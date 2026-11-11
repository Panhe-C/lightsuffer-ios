//
//  MetalPlan.swift
//  light suffer胶片 — iOS app
//
//  The bridge between the render plan of `FilmPhysics` and the Metal
//  buffers: the structures the shaders read and the builders of the
//  convolution kernels.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

#if canImport(Metal)

import Foundation
import Metal
import FilmPhysics

// MARK: - The parameters of the shaders

/// The parameters of a render.
///
/// The layout mirrors **exactly** the `FilmPlanParams` structure of
/// `Shaders/FilmShaders.metal`: every member is four bytes wide, so the two
/// structures have the same size and the same offsets.
struct FilmPlanParams {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var tcLUTSize: UInt32 = 0
    var wavelengthCount: UInt32 = 0
    var filmCurveCount: UInt32 = 0
    var printCurveCount: UInt32 = 0
    var cMaxLightnessCount: UInt32 = 0
    var cMaxHueCount: UInt32 = 0
    var filmCurveStart: Float = 0
    var filmCurveStep: Float = 0
    var filmCurveBeforeStart: Float = 0
    var filmCurveBeforeStep: Float = 0
    var printCurveStart: Float = 0
    var printCurveStep: Float = 0
    var exposureScale: Float = 0
    var filmingScale: Float = 0
    var couplerActive: Float = 0
    var couplerPositive: Float = 0
    var exposureFactor: Float = 0
    var printExposure: Float = 0
    var printingCorrection: Float = 0
    var scanNormalization: Float = 0
    var gamutActive: Float = 0
    var lightnessActive: Float = 0
    var gamutKneeThreshold: Float = 0
    var gamutKneeLimit: Float = 0
    var gamutKneePower: Float = 0
    var lightnessKneeThreshold: Float = 0
    var lightnessKneeLimit: Float = 0
    var lightnessKneePower: Float = 0
    var cam16LA: Float = 0
    var cam16Yb: Float = 0
    var cam16WhiteJp: Float = 0
    var whiteX: Float = 0
    var whiteY: Float = 0
    var whiteZ: Float = 0
    var correctionSlope: Float = 1
    var correctionOffset: Float = 0
    var correctionActive: Float = 0
    var inputCCTF: Float = 0
    var outputEncoded: Float = 0
    var cMaxLightnessStart: Float = 0
    var cMaxLightnessStep: Float = 0
    var cMaxHueStart: Float = 0
    var cMaxHueStep: Float = 0
    var boostEV: Float = 0
    var boostRange: Float = 0
    var protectEV: Float = 0

    /// The parameters of a render, built from the plan.
    ///
    /// - Parameters:
    ///   - plan: the precomputed data of the render.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    init(plan: FilmRenderPlan, width: Int, height: Int) {
        self.width = UInt32(width)
        self.height = UInt32(height)
        self.tcLUTSize = UInt32(plan.tcLUTSize)
        self.wavelengthCount = UInt32(plan.filmBaseDensity.count)
        self.filmCurveCount = UInt32(plan.filmCurve.count)
        self.printCurveCount = UInt32(plan.printCurve.count)
        self.filmCurveStart = plan.filmCurve.start
        self.filmCurveStep = plan.filmCurve.step
        self.filmCurveBeforeStart = plan.filmCurveBeforeCouplers.start
        self.filmCurveBeforeStep = plan.filmCurveBeforeCouplers.step
        self.printCurveStart = plan.printCurve.start
        self.printCurveStep = plan.printCurve.step
        self.exposureScale = plan.exposureScale
        self.filmingScale = plan.filmingScale
        self.couplerActive = plan.couplersActive ? 1 : 0
        self.couplerPositive = plan.couplerPositive ? 1 : 0
        self.exposureFactor = plan.exposureFactor
        self.printExposure = plan.printExposure
        self.printingCorrection = plan.printingExposureCorrection
        self.scanNormalization = plan.scanNormalization
        self.inputCCTF = Float(plan.inputCCTF)
        self.outputEncoded = plan.outputEncoded ? 1 : 0
        self.boostEV = plan.boostEV
        self.boostRange = plan.boostRange
        self.protectEV = plan.protectEV
        if plan.colorReferenceSlope != 1 || plan.colorReferenceOffset != 0 {
            self.correctionActive = 1
            self.correctionSlope = plan.colorReferenceSlope
            self.correctionOffset = plan.colorReferenceOffset
        }
        if let gamut = plan.gamutCompression {
            self.gamutActive = 1
            self.gamutKneeThreshold = Float(gamut.knee.threshold)
            self.gamutKneeLimit = Float(gamut.knee.limit)
            self.gamutKneePower = Float(gamut.knee.power)
            if let lightness = gamut.lightnessKnee {
                self.lightnessActive = 1
                self.lightnessKneeThreshold = Float(lightness.threshold)
                self.lightnessKneeLimit = Float(lightness.limit)
                self.lightnessKneePower = Float(lightness.power)
            }
            self.cam16LA = gamut.la
            self.cam16Yb = gamut.yb
            self.cam16WhiteJp = gamut.whiteJp
            self.whiteX = gamut.whiteXYZ.count > 0 ? gamut.whiteXYZ[0] : 0
            self.whiteY = gamut.whiteXYZ.count > 1 ? gamut.whiteXYZ[1] : 0
            self.whiteZ = gamut.whiteXYZ.count > 2 ? gamut.whiteXYZ[2] : 0
            self.cMaxLightnessCount = UInt32(gamut.cMaxLightnessCount)
            self.cMaxHueCount = UInt32(gamut.cMaxHueCount)
            self.cMaxLightnessStart = gamut.cMaxLightnessStart
            self.cMaxLightnessStep = gamut.cMaxLightnessStep
            self.cMaxHueStart = gamut.cMaxHueStart
            self.cMaxHueStep = gamut.cMaxHueStep
        }
    }
}

/// The parameters of the convolutions.
struct FilmBlurParams {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var radius: UInt32 = 0
    var reserved: UInt32 = 0
    var weightA: Float = 0
    var weightB: Float = 0
    var weightC: Float = 0
    var scatterFraction: Float = 0

    init(width: Int, height: Int, radius: Int) {
        self.width = UInt32(width)
        self.height = UInt32(height)
        self.radius = UInt32(radius)
    }
}

/// The parameters of the linear combinations.
struct FilmCombineParams {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var weightA: Float = 0
    var weightB: Float = 0
    var weightC: Float = 0
    var weightD: Float = 0

    init(
        width: Int,
        height: Int,
        weightA: Float = 0,
        weightB: Float = 0,
        weightC: Float = 0,
        weightD: Float = 0
    ) {
        self.width = UInt32(width)
        self.height = UInt32(height)
        self.weightA = weightA
        self.weightB = weightB
        self.weightC = weightC
        self.weightD = weightD
    }
}

/// The parameters of the exposure (the linear to log10 conversion).
struct FilmExposureParams {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var scale: Float = 0
    var offset: Float = 0

    init(width: Int, height: Int, scale: Float, offset: Float = 0) {
        self.width = UInt32(width)
        self.height = UInt32(height)
        self.scale = scale
        self.offset = offset
    }
}

/// The parameters of the grain of the negative.
///
/// The layout mirrors **exactly** the `FilmGrainParams` structure of
/// `Shaders/FilmShaders.metal`.
struct FilmGrainParams {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var sampleCount: UInt32 = 0
    var layerCount: UInt32 = 0
    var positive: UInt32 = 0
    var reserved: UInt32 = 0

    init(width: Int, height: Int, sampleCount: Int, layerCount: Int, positive: Bool) {
        self.width = UInt32(width)
        self.height = UInt32(height)
        self.sampleCount = UInt32(sampleCount)
        self.layerCount = UInt32(layerCount)
        self.positive = positive ? 1 : 0
    }
}

/// The parameters of the micro structure of the emulsion.
///
/// The layout mirrors **exactly** the `FilmGrainClumpingParams` structure
/// of `Shaders/FilmShaders.metal`.
struct FilmGrainClumpingParams {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var seed: UInt32 = 0
    var sigma: Float = 0

    init(width: Int, height: Int, seed: UInt32, sigma: Float) {
        self.width = UInt32(width)
        self.height = UInt32(height)
        self.seed = seed
        self.sigma = sigma
    }
}

/// The parameters of the glare of the print.
///
/// The layout mirrors **exactly** the `FilmGlareParams` structure of
/// `Shaders/FilmShaders.metal`.
struct FilmGlareParams {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var seed: UInt32 = 0
    var mean: Float = 0
    var std: Float = 0
    var reserved: Float = 0

    init(width: Int, height: Int, seed: UInt32, mean: Float, std: Float) {
        self.width = UInt32(width)
        self.height = UInt32(height)
        self.seed = seed
        self.mean = mean
        self.std = std
    }
}

// MARK: - The convolution kernels

/// The separable Gaussian kernels of the three channels.
///
/// The kernels are laid out channel major: the kernel of the channel `c` is
/// the slice `c * (2 * radius + 1) ..< (c + 1) * (2 * radius + 1)` and the
/// tap `i` of a kernel is the tap `i - radius` of the convolution.
///
/// The radius is the largest radius of the three channels; the kernels of
/// the channels with a smaller radius are zero padded, which is exactly the
/// identity the CPU reference uses for a radius of zero.
enum MetalKernels {

    /// The maximum radius of a convolution kernel, in pixels.
    ///
    /// The radius of a Gaussian kernel is the truncation of the kernel at
    /// three sigmas: a radius above this bound would mean a blur of more
    /// than three hundred pixels, which is never the case (the diffusion
    /// filters are bounded by the size of the image).  The bound makes the
    /// loops of the kernels **bounded**, whatever the parameters of the
    /// render are: a parameter that is not a number (a `NaN` of a
    /// degenerate profile, an infinite sigma) would otherwise make the
    /// conversion to an integer trap, or the loop of the kernel run for
    /// billions of iterations.
    static let maxBlurRadius = 1024

    /// The separable Gaussian kernels of the given sigmas.
    ///
    /// - Parameter sigmas: the standard deviations, in pixels, one per
    ///   channel (a single value applies to the three channels).
    /// - Returns: the radius and the kernels.
    static func gaussian(sigmas: [Double]) -> (radius: Int, kernels: [Float]) {
        let sigmas = sigmas.count == 1 ? [sigmas[0], sigmas[0], sigmas[0]] : sigmas
        let channels = sigmas.count == 3 ? sigmas : [sigmas[0], sigmas[0], sigmas[0]]
        var radii = [Int](repeating: 0, count: 3)
        var effective = [Double](repeating: 0, count: 3)
        for channel in 0..<3 {
            let sigma = channels[channel]
            // A sigma that is not a positive number is the identity.
            guard sigma.isFinite, sigma > 0 else { continue }
            // The truncation at three sigmas, bounded.
            let bounded = Swift.min(sigma, Double(maxBlurRadius) / 3.0)
            effective[channel] = bounded
            radii[channel] = Int(3.0 * bounded + 0.5)
        }
        let radius = Swift.min(max(max(radii[0], radii[1]), radii[2]), maxBlurRadius)
        let length = 2 * radius + 1
        var kernels = [Float](repeating: 0, count: 3 * length)
        for channel in 0..<3 {
            let (kernel, kernelRadius) = SpatialEffects.gaussianKernel(
                sigma: effective[channel], truncate: 3.0
            )
            if kernelRadius == 0 {
                kernels[channel * length + radius] = 1
                continue
            }
            let offset = radius - kernelRadius
            for index in 0..<kernel.count {
                kernels[channel * length + offset + index] = Float(kernel[index])
            }
        }
        return (radius, kernels)
    }

    /// The point spread function of a diffusion filter.
    ///
    /// - Parameters:
    ///   - params: the parameters of the filter.
    ///   - pixelSizeUM: the size of a pixel of the negative, in micrometres.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    /// - Returns: the radius and the point spread function, channel major.
    static func diffusionFilter(
        params: DiffusionFilterParams,
        pixelSizeUM: Double,
        width: Int,
        height: Int
    ) -> (radius: Int, psf: [Float])? {
        guard params.active, params.strength > 0, params.spatialScale > 0 else { return nil }
        guard pixelSizeUM > 0 else { return nil }
        guard DiffusionFilter.families[params.filterFamily] != nil else { return nil }
        let scatter = DiffusionFilter.scatterFraction(
            strength: params.strength, family: params.filterFamily
        )
        guard scatter > 0 else { return nil }

        // The truncation budget of the kernel: a single 2D exponential has
        // 99.95 % of its energy inside eight decay constants.
        let bloomMaxLambdaPX = DiffusionFilter.bloomMaxLambdaUM(
            params.filterFamily, params: params
        ) * params.spatialScale / pixelSizeUM
        // The radius is bounded (a parameter that is not a number would
        // otherwise trap the conversion, and the loop of the kernel would
        // run for billions of iterations).
        let bounded = Swift.min(
            Swift.max(bloomMaxLambdaPX.isFinite ? 8.0 * bloomMaxLambdaPX : 5.0, 5.0),
            Double(maxBlurRadius)
        )
        var radius = Int(ceil(bounded))
        radius = min(radius, max(min(height, width) / 2 - 1, 1))
        radius = min(radius, maxBlurRadius)
        let shape = 2 * radius + 1
        guard let kernel = DiffusionFilter.psf(
            shape: shape,
            family: params.filterFamily,
            spatialScale: params.spatialScale,
            pixelSizeUM: pixelSizeUM,
            haloWarmth: params.haloWarmth,
            params: params
        ) else { return nil }
        var psf = [Float](repeating: 0, count: 3 * shape * shape)
        for channel in 0..<3 {
            for index in 0..<(shape * shape) {
                psf[channel * shape * shape + index] = Float(kernel[channel][index])
            }
        }
        return (radius, psf)
    }
}

// MARK: - The plan buffers

/// The Metal buffers of the grain of the negative.
///
/// The buffers hold the precomputed data of the stochastic particle model
/// (``FilmGrainPlan``) and the parameters of the kernels.
struct MetalGrainBuffers {

    /// The parameters of the kernel `filmGrainLayers`.
    let params: MTLBuffer
    /// The density curves of the emulsion layers.
    let layerCurves: MTLBuffer
    /// The normalised density curves of the film (the axis of the
    /// interpolation).
    let normalisedCurves: MTLBuffer
    /// The parameters of the layers: the maximum densities, the minimum
    /// densities, the number of particles and the optical density of a
    /// particle, four blocks of nine values (`[layer][channel]`).
    let layerParameters: MTLBuffer
    /// The uniformity of the emulsion, one value per channel.
    let uniformity: MTLBuffer
    /// The seed of every stream, one value per channel and per layer.
    let seeds: MTLBuffer
    /// The minimum density of the grain, one value per channel.
    let densityMin: MTLBuffer
    /// The parameters of the kernel `filmGrainClumping`.
    let clumpingParams: MTLBuffer

    /// Builds the buffers of the grain.
    ///
    /// - Parameters:
    ///   - plan: the precomputed data of the grain.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    ///   - seed: the seed of the pipeline.
    ///   - device: the Metal device.
    init(
        plan: FilmGrainPlan,
        width: Int,
        height: Int,
        seed: UInt64,
        device: MTLDevice
    ) throws {
        func buffer(_ values: [Float]) throws -> MTLBuffer {
            guard !values.isEmpty else {
                throw MetalBackendError.invalidPlan("an empty buffer of the grain")
            }
            guard let buffer = device.makeBuffer(
                bytes: values, length: values.count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ) else {
                throw MetalBackendError.commandFailed("a buffer of the grain could not be allocated")
            }
            return buffer
        }
        var parameters = FilmGrainParams(
            width: width,
            height: height,
            sampleCount: plan.sampleCount,
            layerCount: FilmGrainPlan.layerCount,
            positive: plan.positiveFilm
        )
        guard let parametersBuffer = device.makeBuffer(
            bytes: &parameters, length: MemoryLayout<FilmGrainParams>.stride,
            options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed(
                "the parameter buffer of the grain could not be allocated"
            )
        }
        self.params = parametersBuffer
        self.layerCurves = try buffer(plan.layerCurves)
        self.normalisedCurves = try buffer(plan.normalisedCurves)

        // The parameters of the layers: four blocks of nine values.
        let count = FilmGrainPlan.layerCount * FilmGrainPlan.channelCount
        var layerParameters = [Float](repeating: 0, count: count * 4)
        for index in 0..<count {
            layerParameters[index] = plan.densityMaxLayers[index]
            layerParameters[count + index] = plan.densityMinLayers[index]
            layerParameters[2 * count + index] = plan.nParticlesPerPixel[index]
            layerParameters[3 * count + index] = plan.odParticle[index]
        }
        self.layerParameters = try buffer(layerParameters)
        self.uniformity = try buffer(plan.uniformity)

        // The seed of every stream (the channel and the layer of the
        // emulsion), exactly like the pure Swift reference.
        var seeds = [Float](repeating: 0, count: count)
        for colour in 0..<FilmGrainPlan.channelCount {
            for layer in 0..<FilmGrainPlan.layerCount {
                let derived = StochasticSeed.grainLayer(
                    seed: seed, channel: colour, layer: layer
                )
                seeds[colour * FilmGrainPlan.layerCount + layer] = Float(
                    UInt32(truncatingIfNeeded: derived)
                )
            }
        }
        self.seeds = try buffer(seeds)
        self.densityMin = try buffer(plan.densityMin)

        var clumping = FilmGrainClumpingParams(
            width: width,
            height: height,
            seed: UInt32(truncatingIfNeeded: StochasticSeed.grainLayer(
                seed: seed, channel: FilmGrainPlan.channelCount, layer: 0
            )),
            sigma: plan.microStructureSigma
        )
        guard let clumpingBuffer = device.makeBuffer(
            bytes: &clumping, length: MemoryLayout<FilmGrainClumpingParams>.stride,
            options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed(
                "the parameter buffer of the micro structure could not be allocated"
            )
        }
        self.clumpingParams = clumpingBuffer
    }
}

/// The Metal buffers of a render plan.
struct MetalPlanBuffers {

    let params: MTLBuffer
    let tcLUT: MTLBuffer
    let inputMatrix: MTLBuffer
    let filmCurve: MTLBuffer
    let filmCurveBeforeCouplers: MTLBuffer
    let printCurve: MTLBuffer
    let coupler: MTLBuffer
    let filmChannelDensity: MTLBuffer
    let filmBaseDensity: MTLBuffer
    let printSensitivity: MTLBuffer
    let printIlluminant: MTLBuffer
    let preflash: MTLBuffer
    let scanChannelDensity: MTLBuffer
    let scanBaseDensity: MTLBuffer
    let scanIlluminant: MTLBuffer
    let colourMatchingFunctions: MTLBuffer
    let xyzToRGB: MTLBuffer
    let srgbToSRGB: MTLBuffer
    let gamutRGBToXYZ: MTLBuffer
    let gamutXYZToRGB: MTLBuffer
    let cMax: MTLBuffer?

    /// Builds the buffers of a plan.
    init(plan: FilmRenderPlan, width: Int, height: Int, device: MTLDevice) throws {
        func buffer(_ values: [Float]) throws -> MTLBuffer {
            guard !values.isEmpty else {
                throw MetalBackendError.invalidPlan("an empty buffer of the plan")
            }
            guard let buffer = device.makeBuffer(
                bytes: values, length: values.count * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ) else {
                throw MetalBackendError.commandFailed(
                    "a buffer of the plan could not be allocated"
                )
            }
            return buffer
        }
        var parameters = FilmPlanParams(plan: plan, width: width, height: height)
        guard let parametersBuffer = device.makeBuffer(
            bytes: &parameters, length: MemoryLayout<FilmPlanParams>.stride,
            options: .storageModeShared
        ) else {
            throw MetalBackendError.commandFailed(
                "the parameter buffer of the plan could not be allocated"
            )
        }
        self.params = parametersBuffer
        self.tcLUT = try buffer(plan.tcLUT)
        self.inputMatrix = try buffer(plan.inputRGBToXYZ)
        self.filmCurve = try buffer(plan.filmCurve.values)
        self.filmCurveBeforeCouplers = try buffer(plan.filmCurveBeforeCouplers.values)
        self.printCurve = try buffer(plan.printCurve.values)
        var coupler = plan.couplerMatrix
        coupler.append(contentsOf: plan.densityMax)
        self.coupler = try buffer(coupler)
        self.filmChannelDensity = try buffer(plan.filmChannelDensity)
        self.filmBaseDensity = try buffer(plan.filmBaseDensity)
        self.printSensitivity = try buffer(plan.printSensitivity)
        self.printIlluminant = try buffer(plan.printIlluminant)
        self.preflash = try buffer(plan.preflash)
        self.scanChannelDensity = try buffer(plan.scanChannelDensity)
        self.scanBaseDensity = try buffer(plan.scanBaseDensity)
        self.scanIlluminant = try buffer(plan.scanIlluminant)
        self.colourMatchingFunctions = try buffer(plan.colourMatchingFunctions)
        self.xyzToRGB = try buffer(plan.xyzToRGB)
        self.srgbToSRGB = try buffer(plan.srgbToSRGB)
        self.gamutRGBToXYZ = try buffer(plan.gamutRGBToXYZ)
        self.gamutXYZToRGB = try buffer(plan.gamutXYZToRGB)
        if let gamut = plan.gamutCompression {
            self.cMax = try buffer(gamut.cMax)
        } else {
            self.cMax = nil
        }
    }
}

#endif
