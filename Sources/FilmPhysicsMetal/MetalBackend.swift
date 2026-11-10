//
//  MetalBackend.swift
//  light suffer胶片 — iOS app
//
//  The Metal implementation of the film simulation: the GPU port of the
//  pipeline of `FilmPhysics`.
//
//  The backend encodes the very same chain as the CPU reference:
//
//    rgb_in ──▶ raw ──▶ log_e_film ──▶ cmy_film ──▶ log_e_print ──▶ cmy_print ──▶ rgb_out
//
//  The per pixel stages are the kernels of `Shaders/FilmShaders.metal`; the
//  spatial effects (the diffusion filters, the lens blurs, the halation,
//  the diffusion of the DIR couplers and the unsharp mask) are the
//  convolution passes of the same chain.
//
//  The whole file is wrapped in `#if canImport(Metal)`: the target compiles
//  to nothing on Linux, where the CPU reference is built and tested.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

#if canImport(Metal)

import Foundation
import Metal
import FilmPhysics

// MARK: - The errors

/// The errors of the Metal backend.
public enum MetalBackendError: Error, CustomStringConvertible {
    /// No Metal device is available.
    case noDevice
    /// The shader library could not be compiled.
    case libraryCompilationFailed(String)
    /// The plan of the render is not usable.
    case invalidPlan(String)
    /// A command of the render failed.
    case commandFailed(String)

    public var description: String {
        switch self {
        case .noDevice:
            return "no Metal device is available"
        case let .libraryCompilationFailed(reason):
            return "the shader library could not be compiled: \(reason)"
        case let .invalidPlan(reason):
            return "invalid render plan: \(reason)"
        case let .commandFailed(reason):
            return "the render command failed: \(reason)"
        }
    }
}

// MARK: - The buffer pool

/// A pool of the scratch buffers of a render.
///
/// The buffers are allocated lazily, so that a render that does not use the
/// spatial effects does not pay for them.
final class MetalBufferPool {
    private let device: MTLDevice
    private let length: Int
    private var storage: [MTLBuffer] = []
    private var free: [Int] = []

    init(device: MTLDevice, length: Int) {
        self.device = device
        self.length = length
    }

    /// Acquires a buffer of the pool.
    func acquire() -> MTLBuffer {
        if let index = free.popLast() {
            return storage[index]
        }
        guard let buffer = device.makeBuffer(
            length: length, options: .storageModeShared
        ) else {
            fatalError("the Metal device could not allocate a buffer of \(length) bytes")
        }
        storage.append(buffer)
        return buffer
    }

    /// Releases a buffer of the pool.
    func release(_ buffer: MTLBuffer) {
        guard let index = storage.firstIndex(where: { $0 === buffer }) else { return }
        free.append(index)
    }
}

// MARK: - The backend

/// The Metal implementation of ``FilmRenderBackend``.
///
/// The backend renders the whole simulation on the GPU: the spectral
/// upsampling of the camera image, the development of the negative (with
/// the DIR couplers), the printing on the paper, the development of the
/// paper, the scanning and the output gamut compression.
///
/// ```swift
/// guard let backend = MetalBackend() else { return }  // no Metal device
/// let output = try backend.render(image, params: params)
/// ```
public final class MetalBackend: FilmRenderBackend {

    /// The Metal device of the backend.
    public let device: MTLDevice
    /// The command queue of the backend.
    public let commandQueue: MTLCommandQueue
    /// The error of the initialisation, when the shader library could not be
    /// compiled.
    ///
    /// A missing device is reported by a `nil` backend; a **compilation
    /// error** is reported by this property (the tests fail on it, they do
    /// not skip).
    public let initializationError: Error?

    /// The compiled shader library.
    private let library: MTLLibrary?
    /// The compute pipeline states, by name.
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let pipelineLock = NSLock()

    /// Creates the backend.
    ///
    /// - Parameter device: the Metal device to render on. The default is the
    ///   system default device.
    /// - Returns: `nil` when there is no Metal device at all.
    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        do {
            self.library = try MetalBackend.compileLibrary(device: device)
            self.initializationError = nil
        } catch {
            self.library = nil
            self.initializationError = error
        }
    }

    /// Compiles the shader library of the package.
    ///
    /// The Metal Shading Language source is **compiled at runtime** (the
    /// package does not rely on SwiftPM compiling the `.metal` files): the
    /// source is read from the resources of the package and handed over to
    /// `makeLibrary(source:options:)`.
    static func compileLibrary(device: MTLDevice) throws -> MTLLibrary {
        guard let url = MetalBackend.shaderURL() else {
            throw MetalBackendError.libraryCompilationFailed(
                "the shader source 'FilmShaders.metal' was not found in the resources"
            )
        }
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MetalBackendError.libraryCompilationFailed(
                "the shader source could not be read: \(error)"
            )
        }
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw MetalBackendError.libraryCompilationFailed(String(describing: error))
        }
    }

    /// Locates the shader source in the resources of the package.
    static func shaderURL() -> URL? {
        let bundle = Bundle.module
        if let url = bundle.url(
            forResource: "FilmShaders", withExtension: "metal", subdirectory: "Shaders"
        ) {
            return url
        }
        if let url = bundle.url(forResource: "FilmShaders", withExtension: "metal") {
            return url
        }
        guard let root = bundle.resourceURL ?? bundle.bundleURL as URL?,
              let enumerator = FileManager.default.enumerator(
                  at: root, includingPropertiesForKeys: nil
              ) else {
            return nil
        }
        for case let url as URL in enumerator
        where url.lastPathComponent == "FilmShaders.metal" {
            return url
        }
        return nil
    }

    // MARK: - The rendering

    /// Renders an image.
    ///
    /// - Parameters:
    ///   - image: the camera image, in the input colourspace of the
    ///     parameters.
    ///   - params: the parameters of the simulation.
    /// - Returns: the scanned print.
    public func render(_ image: RGBImage, params: PipelineParams) throws -> RGBImage {
        let plan = try FilmRenderPlan.build(params: params)
        return try render(image, plan: plan)
    }

    /// Renders an image with a precomputed plan.
    ///
    /// - Parameters:
    ///   - image: the camera image, in the input colourspace of the plan.
    ///   - plan: the precomputed data of the render.
    /// - Returns: the scanned print.
    public func render(_ image: RGBImage, plan: FilmRenderPlan) throws -> RGBImage {
        guard let library else {
            throw initializationError ?? MetalBackendError.noDevice
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            return RGBImage(width: 0, height: 0, data: [])
        }
        guard image.data.count == width * height * 3 else {
            throw PipelineError.invalidImageData(
                "expected \(width * height * 3) values for a \(width)x\(height) image, "
                    + "got \(image.data.count)"
            )
        }
        let count = width * height * 3

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalBackendError.commandFailed("the command buffer could not be created")
        }

        let planBuffers = try MetalPlanBuffers(
            plan: plan, width: width, height: height, device: device
        )
        let pool = MetalBufferPool(
            device: device, length: count * MemoryLayout<Float>.stride
        )

        // The input image.
        var inputValues = [Float](repeating: 0, count: count)
        for index in 0..<count {
            inputValues[index] = Float(image.data[index])
        }
        guard let input = device.makeBuffer(
            bytes: inputValues, length: count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed("the input buffer could not be allocated")
        }

        // The scale of the negative.
        let pixelSizeUM = Halation.pixelSizeUM(
            filmFormatMM: plan.params.camera.filmFormatMM, width: width, height: height
        )

        // --- the filming stage ------------------------------------------
        let raw = pool.acquire()
        try dispatch(
            encoder, "filmSpectralUpsample",
            [input, raw, planBuffers.inputMatrix, planBuffers.tcLUT, planBuffers.params],
            library: library, width: width, height: height
        )

        var current = raw
        if plan.boostActive {
            let boosted = pool.acquire()
            try applyHighlightBoost(
                encoder, source: current, destination: boosted, plan: plan,
                planBuffers: planBuffers, library: library, width: width, height: height
            )
            current = boosted
        }

        // The diffusion filter of the camera.
        let cameraFilter = MetalKernels.diffusionFilter(
            params: plan.params.camera.diffusionFilter,
            pixelSizeUM: pixelSizeUM,
            width: width,
            height: height
        )
        if let cameraFilter {
            let filtered = pool.acquire()
            try applyDiffusionFilter(
                encoder, source: current, destination: filtered, filter: cameraFilter,
                scatter: DiffusionFilter.scatterFraction(
                    strength: plan.params.camera.diffusionFilter.strength,
                    family: plan.params.camera.diffusionFilter.filterFamily
                ),
                width: width, height: height, library: library, pool: pool
            )
            current = filtered
        }

        // The lens blur of the camera.
        if plan.params.camera.lensBlurUM > 0, pixelSizeUM > 0 {
            let sigma = plan.params.camera.lensBlurUM / pixelSizeUM
            if sigma > 0 {
                let blurred = pool.acquire()
                try applyBlur(
                    encoder, source: current, destination: blurred, sigmas: [sigma],
                    width: width, height: height, library: library, pool: pool
                )
                current = blurred
            }
        }

        // The scatter and the back reflection halation.
        if plan.params.filmRender.halation.active, pixelSizeUM > 0 {
            let bloomed = pool.acquire()
            try applyHalation(
                encoder, source: current, destination: bloomed,
                params: plan.params.filmRender.halation, pixelSizeUM: pixelSizeUM,
                width: width, height: height, library: library, pool: pool
            )
            current = bloomed
        }

        // The log exposure of the negative.
        let logEFilm = pool.acquire()
        try dispatch(
            encoder, "filmLinearToLog",
            [
                current,
                logEFilm,
                try smallBuffer(
                    FilmExposureParams(
                        width: width, height: height, scale: plan.filmingScale
                    )
                ),
            ],
            library: library, width: width, height: height
        )

        // --- the development of the negative ------------------------------
        let density = pool.acquire()
        try dispatch(
            encoder, "filmFilmDensity",
            [logEFilm, density, planBuffers.filmCurve, planBuffers.params],
            library: library, width: width, height: height
        )

        var cmyFilm = density
        if plan.couplersActive {
            let correction = pool.acquire()
            try dispatch(
                encoder, "filmCouplerCorrection",
                [density, correction, planBuffers.coupler, planBuffers.params],
                library: library, width: width, height: height
            )

            // The spatial diffusion of the inhibitors.
            var diffused = correction
            let couplers = plan.params.filmRender.dirCouplers
            if couplers.diffusionSizeUM > 0, pixelSizeUM > 0 {
                let diffusionSize = couplers.diffusionSizeUM / pixelSizeUM
                let tailSize = couplers.diffusionTailUM / pixelSizeUM
                let gaussian = pool.acquire()
                try applyBlur(
                    encoder, source: correction, destination: gaussian,
                    sigmas: [diffusionSize], width: width, height: height,
                    library: library, pool: pool
                )
                let tail = pool.acquire()
                try applyExponentialFilter(
                    encoder, source: correction, destination: tail, decay: [tailSize],
                    width: width, height: height, library: library, pool: pool
                )
                let combined = pool.acquire()
                try dispatch(
                    encoder, "filmCombine2",
                    [
                        gaussian,
                        tail,
                        combined,
                        try smallBuffer(
                            FilmCombineParams(
                                width: width,
                                height: height,
                                weightA: Float(1.0 - couplers.diffusionTailWeight),
                                weightB: Float(couplers.diffusionTailWeight)
                            )
                        ),
                    ],
                    library: library, width: width, height: height
                )
                diffused = combined
            }

            let coupled = pool.acquire()
            try dispatch(
                encoder, "filmFilmDensityCoupled",
                [
                    logEFilm,
                    diffused,
                    coupled,
                    planBuffers.filmCurveBeforeCouplers,
                    planBuffers.params,
                ],
                library: library, width: width, height: height
            )
            cmyFilm = coupled
        }

        // --- the printing stage -------------------------------------------
        let rawPrint = pool.acquire()
        try dispatch(
            encoder, "filmPrintingExposure",
            [
                cmyFilm,
                rawPrint,
                planBuffers.filmChannelDensity,
                planBuffers.filmBaseDensity,
                planBuffers.printSensitivity,
                planBuffers.printIlluminant,
                planBuffers.preflash,
                planBuffers.params,
            ],
            library: library, width: width, height: height
        )

        // The diffusion filter of the enlarger.
        let enlargerFilter = MetalKernels.diffusionFilter(
            params: plan.params.enlarger.diffusionFilter,
            pixelSizeUM: pixelSizeUM,
            width: width,
            height: height
        )
        var printed = rawPrint
        if let enlargerFilter {
            let filtered = pool.acquire()
            try applyDiffusionFilter(
                encoder, source: rawPrint, destination: filtered, filter: enlargerFilter,
                scatter: DiffusionFilter.scatterFraction(
                    strength: plan.params.enlarger.diffusionFilter.strength,
                    family: plan.params.enlarger.diffusionFilter.filterFamily
                ),
                width: width, height: height, library: library, pool: pool
            )
            printed = filtered
        }

        // The log exposure of the paper.
        let logEPrint = pool.acquire()
        try dispatch(
            encoder, "filmLinearToLog",
            [
                printed,
                logEPrint,
                try smallBuffer(
                    FilmExposureParams(
                        width: width,
                        height: height,
                        scale: plan.printExposure * plan.printingExposureCorrection
                    )
                ),
            ],
            library: library, width: width, height: height
        )

        // --- the development of the paper ----------------------------------
        let cmyPrint = pool.acquire()
        try dispatch(
            encoder, "filmPrintDensity",
            [logEPrint, cmyPrint, planBuffers.printCurve, planBuffers.params],
            library: library, width: width, height: height
        )

        // --- the scanning stage --------------------------------------------
        let xyz = pool.acquire()
        try dispatch(
            encoder, "filmScanXYZ",
            [
                cmyPrint,
                xyz,
                planBuffers.printChannelDensity,
                planBuffers.printBaseDensity,
                planBuffers.scanIlluminant,
                planBuffers.colourMatchingFunctions,
                planBuffers.params,
            ],
            library: library, width: width, height: height
        )

        var rgb = pool.acquire()
        try dispatch(
            encoder, "filmXYZToRGB",
            [xyz, rgb, planBuffers.xyzToRGB, planBuffers.params],
            library: library, width: width, height: height
        )

        // The output gamut compression.
        if let cMax = planBuffers.cMax {
            let compressed = pool.acquire()
            try dispatch(
                encoder, "filmGamutCompress",
                [
                    rgb,
                    compressed,
                    planBuffers.gamutRGBToXYZ,
                    planBuffers.gamutXYZToRGB,
                    cMax,
                    planBuffers.params,
                ],
                library: library, width: width, height: height
            )
            rgb = compressed
        }

        // The lens blur of the scanner.
        if plan.params.scanner.lensBlur > 0 {
            let blurred = pool.acquire()
            try applyBlur(
                encoder, source: rgb, destination: blurred,
                sigmas: [plan.params.scanner.lensBlur],
                width: width, height: height, library: library, pool: pool
            )
            rgb = blurred
        }

        // The unsharp mask of the scanner.
        let unsharpAmount = plan.params.scanner.unsharpMaskAmount
        let unsharpSigma = plan.params.scanner.unsharpMaskSigma
        if unsharpSigma > 0, unsharpAmount > 0 {
            let blurred = pool.acquire()
            try applyBlur(
                encoder, source: rgb, destination: blurred, sigmas: [unsharpSigma],
                width: width, height: height, library: library, pool: pool
            )
            let sharpened = pool.acquire()
            try dispatch(
                encoder, "filmCombine2",
                [
                    rgb,
                    blurred,
                    sharpened,
                    try smallBuffer(
                        FilmCombineParams(
                            width: width,
                            height: height,
                            weightA: Float(1.0 + unsharpAmount),
                            weightB: Float(-unsharpAmount)
                        )
                    ),
                ],
                library: library, width: width, height: height
            )
            rgb = sharpened
        }

        // The output transfer function.
        let output = pool.acquire()
        try dispatch(
            encoder, "filmEncodeOutput",
            [rgb, output, planBuffers.srgbToSRGB, planBuffers.params],
            library: library, width: width, height: height
        )

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw MetalBackendError.commandFailed(String(describing: error))
        }

        // The read back.
        let contents = output.contents().bindMemory(to: Float.self, capacity: count)
        var values = [Double](repeating: 0, count: count)
        for index in 0..<count {
            values[index] = Double(contents[index])
        }
        return RGBImage(width: width, height: height, data: values)
    }

    // MARK: - The passes

    /// Encodes a compute dispatch of the chain.
    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        _ name: String,
        _ buffers: [MTLBuffer],
        library: MTLLibrary,
        width: Int,
        height: Int
    ) throws {
        let state = try pipeline(named: name, library: library)
        encoder.setComputePipelineState(state)
        for (index, buffer) in buffers.enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
        let group = groupWidth(for: state)
        let totalWidth = ((width + group - 1) / group) * group
        let totalHeight = ((height + group - 1) / group) * group
        encoder.dispatchThreads(
            MTLSize(width: totalWidth, height: totalHeight, depth: 1),
            threadsPerThreadgroup: MTLSize(width: group, height: group, depth: 1)
        )
    }

    /// The width of the thread groups of a pipeline.
    private func groupWidth(for state: MTLComputePipelineState) -> Int {
        let maximum = state.maxTotalThreadsPerThreadgroup
        if maximum >= 256 { return 16 }
        if maximum >= 64 { return 8 }
        return 4
    }

    /// The compute pipeline state of a kernel.
    private func pipeline(named name: String, library: MTLLibrary) throws -> MTLComputePipelineState {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        if let state = pipelines[name] { return state }
        guard let function = library.makeFunction(name: name) else {
            throw MetalBackendError.libraryCompilationFailed(
                "the kernel '\(name)' was not found in the shader library"
            )
        }
        let state = try device.makeComputePipelineState(function: function)
        pipelines[name] = state
        return state
    }

    /// A small buffer of the parameters of a pass.
    private func smallBuffer<T>(_ value: T) throws -> MTLBuffer {
        var value = value
        guard let buffer = device.makeBuffer(
            bytes: &value, length: MemoryLayout<T>.stride, options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed("a parameter buffer could not be allocated")
        }
        return buffer
    }

    /// The highlight boost of the negative.
    private func applyHighlightBoost(
        _ encoder: MTLComputeCommandEncoder,
        source: MTLBuffer,
        destination: MTLBuffer,
        plan: FilmRenderPlan,
        planBuffers: MetalPlanBuffers,
        library: MTLLibrary,
        width: Int,
        height: Int
    ) throws {
        let partials = device.makeBuffer(
            length: 1024 * MemoryLayout<Float>.stride, options: .storageModeShared
        )
        let maximum = device.makeBuffer(
            length: MemoryLayout<Float>.stride, options: .storageModeShared
        )
        guard let partials, let maximum else {
            throw MetalBackendError.commandFailed("the reduction buffers could not be allocated")
        }

        // The first stage of the reduction.
        let partialState = try pipeline(named: "filmReduceMaxPartial", library: library)
        encoder.setComputePipelineState(partialState)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(partials, offset: 0, index: 1)
        encoder.setBuffer(planBuffers.params, offset: 0, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: 1024, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1)
        )

        // The second stage of the reduction.
        let finalState = try pipeline(named: "filmReduceMaxFinal", library: library)
        encoder.setComputePipelineState(finalState)
        encoder.setBuffer(partials, offset: 0, index: 0)
        encoder.setBuffer(maximum, offset: 0, index: 1)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )

        // The boost itself.
        try dispatch(
            encoder, "filmBoostHighlights",
            [source, destination, maximum, planBuffers.params],
            library: library, width: width, height: height
        )
    }

    /// The separable Gaussian filter.
    private func applyBlur(
        _ encoder: MTLComputeCommandEncoder,
        source: MTLBuffer,
        destination: MTLBuffer,
        sigmas: [Double],
        width: Int,
        height: Int,
        library: MTLLibrary,
        pool: MetalBufferPool
    ) throws {
        let (radius, kernels) = MetalKernels.gaussian(sigmas: sigmas)
        guard let kernelBuffer = device.makeBuffer(
            bytes: kernels, length: kernels.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed("a kernel buffer could not be allocated")
        }
        var blurParams = FilmBlurParams(width: width, height: height, radius: radius)
        guard let paramsBuffer = device.makeBuffer(
            bytes: &blurParams, length: MemoryLayout<FilmBlurParams>.stride,
            options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed("a parameter buffer could not be allocated")
        }
        let temporary = pool.acquire()
        try dispatch(
            encoder, "filmBlurHorizontal",
            [source, temporary, kernelBuffer, paramsBuffer],
            library: library, width: width, height: height
        )
        try dispatch(
            encoder, "filmBlurVertical",
            [temporary, destination, kernelBuffer, paramsBuffer],
            library: library, width: width, height: height
        )
        pool.release(temporary)
    }

    /// The exponential surrogate of the isotropic 2D exponential PSF.
    private func applyExponentialFilter(
        _ encoder: MTLComputeCommandEncoder,
        source: MTLBuffer,
        destination: MTLBuffer,
        decay: [Double],
        width: Int,
        height: Int,
        library: MTLLibrary,
        pool: MetalBufferPool
    ) throws {
        let fits = SpatialEffects.exponentialGaussianFits
        var components: [MTLBuffer] = []
        for fit in fits {
            let sigmas = decay.count == 1
                ? [fit.sigmaRatio * decay[0], fit.sigmaRatio * decay[0], fit.sigmaRatio * decay[0]]
                : decay.map { fit.sigmaRatio * $0 }
            let component = pool.acquire()
            try applyBlur(
                encoder, source: source, destination: component, sigmas: sigmas,
                width: width, height: height, library: library, pool: pool
            )
            components.append(component)
        }
        var combineParams = FilmCombineParams(
            width: width,
            height: height,
            weightA: Float(fits[0].amplitude),
            weightB: Float(fits[1].amplitude),
            weightC: Float(fits[2].amplitude)
        )
        guard let paramsBuffer = device.makeBuffer(
            bytes: &combineParams, length: MemoryLayout<FilmCombineParams>.stride,
            options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed("a parameter buffer could not be allocated")
        }
        try dispatch(
            encoder, "filmCombine3",
            [components[0], components[1], components[2], destination, paramsBuffer],
            library: library, width: width, height: height
        )
        for component in components {
            pool.release(component)
        }
    }

    /// The two dimensional convolution of a diffusion filter.
    private func applyDiffusionFilter(
        _ encoder: MTLComputeCommandEncoder,
        source: MTLBuffer,
        destination: MTLBuffer,
        filter: (radius: Int, psf: [Float]),
        scatter: Double,
        width: Int,
        height: Int,
        library: MTLLibrary,
        pool: MetalBufferPool
    ) throws {
        guard let psfBuffer = device.makeBuffer(
            bytes: filter.psf, length: filter.psf.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed("a kernel buffer could not be allocated")
        }
        var blurParams = FilmBlurParams(width: width, height: height, radius: filter.radius)
        blurParams.scatterFraction = Float(scatter)
        guard let paramsBuffer = device.makeBuffer(
            bytes: &blurParams, length: MemoryLayout<FilmBlurParams>.stride,
            options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed("a parameter buffer could not be allocated")
        }
        try dispatch(
            encoder, "filmDiffusionFilter",
            [source, destination, psfBuffer, paramsBuffer],
            library: library, width: width, height: height
        )
    }

    /// The in emulsion scatter and the back reflection halation.
    private func applyHalation(
        _ encoder: MTLComputeCommandEncoder,
        source: MTLBuffer,
        destination: MTLBuffer,
        params: HalationParams,
        pixelSizeUM: Double,
        width: Int,
        height: Int,
        library: MTLLibrary,
        pool: MetalBufferPool
    ) throws {
        var current = source

        // 1. The scatter pass.
        let corePixels = params.scatterCoreUM.map {
            $0 * params.scatterSpatialScale / pixelSizeUM
        }
        let tailPixels = params.scatterTailUM.map {
            $0 * params.scatterSpatialScale / pixelSizeUM
        }
        let hasCore = corePixels.contains { $0 > 0 }
        let hasTail = tailPixels.contains { $0 > 0 }
        if params.scatterAmount > 0, hasCore || hasTail {
            var core = current
            if hasCore {
                let blurred = pool.acquire()
                try applyBlur(
                    encoder, source: current, destination: blurred,
                    sigmas: corePixels.map { max($0, 1e-6) },
                    width: width, height: height, library: library, pool: pool
                )
                core = blurred
            }
            var tail = current
            if hasTail {
                let filtered = pool.acquire()
                try applyExponentialFilter(
                    encoder, source: current, destination: filtered,
                    decay: tailPixels.map { max($0, 1e-6) },
                    width: width, height: height, library: library, pool: pool
                )
                tail = filtered
            }
            let scattered = pool.acquire()
            let tailWeight = params.scatterTailWeight
            var combineParams = FilmCombineParams(
                width: width,
                height: height,
                weightA: Float(tailWeight.count > 0 ? tailWeight[0] : 0),
                weightB: Float(tailWeight.count > 1 ? tailWeight[1] : 0),
                weightC: Float(tailWeight.count > 2 ? tailWeight[2] : 0),
                weightD: Float(params.scatterAmount)
            )
            guard let paramsBuffer = device.makeBuffer(
                bytes: &combineParams, length: MemoryLayout<FilmCombineParams>.stride,
                options: .storageModeShared
            ) else {
                throw MetalBackendError.commandFailed("a parameter buffer could not be allocated")
            }
            try dispatch(
                encoder, "filmScatterCombine",
                [current, core, tail, scattered, paramsBuffer],
                library: library, width: width, height: height
            )
            current = scattered
        }

        // 2. The halation pass.
        let strength = params.halationStrength.map { $0 * params.halationAmount }
        let sigmaPixels = params.halationFirstSigmaUM.map {
            $0 * params.halationSpatialScale / pixelSizeUM
        }
        let bounces = params.halationNBounces
        let hasStrength = strength.contains { $0 > 0 }
        let hasSigma = sigmaPixels.contains { $0 > 0 }
        if bounces >= 1, hasStrength, hasSigma {
            var weights = [Double](repeating: 0, count: bounces)
            var total = 0.0
            for index in 0..<bounces {
                weights[index] = pow(params.halationBounceDecay, Double(index))
                total += weights[index]
            }
            if total > 0 {
                for index in 0..<bounces { weights[index] /= total }
            }
            var components: [MTLBuffer] = []
            var componentWeights: [Float] = []
            for index in 0..<bounces {
                let sigma = sigmaPixels.map { max($0 * sqrt(Double(index + 1)), 1e-6) }
                let component = pool.acquire()
                try applyBlur(
                    encoder, source: current, destination: component, sigmas: sigma,
                    width: width, height: height, library: library, pool: pool
                )
                components.append(component)
                componentWeights.append(Float(weights[index]))
            }
            // The combination of at most three bounces.
            while components.count < 3 {
                components.append(components[components.count - 1])
                componentWeights.append(0)
            }
            var combineParams = FilmCombineParams(
                width: width,
                height: height,
                weightA: componentWeights[0],
                weightB: componentWeights[1],
                weightC: componentWeights[2]
            )
            guard let paramsBuffer = device.makeBuffer(
                bytes: &combineParams, length: MemoryLayout<FilmCombineParams>.stride,
                options: .storageModeShared
            ) else {
                throw MetalBackendError.commandFailed("a parameter buffer could not be allocated")
            }
            let bloom = pool.acquire()
            try dispatch(
                encoder, "filmCombine3",
                [components[0], components[1], components[2], bloom, paramsBuffer],
                library: library, width: width, height: height
            )
            for component in components {
                pool.release(component)
            }
            var halationParams = FilmCombineParams(
                width: width,
                height: height,
                weightA: Float(strength.count > 0 ? strength[0] : 0),
                weightB: Float(strength.count > 1 ? strength[1] : 0),
                weightC: Float(strength.count > 2 ? strength[2] : 0),
                weightD: params.halationRenormalize ? 1 : 0
            )
            guard let halationBuffer = device.makeBuffer(
                bytes: &halationParams, length: MemoryLayout<FilmCombineParams>.stride,
                options: .storageModeShared
            ) else {
                throw MetalBackendError.commandFailed("a parameter buffer could not be allocated")
            }
            try dispatch(
                encoder, "filmHalationCombine",
                [current, bloom, destination, halationBuffer],
                library: library, width: width, height: height
            )
        } else {
            // Without the halation the image is unchanged: the destination is
            // filled with the source by a copy pass.
            try dispatch(
                encoder, "filmCombine2",
                [
                    current,
                    current,
                    destination,
                    try smallBuffer(
                        FilmCombineParams(
                            width: width, height: height, weightA: 1, weightB: 0
                        )
                    ),
                ],
                library: library, width: width, height: height
            )
        }
    }
}

#endif
