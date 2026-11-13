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
import Dispatch
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
    /// A command of the render did not finish in time.
    ///
    /// The GPU never completed the command buffer: the render is abandoned
    /// instead of blocking the process forever.
    case gpuTimeout(stage: String)

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
        case let .gpuTimeout(stage):
            return "the GPU did not finish the stage '\(stage)' in time"
        }
    }
}

// MARK: - The command context

/// The command buffer of a render of the Metal backend.
///
/// The context owns the command buffer and the compute encoder of the
/// render, and it waits for the completion of the command buffer with a
/// **bounded** wait: a GPU that never finishes (a kernel that never
/// terminates, a device that is lost) must not hang the process — the
/// render fails with ``MetalBackendError/gpuTimeout(stage:)`` instead.
///
/// In the **diagnostic** mode (the environment variable
/// `FILM_METAL_DIAGNOSTIC=1`), every pass is committed in its own command
/// buffer and the time it took is printed (`METAL-STAGE <kernel> <ms>`):
/// the log of the CI then shows exactly which kernel hangs.
final class MetalCommandContext {

    /// The queue of the commands.
    private let queue: MTLCommandQueue
    /// Whether every pass is committed on its own command buffer.
    let diagnostic: Bool
    /// The maximum time a command buffer may take, in seconds.
    let timeout: TimeInterval
    /// The command buffer of the render.
    private var commandBuffer: MTLCommandBuffer?
    /// The encoder of the render.
    ///
    /// The property is **not** named `encoder`: the method ``encoder()``
    /// (which creates the encoder on the first call) would collide with it,
    /// and the Swift compiler rejects the redeclaration.
    private var activeEncoder: MTLComputeCommandEncoder?
    /// The number of the committed stages.
    private(set) var stageCount = 0

    /// Creates the context of a render.
    ///
    /// - Parameters:
    ///   - queue: the queue of the commands.
    ///   - diagnostic: whether every pass is committed on its own.
    ///   - timeout: the maximum time a command buffer may take.
    init(queue: MTLCommandQueue, diagnostic: Bool, timeout: TimeInterval) {
        self.queue = queue
        self.diagnostic = diagnostic
        self.timeout = timeout
    }

    /// The encoder of the render.
    ///
    /// - Returns: the encoder, created on the first call.
    func encoder() throws -> MTLComputeCommandEncoder {
        if let activeEncoder { return activeEncoder }
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalBackendError.commandFailed("the command buffer could not be created")
        }
        self.commandBuffer = commandBuffer
        self.activeEncoder = encoder
        return encoder
    }

    /// Commits the current command buffer and waits for its completion.
    ///
    /// - Parameter stage: the name of the stage (the name of the kernel),
    ///   which is reported when the GPU does not finish.
    func commit(stage: String) throws {
        guard let commandBuffer, let activeEncoder else { return }
        activeEncoder.endEncoding()
        self.activeEncoder = nil
        self.commandBuffer = nil
        let start = Date()
        try Self.wait(
            for: commandBuffer, timeout: timeout, stage: stage
        )
        stageCount += 1
        if diagnostic {
            let elapsed = Date().timeIntervalSince(start) * 1000
            MetalCommandContext.log(
                "METAL-STAGE \(stage) \(String(format: "%.3f", elapsed)) ms"
            )
        }
    }

    /// The completion of the render.
    func finish() throws {
        try commit(stage: "the render")
    }

    /// Waits for the completion of a command buffer, with a bounded wait.
    ///
    /// The wait is bounded: a command buffer that does not complete in
    /// `timeout` seconds is a failure, not a hang.  The status and the
    /// error of the command buffer are checked afterwards: an error of the
    /// GPU (a fault of a kernel, a lost device) is reported with the
    /// message of the driver, which is the difference between a *runtime*
    /// failure and a *compilation* failure of the shaders.
    ///
    /// - Parameters:
    ///   - commandBuffer: the command buffer to wait for.
    ///   - timeout: the maximum time, in seconds.
    ///   - stage: the name of the stage (reported in the errors).
    private static func wait(
        for commandBuffer: MTLCommandBuffer, timeout: TimeInterval, stage: String
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.commit()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw MetalBackendError.gpuTimeout(stage: stage)
        }
        if commandBuffer.status == .error {
            throw MetalBackendError.commandFailed(
                "the stage '\(stage)' failed: "
                    + (commandBuffer.error.map { String(describing: $0) } ?? "unknown error")
            )
        }
        guard commandBuffer.status == .completed else {
            throw MetalBackendError.gpuTimeout(stage: stage)
        }
        if let error = commandBuffer.error {
            throw MetalBackendError.commandFailed("the stage '\(stage)' failed: \(error)")
        }
    }

    /// Prints a line on the standard error, unbuffered.
    ///
    /// The lines of the diagnostic mode must reach the log of the CI
    /// immediately: the standard output of a test is block buffered when
    /// it is piped.
    static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
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
    ///
    /// - Returns: the buffer.
    /// - Throws: ``MetalBackendError/commandFailed(_:)`` when the device
    ///   cannot allocate the buffer (the render fails instead of
    ///   terminating the process).
    func acquire() throws -> MTLBuffer {
        if let index = free.popLast() {
            return storage[index]
        }
        guard let buffer = device.makeBuffer(
            length: length, options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed(
                "the Metal device could not allocate a buffer of \(length) bytes"
            )
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

// MARK: - The taps

/// The taps of a render of the Metal backend.
///
/// The taps are the same as the ones of the CPU reference (``FilmTaps``):
/// they are the intermediate results of the chain, which the tests compare
/// with the ones of the CPU.
public struct MetalRenderTaps: Sendable {
    /// The log10 exposure of the negative.
    public var logEFilm: RGBImage
    /// The developed densities of the negative (with the grain).
    public var cmyFilm: RGBImage
    /// The log10 exposure of the paper (empty on the direct scan path).
    public var logEPrint: RGBImage
    /// The developed densities of the print (empty on the direct scan path).
    public var cmyPrint: RGBImage
    /// The scanned and encoded print.
    public var rgbOut: RGBImage

    public init(
        logEFilm: RGBImage,
        cmyFilm: RGBImage,
        logEPrint: RGBImage,
        cmyPrint: RGBImage,
        rgbOut: RGBImage
    ) {
        self.logEFilm = logEFilm
        self.cmyFilm = cmyFilm
        self.logEPrint = logEPrint
        self.cmyPrint = cmyPrint
        self.rgbOut = rgbOut
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

    /// Whether the backend runs in the **diagnostic** mode.
    ///
    /// In that mode every pass of a render is committed in its own command
    /// buffer and the time it took is printed (`METAL-STAGE <kernel> <ms>`),
    /// so that the log shows exactly which kernel hangs.  The mode is
    /// enabled by the environment variable `FILM_METAL_DIAGNOSTIC=1`.
    public let diagnostic: Bool

    /// The maximum time a command buffer of a render may take, in seconds.
    ///
    /// The default is 60 seconds; the environment variable
    /// `FILM_METAL_TIMEOUT` overrides it.  The wait is **bounded**: a GPU
    /// that never finishes must fail the render, not hang the process.
    public let timeout: TimeInterval

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
        self.diagnostic = MetalBackend.environmentFlag("FILM_METAL_DIAGNOSTIC")
        self.timeout = MetalBackend.environmentTimeout("FILM_METAL_TIMEOUT")
        do {
            self.library = try MetalBackend.compileLibrary(device: device)
            self.initializationError = nil
        } catch {
            self.library = nil
            self.initializationError = error
        }
    }

    /// Reads a flag of the environment.
    ///
    /// - Parameter name: the name of the variable.
    /// - Returns: `true` when the variable is set to `1` or to `true`.
    private static func environmentFlag(_ name: String) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return false }
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    /// Reads a timeout of the environment, in seconds.
    ///
    /// - Parameter name: the name of the variable.
    /// - Returns: the timeout, or the default of 60 seconds.
    private static func environmentTimeout(_ name: String) -> TimeInterval {
        guard let value = ProcessInfo.processInfo.environment[name],
              let timeout = TimeInterval(value), timeout > 0 else { return 60 }
        return timeout
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
    /// The sampler of the variates of the grain is the one of the
    /// parameters (`params.stochastic.grainSampler`, which is `.fast`
    /// unless it is explicitly set).
    ///
    /// - Parameters:
    ///   - image: the camera image, in the input colourspace of the
    ///     parameters.
    ///   - params: the parameters of the simulation.
    /// - Returns: the scanned print.
    public func render(_ image: RGBImage, params: PipelineParams) throws -> RGBImage {
        try render(image, params: params, sampler: nil)
    }

    /// Renders an image.
    ///
    /// - Parameters:
    ///   - image: the camera image, in the input colourspace of the
    ///     parameters.
    ///   - params: the parameters of the simulation.
    ///   - sampler: the sampler of the variates of the grain: `nil` (the
    ///     default) takes the sampler of the parameters
    ///     (`params.stochastic.grainSampler`, which is `.fast` unless it is
    ///     explicitly set).
    /// - Returns: the scanned print.
    public func render(
        _ image: RGBImage, params: PipelineParams, sampler: GrainSampler?
    ) throws -> RGBImage {
        let exposure = try AutoExposure.resolve(params: params, meteringImage: image)
        let plan = try FilmRenderPlan.build(params: exposure.params)
        return try render(
            exposure.apply(to: image), plan: plan, sampler: sampler, collectTaps: false
        ).rgbOut
    }

    /// Renders an image with a precomputed plan.
    ///
    /// The sampler of the variates of the grain is the one of the
    /// parameters (`plan.params.stochastic.grainSampler`, which is `.fast`
    /// unless it is explicitly set).
    ///
    /// - Parameters:
    ///   - image: the camera image, in the input colourspace of the plan.
    ///   - plan: the precomputed data of the render.
    /// - Returns: the taps of the render.
    public func render(_ image: RGBImage, plan: FilmRenderPlan) throws -> MetalRenderTaps {
        try render(image, plan: plan, sampler: nil)
    }

    /// Renders an image with a precomputed plan.
    ///
    /// - Parameters:
    ///   - image: the camera image, in the input colourspace of the plan.
    ///   - plan: the precomputed data of the render.
    ///   - sampler: the sampler of the variates of the grain: `nil` (the
    ///     default) takes the sampler of the parameters
    ///     (`plan.params.stochastic.grainSampler`, which is `.fast` unless
    ///     it is explicitly set).
    /// - Returns: the taps of the render.
    public func render(
        _ image: RGBImage, plan: FilmRenderPlan, sampler: GrainSampler?
    ) throws -> MetalRenderTaps {
        try render(image, plan: plan, sampler: sampler, collectTaps: true)
    }

    /// Renders an image with a precomputed plan.
    ///
    /// - Parameters:
    ///   - image: the camera image, in the input colourspace of the plan.
    ///   - plan: the precomputed data of the render.
    ///   - sampler: the sampler of the variates of the grain: `nil` (the
    ///     default) takes the sampler of the parameters.
    ///   - collectTaps: whether the intermediate taps are read back (the
    ///     read back of the taps is a measurable part of the time of a
    ///     render, so the timing runs skip it).
    /// - Returns: the taps of the render.
    private func render(
        _ image: RGBImage,
        plan: FilmRenderPlan,
        sampler: GrainSampler?,
        collectTaps: Bool
    ) throws -> MetalRenderTaps {
        guard !plan.params.camera.autoExposure else {
            throw PipelineError.invalidInputs("the render plan contains unresolved auto exposure")
        }
        guard let library else {
            throw initializationError ?? MetalBackendError.noDevice
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            let empty = RGBImage(width: 0, height: 0, data: [])
            return MetalRenderTaps(
                logEFilm: empty, cmyFilm: empty, logEPrint: empty, cmyPrint: empty,
                rgbOut: empty
            )
        }
        guard image.data.count == width * height * 3 else {
            throw PipelineError.invalidImageData(
                "expected \(width * height * 3) values for a \(width)x\(height) image, "
                    + "got \(image.data.count)"
            )
        }
        let count = width * height * 3

        // The command buffer of the render.  In the diagnostic mode every
        // pass is committed on its own command buffer (the log then shows
        // the time of every kernel).
        let context = MetalCommandContext(
            queue: commandQueue, diagnostic: diagnostic, timeout: timeout
        )

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
        let raw = try pool.acquire()
        try dispatch(
            context, "filmSpectralUpsample",
            [input, raw, planBuffers.inputMatrix, planBuffers.tcLUT, planBuffers.params],
            library: library, width: width, height: height
        )

        var current = raw
        if plan.boostActive {
            let boosted = try pool.acquire()
            try applyHighlightBoost(
                context, source: current, destination: boosted, plan: plan,
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
            let filtered = try pool.acquire()
            try applyDiffusionFilter(
                context, source: current, destination: filtered, filter: cameraFilter,
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
                let blurred = try pool.acquire()
                try applyBlur(
                    context, source: current, destination: blurred, sigmas: [sigma],
                    width: width, height: height, library: library, pool: pool
                )
                current = blurred
            }
        }

        // The scatter and the back reflection halation.
        if plan.params.filmRender.halation.active, pixelSizeUM > 0 {
            let bloomed = try pool.acquire()
            try applyHalation(
                context, source: current, destination: bloomed,
                params: plan.params.filmRender.halation, pixelSizeUM: pixelSizeUM,
                width: width, height: height, library: library, pool: pool
            )
            current = bloomed
        }

        // The log exposure of the negative.
        let logEFilm = try pool.acquire()
        try dispatch(
            context, "filmLinearToLog",
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
        let density = try pool.acquire()
        try dispatch(
            context, "filmFilmDensity",
            [logEFilm, density, planBuffers.filmCurve, planBuffers.params],
            library: library, width: width, height: height
        )

        var cmyFilm = density
        if plan.couplersActive {
            let correction = try pool.acquire()
            try dispatch(
                context, "filmCouplerCorrection",
                [density, correction, planBuffers.coupler, planBuffers.params],
                library: library, width: width, height: height
            )

            // The spatial diffusion of the inhibitors.
            var diffused = correction
            let couplers = plan.params.filmRender.dirCouplers
            if couplers.diffusionSizeUM > 0, pixelSizeUM > 0 {
                let diffusionSize = couplers.diffusionSizeUM / pixelSizeUM
                let tailSize = couplers.diffusionTailUM / pixelSizeUM
                let gaussian = try pool.acquire()
                try applyBlur(
                    context, source: correction, destination: gaussian,
                    sigmas: [diffusionSize], width: width, height: height,
                    library: library, pool: pool
                )
                let tail = try pool.acquire()
                try applyExponentialFilter(
                    context, source: correction, destination: tail, decay: [tailSize],
                    width: width, height: height, library: library, pool: pool
                )
                let combined = try pool.acquire()
                try dispatch(
                    context, "filmCombine2",
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

            let coupled = try pool.acquire()
            try dispatch(
                context, "filmFilmDensityCoupled",
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

        // --- the grain of the negative -------------------------------------
        // The grain replaces the developed densities (the upstream does not
        // add the grain to them).
        let grainParams = plan.params.filmRender.grain
        if grainParams.active {
            guard grainParams.sublayersActive else {
                throw MetalBackendError.invalidPlan(
                    "the single layer model of the grain is not ported to the GPU"
                )
            }
            let grainPlan = FilmGrainPlan.build(
                grain: grainParams,
                film: plan.params.film,
                pixelSizeUM: pixelSizeUM
            )
            let grainBuffers = try MetalGrainBuffers(
                plan: grainPlan,
                width: width,
                height: height,
                seed: plan.params.stochastic.seed,
                sampler: sampler ?? plan.params.stochastic.grainSampler,
                device: device
            )
            let cyan = try pool.acquire()
            let magenta = try pool.acquire()
            let yellow = try pool.acquire()
            try dispatch(
                context, "filmGrainLayers",
                [
                    cmyFilm,
                    cyan,
                    magenta,
                    yellow,
                    grainBuffers.layerCurves,
                    grainBuffers.normalisedCurves,
                    grainBuffers.layerParameters,
                    grainBuffers.uniformity,
                    grainBuffers.seeds,
                    grainBuffers.params,
                ],
                library: library, width: width, height: height
            )

            // The blur of the dye clouds: every layer is blurred with its
            // own sigma, so the three layers of a channel are the three
            // channels of an image.
            var layers = [cyan, magenta, yellow]
            for colour in 0..<3 {
                let sigmas = (0..<FilmGrainPlan.layerCount).map { layer in
                    Double(grainPlan.blurSigma[layer * FilmGrainPlan.channelCount + colour])
                }
                let blurred = try pool.acquire()
                try applyBlur(
                    context, source: layers[colour], destination: blurred,
                    sigmas: sigmas, width: width, height: height,
                    library: library, pool: pool
                )
                layers[colour] = blurred
            }

            // The sum of the layers.
            var sum = try pool.acquire()
            try dispatch(
                context, "filmGrainSumLayers",
                [layers[0], layers[1], layers[2], sum, planBuffers.params],
                library: library, width: width, height: height
            )

            // The micro structure of the emulsion.
            //
            // The CPU reference applies the clumping of the dye clouds only
            // above a sigma of 0.05 (`Grain.addMicroStructure`): below it
            // the emulsion has no micro structure and the field of the
            // densities is left alone.
            if grainPlan.microStructureSigma > 0.05 {
                let clumping = try pool.acquire()
                try dispatch(
                    context, "filmGrainClumping",
                    [clumping, grainBuffers.clumpingParams],
                    library: library, width: width, height: height
                )
                var clumpingField = clumping
                if Double(grainPlan.microStructureBlur) > 0.4 {
                    let blurred = try pool.acquire()
                    try applyBlur(
                        context, source: clumping, destination: blurred,
                        sigmas: [Double(grainPlan.microStructureBlur)],
                        width: width, height: height, library: library, pool: pool
                    )
                    clumpingField = blurred
                }
                let multiplied = try pool.acquire()
                try dispatch(
                    context, "filmCombineMultiply",
                    [sum, clumpingField, multiplied, planBuffers.params],
                    library: library, width: width, height: height
                )
                sum = multiplied
            }

            // The removal of the minimum density.
            var grained = try pool.acquire()
            try dispatch(
                context, "filmGrainFinalize",
                [sum, grainBuffers.densityMin, grained, planBuffers.params],
                library: library, width: width, height: height
            )

            // The final blur of the grain.
            if grainParams.blur > 0 {
                let blurred = try pool.acquire()
                try applyBlur(
                    context, source: grained, destination: blurred,
                    sigmas: [grainParams.blur], width: width, height: height,
                    library: library, pool: pool
                )
                grained = blurred
            }
            cmyFilm = grained
        }

        // --- the printing stage -------------------------------------------
        // The direct scan path (`io.scan_film`) skips the printing stage:
        // the negative is scanned as it is.
        var logEPrintBuffer: MTLBuffer?
        var cmyPrintBuffer: MTLBuffer?
        var cmyPrint = cmyFilm
        if !plan.scanFilm {
            let rawPrint = try pool.acquire()
            try dispatch(
                context, "filmPrintingExposure",
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
                let filtered = try pool.acquire()
                try applyDiffusionFilter(
                    context, source: rawPrint, destination: filtered, filter: enlargerFilter,
                    scatter: DiffusionFilter.scatterFraction(
                        strength: plan.params.enlarger.diffusionFilter.strength,
                        family: plan.params.enlarger.diffusionFilter.filterFamily
                    ),
                    width: width, height: height, library: library, pool: pool
                )
                printed = filtered
            }

            // The log exposure of the paper.
            let logEPrint = try pool.acquire()
            logEPrintBuffer = logEPrint
            try dispatch(
                context, "filmLinearToLog",
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
            let developed = try pool.acquire()
            cmyPrintBuffer = developed
            try dispatch(
                context, "filmPrintDensity",
                [logEPrint, developed, planBuffers.printCurve, planBuffers.params],
                library: library, width: width, height: height
            )
            cmyPrint = developed
        }

        // --- the scanning stage --------------------------------------------
        var xyz = try pool.acquire()
        try dispatch(
            context, "filmScanXYZ",
            [
                cmyPrint,
                xyz,
                planBuffers.scanChannelDensity,
                planBuffers.scanBaseDensity,
                planBuffers.scanIlluminant,
                planBuffers.colourMatchingFunctions,
                planBuffers.params,
            ],
            library: library, width: width, height: height
        )

        // The glare of the print, added to the tristimulus values.
        let glare = plan.params.printRender.glare
        if glare.active, glare.percent > 0 {
            let field = try pool.acquire()
            try dispatch(
                context, "filmGlareField",
                [
                    field,
                    try smallBuffer(
                        FilmGlareParams(
                            width: width,
                            height: height,
                            seed: UInt32(truncatingIfNeeded: StochasticSeed.glare(
                                seed: plan.params.stochastic.seed
                            )),
                            mean: Float(glare.percent),
                            std: Float(glare.roughness * glare.percent)
                        )
                    ),
                ],
                library: library, width: width, height: height
            )
            var blurred = field
            if glare.blur > 0 {
                let destination = try pool.acquire()
                try applyBlur(
                    context, source: field, destination: destination,
                    sigmas: [glare.blur], width: width, height: height,
                    library: library, pool: pool
                )
                blurred = destination
            }
            let illuminant = Glare.illuminantXYZ(
                scanIlluminant: plan.scanIlluminant.map { Double($0) },
                colourMatchingFunctions: stride(
                    from: 0, to: plan.colourMatchingFunctions.count, by: 3
                ).map { offset in
                    (0..<3).map { Double(plan.colourMatchingFunctions[offset + $0]) }
                },
                normalization: Double(plan.scanNormalization)
            )
            let illuminantValues = illuminant.map { Float($0) }
            guard let illuminantBuffer = device.makeBuffer(
                bytes: illuminantValues,
                length: illuminantValues.count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ) else {
                throw MetalBackendError.commandFailed(
                    "the buffer of the illuminant could not be allocated"
                )
            }
            let glared = try pool.acquire()
            try dispatch(
                context, "filmGlareApply",
                [
                    xyz,
                    blurred,
                    illuminantBuffer,
                    glared,
                    planBuffers.params,
                ],
                library: library, width: width, height: height
            )
            xyz = glared
        }

        var rgb = try pool.acquire()
        try dispatch(
            context, "filmXYZToRGB",
            [xyz, rgb, planBuffers.xyzToRGB, planBuffers.params],
            library: library, width: width, height: height
        )

        // The output gamut compression.
        if let cMax = planBuffers.cMax {
            let compressed = try pool.acquire()
            try dispatch(
                context, "filmGamutCompress",
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
            let blurred = try pool.acquire()
            try applyBlur(
                context, source: rgb, destination: blurred,
                sigmas: [plan.params.scanner.lensBlur],
                width: width, height: height, library: library, pool: pool
            )
            rgb = blurred
        }

        // The unsharp mask of the scanner.
        let unsharpAmount = plan.params.scanner.unsharpMaskAmount
        let unsharpSigma = plan.params.scanner.unsharpMaskSigma
        if unsharpSigma > 0, unsharpAmount > 0 {
            let blurred = try pool.acquire()
            try applyBlur(
                context, source: rgb, destination: blurred, sigmas: [unsharpSigma],
                width: width, height: height, library: library, pool: pool
            )
            let sharpened = try pool.acquire()
            try dispatch(
                context, "filmCombine2",
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
        let output = try pool.acquire()
        try dispatch(
            context, "filmEncodeOutput",
            [rgb, output, planBuffers.srgbToSRGB, planBuffers.params],
            library: library, width: width, height: height
        )

        // The completion of the render: the wait is bounded, and the
        // status and the error of the command buffer are checked.
        try context.finish()

        // The read back.
        let contents = output.contents().bindMemory(to: Float.self, capacity: count)
        var values = [Double](repeating: 0, count: count)
        for index in 0..<count {
            values[index] = Double(contents[index])
        }
        let rgbOut = RGBImage(width: width, height: height, data: values)
        guard collectTaps else {
            let empty = RGBImage(width: 0, height: 0, data: [])
            return MetalRenderTaps(
                logEFilm: empty, cmyFilm: empty, logEPrint: empty, cmyPrint: empty,
                rgbOut: rgbOut
            )
        }
        return MetalRenderTaps(
            logEFilm: readBack(logEFilm, width: width, height: height),
            cmyFilm: readBack(cmyFilm, width: width, height: height),
            logEPrint: logEPrintBuffer.map {
                readBack($0, width: width, height: height)
            } ?? RGBImage(width: 0, height: 0, data: []),
            cmyPrint: cmyPrintBuffer.map {
                readBack($0, width: width, height: height)
            } ?? RGBImage(width: 0, height: 0, data: []),
            rgbOut: rgbOut
        )
    }

    /// Reads a buffer of the render back into an image.
    private func readBack(_ buffer: MTLBuffer, width: Int, height: Int) -> RGBImage {
        let count = width * height * 3
        let contents = buffer.contents().bindMemory(to: Float.self, capacity: count)
        var values = [Double](repeating: 0, count: count)
        for index in 0..<count {
            values[index] = Double(contents[index])
        }
        return RGBImage(width: width, height: height, data: values)
    }

    // MARK: - The passes

    /// Encodes a compute dispatch of the chain.
    ///
    /// In the diagnostic mode the pass is committed on its own command
    /// buffer: the log then shows the time of every kernel, and a kernel
    /// that hangs is reported (with its name) instead of hanging the
    /// whole render.
    private func dispatch(
        _ context: MetalCommandContext,
        _ name: String,
        _ buffers: [MTLBuffer],
        library: MTLLibrary,
        width: Int,
        height: Int
    ) throws {
        let state = try pipeline(named: name, library: library)
        let encoder = try context.encoder()
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
        if context.diagnostic {
            try context.commit(stage: name)
        }
    }

    /// Encodes a compute dispatch of **one thread per row**.
    ///
    /// The Young & van Vliet recursion is sequential along the axis of the
    /// filter: a thread owns a whole row (the horizontal pass) or a whole
    /// column (the vertical pass).  The thread group holds thirty two
    /// threads (the thread execution width of the Apple GPUs).
    ///
    /// - Parameters:
    ///   - context: the context of the render.
    ///   - name: the name of the kernel.
    ///   - buffers: the buffers of the kernel, in the order of its
    ///     bindings.
    ///   - library: the compiled shader library.
    ///   - height: the number of rows (one thread per row).
    private func dispatchRows(
        _ context: MetalCommandContext,
        _ name: String,
        _ buffers: [MTLBuffer],
        library: MTLLibrary,
        height: Int
    ) throws {
        let state = try pipeline(named: name, library: library)
        let encoder = try context.encoder()
        encoder.setComputePipelineState(state)
        for (index, buffer) in buffers.enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
        encoder.dispatchThreads(
            MTLSize(width: 1, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 32, depth: 1)
        )
        if context.diagnostic {
            try context.commit(stage: name)
        }
    }

    /// Encodes a compute dispatch of **one thread per column**.
    ///
    /// - Parameters:
    ///   - context: the context of the render.
    ///   - name: the name of the kernel.
    ///   - buffers: the buffers of the kernel, in the order of its
    ///     bindings.
    ///   - library: the compiled shader library.
    ///   - width: the number of columns (one thread per column).
    private func dispatchColumns(
        _ context: MetalCommandContext,
        _ name: String,
        _ buffers: [MTLBuffer],
        library: MTLLibrary,
        width: Int
    ) throws {
        let state = try pipeline(named: name, library: library)
        let encoder = try context.encoder()
        encoder.setComputePipelineState(state)
        for (index, buffer) in buffers.enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
        encoder.dispatchThreads(
            MTLSize(width: width, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1)
        )
        if context.diagnostic {
            try context.commit(stage: name)
        }
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

    /// The number of the threads of the first stage of the maximum
    /// reduction.
    ///
    /// The kernel `filmReduceMaxPartial` of the shading language assumes
    /// **exactly** this number of threads (the constant
    /// `FILM_REDUCE_THREADS` of the shading language): the grid is split in
    /// contiguous blocks, one per thread group, and the threads of a group
    /// stride over their block, so that every value of the field is read
    /// exactly once.
    private static let reduceThreads = 1024

    /// The number of the threads of a thread group of the reduction.
    ///
    /// It must divide ``reduceThreads``: the number of the thread groups
    /// is the number of the blocks of the reduction.
    private static let reduceGroupThreads = 256

    /// The highlight boost of the negative.
    private func applyHighlightBoost(
        _ context: MetalCommandContext,
        source: MTLBuffer,
        destination: MTLBuffer,
        plan: FilmRenderPlan,
        planBuffers: MetalPlanBuffers,
        library: MTLLibrary,
        width: Int,
        height: Int
    ) throws {
        let partials = device.makeBuffer(
            length: Self.reduceThreads * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )
        let maximum = device.makeBuffer(
            length: MemoryLayout<Float>.stride, options: .storageModeShared
        )
        guard let partials, let maximum else {
            throw MetalBackendError.commandFailed("the reduction buffers could not be allocated")
        }

        // The first stage of the reduction.
        //
        // The kernel expects exactly `reduceThreads` threads, in groups of
        // `reduceGroupThreads` threads (the constant `FILM_REDUCE_THREADS`
        // of the shading language).
        precondition(
            Self.reduceThreads % Self.reduceGroupThreads == 0,
            "the threads of the reduction must be a whole number of thread groups"
        )
        let partialState = try pipeline(named: "filmReduceMaxPartial", library: library)
        let encoder = try context.encoder()
        encoder.setComputePipelineState(partialState)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(partials, offset: 0, index: 1)
        encoder.setBuffer(planBuffers.params, offset: 0, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: Self.reduceThreads, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: Self.reduceGroupThreads, height: 1, depth: 1)
        )
        if context.diagnostic {
            try context.commit(stage: "filmReduceMaxPartial")
        }

        // The second stage of the reduction.
        let finalState = try pipeline(named: "filmReduceMaxFinal", library: library)
        // The encoder is fetched again: in the diagnostic mode the first
        // stage has been committed (and its encoder ended).
        let finalEncoder = try context.encoder()
        finalEncoder.setComputePipelineState(finalState)
        finalEncoder.setBuffer(partials, offset: 0, index: 0)
        finalEncoder.setBuffer(maximum, offset: 0, index: 1)
        finalEncoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        if context.diagnostic {
            try context.commit(stage: "filmReduceMaxFinal")
        }

        // The boost itself.
        try dispatch(
            context, "filmBoostHighlights",
            [source, destination, maximum, planBuffers.params],
            library: library, width: width, height: height
        )
    }

    /// The separable Gaussian filter.
    ///
    /// The path of the filter is the one of the CPU reference
    /// (`SpatialEffects`): the truncated FIR kernel for the channels whose
    /// sigma is below three pixels, the Young & van Vliet recursion for the
    /// others.  The recursion is sequential along the axis of the filter,
    /// so its passes are dispatched with one thread per row (the horizontal
    /// pass) and one thread per column (the vertical pass).
    private func applyBlur(
        _ context: MetalCommandContext,
        source: MTLBuffer,
        destination: MTLBuffer,
        sigmas: [Double],
        width: Int,
        height: Int,
        library: MTLLibrary,
        pool: MetalBufferPool
    ) throws {
        let plan = MetalKernels.blur(sigmas: sigmas)
        guard let kernelBuffer = device.makeBuffer(
            bytes: plan.kernels, length: plan.kernels.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed("a kernel buffer could not be allocated")
        }
        var blurParams = FilmBlurParams(width: width, height: height, plan: plan)
        guard let paramsBuffer = device.makeBuffer(
            bytes: &blurParams, length: MemoryLayout<FilmBlurParams>.stride,
            options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed("a parameter buffer could not be allocated")
        }
        let temporary = try pool.acquire()
        if plan.usesIIR {
            try dispatchRows(
                context, "filmBlurIIRHorizontal",
                [source, temporary, kernelBuffer, paramsBuffer],
                library: library, height: height
            )
            try dispatchColumns(
                context, "filmBlurIIRVertical",
                [temporary, destination, kernelBuffer, paramsBuffer],
                library: library, width: width
            )
        } else {
            try dispatch(
                context, "filmBlurHorizontal",
                [source, temporary, kernelBuffer, paramsBuffer],
                library: library, width: width, height: height
            )
            try dispatch(
                context, "filmBlurVertical",
                [temporary, destination, kernelBuffer, paramsBuffer],
                library: library, width: width, height: height
            )
        }
        pool.release(temporary)
    }

    /// The exponential surrogate of the isotropic 2D exponential PSF.
    private func applyExponentialFilter(
        _ context: MetalCommandContext,
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
            let component = try pool.acquire()
            try applyBlur(
                context, source: source, destination: component, sigmas: sigmas,
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
            context, "filmCombine3",
            [components[0], components[1], components[2], destination, paramsBuffer],
            library: library, width: width, height: height
        )
        for component in components {
            pool.release(component)
        }
    }

    /// The two dimensional convolution of a diffusion filter.
    private func applyDiffusionFilter(
        _ context: MetalCommandContext,
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
            context, "filmDiffusionFilter",
            [source, destination, psfBuffer, paramsBuffer],
            library: library, width: width, height: height
        )
    }

    /// The in emulsion scatter and the back reflection halation.
    private func applyHalation(
        _ context: MetalCommandContext,
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
                let blurred = try pool.acquire()
                try applyBlur(
                    context, source: current, destination: blurred,
                    sigmas: corePixels.map { max($0, 1e-6) },
                    width: width, height: height, library: library, pool: pool
                )
                core = blurred
            }
            var tail = current
            if hasTail {
                let filtered = try pool.acquire()
                try applyExponentialFilter(
                    context, source: current, destination: filtered,
                    decay: tailPixels.map { max($0, 1e-6) },
                    width: width, height: height, library: library, pool: pool
                )
                tail = filtered
            }
            let scattered = try pool.acquire()
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
                context, "filmScatterCombine",
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
                let component = try pool.acquire()
                try applyBlur(
                    context, source: current, destination: component, sigmas: sigma,
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
            let bloom = try pool.acquire()
            try dispatch(
                context, "filmCombine3",
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
                context, "filmHalationCombine",
                [current, bloom, destination, halationBuffer],
                library: library, width: width, height: height
            )
        } else {
            // Without the halation the image is unchanged: the destination is
            // filled with the source by a copy pass.
            try dispatch(
                context, "filmCombine2",
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
