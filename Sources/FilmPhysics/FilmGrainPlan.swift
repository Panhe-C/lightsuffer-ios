//
//  FilmGrainPlan.swift
//  light suffer胶片 — iOS app
//
//  The plan of the grain of the negative: the precomputed data of the
//  stochastic particle model, and the **pure Swift reference** of the GPU
//  implementation.
//
//  The CPU reference (``Grain``) draws its variates from a sequential
//  stream, so it cannot run on a GPU: the order of the pixels is not
//  defined there.  The GPU port therefore draws the same variates from the
//  **counter based** generator of ``FilmCounterRandom`` — the same
//  distributions, a different realisation.
//
//  This file is the executable specification of the Metal kernels
//  `filmGrainLayers`, `filmGrainSumLayers`, `filmGrainClumping` and
//  `filmCombineMultiply` of `Shaders/FilmShaders.metal`: the pure Swift
//  reference below computes the very same field, and the Linux test compares
//  it with the grain of the CPU reference through the statistical gate of
//  the slice 6.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The precomputed data of the grain of the negative.
///
/// The plan holds everything the GPU needs that does not depend on the
/// pixels of the image:
///
/// * the curves of the emulsion layers (the interpolation of the density of
///   a pixel between the layers),
/// * the maximum density of every layer,
/// * the number of particles a pixel holds,
/// * the optical density of a single particle,
/// * the sigma of the blur of the dye clouds.
///
/// The values are stored in `Float32`: they are the payload of the GPU
/// buffers, so the pure Swift reference (``apply(densityCMY:width:height:)``)
/// and the Metal kernel see exactly the same numbers.
public struct FilmGrainPlan: Sendable {

    /// The number of the emulsion layers.
    public static let layerCount = 3

    /// The number of the colour channels.
    public static let channelCount = 3

    /// The parameters of the grain.
    public var params: GrainParams

    /// The number of the samples of the density curves.
    public var sampleCount: Int

    /// The density curves of the emulsion layers, `[sample][layer][channel]`.
    ///
    /// The index of a value is `(sample * layerCount + layer) * channelCount
    /// + channel`.
    public var layerCurves: [Float]

    /// The normalised density curves of the film, `[channel][sample]`.
    ///
    /// They are the axis of the interpolation of the density of a pixel
    /// between the layers.
    public var normalisedCurves: [Float]

    /// The maximum density of every layer, `[layer][channel]`, with the
    /// minimum density of the layer added.
    public var densityMaxLayers: [Float]

    /// The minimum density of every layer, `[layer][channel]`.
    public var densityMinLayers: [Float]

    /// The number of particles a pixel holds, `[layer][channel]`.
    public var nParticlesPerPixel: [Float]

    /// The optical density of a single particle, `[layer][channel]`.
    public var odParticle: [Float]

    /// The sigma of the blur of the dye clouds of every layer,
    /// `[layer][channel]`, in pixels.
    public var blurSigma: [Float]

    /// The minimum density of the grain, per channel.
    public var densityMin: [Float]

    /// The uniformity of the emulsion, per channel.
    public var uniformity: [Float]

    /// The sigma of the micro structure of the emulsion.
    public var microStructureSigma: Float

    /// The blur of the micro structure of the emulsion, in pixels.
    public var microStructureBlur: Float

    /// Whether the emulsion is a positive (slide) stock.
    public var positiveFilm: Bool

    public init(
        params: GrainParams,
        sampleCount: Int,
        layerCurves: [Float],
        normalisedCurves: [Float],
        densityMaxLayers: [Float],
        densityMinLayers: [Float],
        nParticlesPerPixel: [Float],
        odParticle: [Float],
        blurSigma: [Float],
        densityMin: [Float],
        uniformity: [Float],
        microStructureSigma: Float,
        microStructureBlur: Float,
        positiveFilm: Bool
    ) {
        self.params = params
        self.sampleCount = sampleCount
        self.layerCurves = layerCurves
        self.normalisedCurves = normalisedCurves
        self.densityMaxLayers = densityMaxLayers
        self.densityMinLayers = densityMinLayers
        self.nParticlesPerPixel = nParticlesPerPixel
        self.odParticle = odParticle
        self.blurSigma = blurSigma
        self.densityMin = densityMin
        self.uniformity = uniformity
        self.microStructureSigma = microStructureSigma
        self.microStructureBlur = microStructureBlur
        self.positiveFilm = positiveFilm
    }

    // MARK: - The builder

    /// Builds the plan of the grain.
    ///
    /// - Parameters:
    ///   - grain: the parameters of the grain.
    ///   - film: the profile of the negative.
    ///   - pixelSizeUM: the size of a pixel of the negative, in micrometres.
    /// - Returns: the plan of the grain.
    public static func build(
        grain: GrainParams,
        film: Profile,
        pixelSizeUM: Double
    ) -> FilmGrainPlan {
        let normalised = DensityCurves.normalized(film.data.densityCurves)
        let samples = normalised.count
        let layers = film.data.densityCurvesLayers

        // The axis of the interpolation: the normalised density curve of the
        // channel (mirrored for a positive emulsion).
        let positive = film.info.type == .positive
        var axis = [[Double]](repeating: [], count: channelCount)
        for channel in 0..<channelCount {
            var values = [Double](repeating: 0, count: samples)
            for sample in 0..<samples where channel < normalised[sample].count {
                values[sample] = positive
                    ? -normalised[sample][channel]
                    : normalised[sample][channel]
            }
            axis[channel] = values
        }

        // The maximum density of every layer of every channel.
        var densityMaxLayers = [[Double]](
            repeating: [Double](repeating: 0, count: channelCount), count: layerCount
        )
        for layer in 0..<layerCount {
            for channel in 0..<channelCount {
                var maximum = -Double.infinity
                for sample in 0..<samples where sample < layers.count
                    && layer < layers[sample].count && channel < layers[sample][layer].count {
                    let value = layers[sample][layer][channel]
                    if !value.isNaN { maximum = Swift.max(maximum, value) }
                }
                densityMaxLayers[layer][channel] = maximum.isFinite ? maximum : 0
            }
        }

        // The total of every channel (over the layers) and the fractions of
        // the maximum density every layer holds.
        var densityMaxTotal = [Double](repeating: 0, count: channelCount)
        for layer in 0..<layerCount {
            for channel in 0..<channelCount {
                densityMaxTotal[channel] += densityMaxLayers[layer][channel]
            }
        }
        var densityMaxFractions = [[Double]](
            repeating: [Double](repeating: 0, count: channelCount), count: layerCount
        )
        for layer in 0..<layerCount {
            for channel in 0..<channelCount {
                let total = densityMaxTotal[channel]
                densityMaxFractions[layer][channel] = total != 0
                    ? densityMaxLayers[layer][channel] / total
                    : 0
            }
        }

        // The minimum density of every layer.
        var densityMinLayers = [[Double]](
            repeating: [Double](repeating: 0, count: channelCount), count: layerCount
        )
        for layer in 0..<layerCount {
            for channel in 0..<channelCount {
                densityMinLayers[layer][channel] =
                    densityMaxFractions[layer][channel] * grain.densityMin[channel]
            }
        }

        // The maximum density of every layer, with its minimum density added.
        for layer in 0..<layerCount {
            for channel in 0..<channelCount {
                densityMaxLayers[layer][channel] += densityMinLayers[layer][channel]
            }
        }

        // The number of particles a pixel holds, per layer and per channel.
        let pixelArea = pixelSizeUM * pixelSizeUM
        var nParticlesPerPixel = [[Double]](
            repeating: [Double](repeating: 0, count: channelCount), count: layerCount
        )
        for layer in 0..<layerCount {
            for channel in 0..<channelCount {
                let particleArea = grain.particleAreaUM2
                    * grain.particleScale[channel]
                    * grain.particleScaleLayers[layer]
                nParticlesPerPixel[layer][channel] = particleArea != 0
                    ? pixelArea * densityMaxFractions[layer][channel] / particleArea
                    : 0
            }
        }

        // The optical density of a single particle and the blur of the dye
        // clouds it causes.
        var odParticle = [[Double]](
            repeating: [Double](repeating: 0, count: channelCount), count: layerCount
        )
        var blurSigma = [[Double]](
            repeating: [Double](repeating: 0, count: channelCount), count: layerCount
        )
        for layer in 0..<layerCount {
            for channel in 0..<channelCount {
                let od = nParticlesPerPixel[layer][channel] != 0
                    ? densityMaxLayers[layer][channel] / nParticlesPerPixel[layer][channel]
                    : 0
                odParticle[layer][channel] = od
                blurSigma[layer][channel] = grain.blurDyeCloudsUM * od.squareRoot()
            }
        }

        // The micro structure of the emulsion.
        var microStructureSigma: Float = 0
        var microStructureBlur: Float = 0
        if grain.microStructure.count >= 2, pixelSizeUM > 0 {
            microStructureBlur = Float(grain.microStructure[0] / pixelSizeUM)
            microStructureSigma = Float(grain.microStructure[1] * 0.001 / pixelSizeUM)
        }

        // The curves, in `Float32`.
        var layerCurveValues = [Float](
            repeating: 0, count: max(samples, 0) * layerCount * channelCount
        )
        for sample in 0..<samples where sample < layers.count {
            for layer in 0..<layerCount where layer < layers[sample].count {
                for channel in 0..<channelCount where channel < layers[sample][layer].count {
                    let index = (sample * layerCount + layer) * channelCount + channel
                    layerCurveValues[index] = Float(layers[sample][layer][channel])
                }
            }
        }
        var normalisedValues = [Float](repeating: 0, count: channelCount * max(samples, 0))
        for channel in 0..<channelCount {
            for sample in 0..<samples where channel < normalised[sample].count {
                normalisedValues[channel * samples + sample] = Float(normalised[sample][channel])
            }
        }

        return FilmGrainPlan(
            params: grain,
            sampleCount: samples,
            layerCurves: layerCurveValues,
            normalisedCurves: normalisedValues,
            densityMaxLayers: densityMaxLayers.flatMap { $0.map { Float($0) } },
            densityMinLayers: densityMinLayers.flatMap { $0.map { Float($0) } },
            nParticlesPerPixel: nParticlesPerPixel.flatMap { $0.map { Float($0) } },
            odParticle: odParticle.flatMap { $0.map { Float($0) } },
            blurSigma: blurSigma.flatMap { $0.map { Float($0) } },
            densityMin: grain.densityMin.map { Float($0) },
            uniformity: grain.uniformity.map { Float($0) },
            microStructureSigma: microStructureSigma,
            microStructureBlur: microStructureBlur,
            positiveFilm: positive
        )
    }

    // MARK: - The reference implementation

    /// Applies the grain to the developed densities.
    ///
    /// This is the **pure Swift reference** of the GPU path: it computes the
    /// very same field as the Metal kernels, with the counter based
    /// generator instead of the sequential one of the CPU reference.
    ///
    /// - Parameters:
    ///   - densityCMY: the developed densities, three interleaved values per
    ///     pixel.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    ///   - seed: the seed of the pipeline.
    /// - Returns: the densities with the grain.
    public func apply(
        densityCMY: [Double],
        width: Int,
        height: Int,
        seed: UInt64
    ) -> [Double] {
        guard params.active else { return densityCMY }
        guard !densityCMY.isEmpty, width > 0, height > 0 else { return densityCMY }
        guard params.sublayersActive else {
            // The single layer model of the upstream is not ported to the
            // GPU (the upstream default is the sub layer model).
            return densityCMY
        }
        let pixels = width * height

        // --- the layers -------------------------------------------------
        var output = [Double](repeating: 0, count: densityCMY.count)
        for channel in 0..<Self.channelCount {
            let planes = interpolateLayers(
                channel: channel, densityCMY: densityCMY, width: width, height: height
            )
            for layer in 0..<Self.layerCount {
                var plane = planes[layer]
                let minimum = Double(densityMinLayers[layer * Self.channelCount + channel])
                for index in 0..<plane.count { plane[index] += minimum }
                let grain = particleModel(
                    plane: plane,
                    layer: layer,
                    channel: channel,
                    width: width,
                    height: height,
                    seed: seed
                )
                for index in 0..<plane.count {
                    output[index * Self.channelCount + channel] += grain[index]
                }
            }
        }

        // --- the micro structure ----------------------------------------
        if microStructureSigma > 0.05 {
            let seed32 = UInt32(truncatingIfNeeded: StochasticSeed.grainLayer(
                seed: seed, channel: Self.channelCount, layer: 0
            ))
            var clumping = [Double](repeating: 0, count: densityCMY.count)
            for pixel in 0..<pixels {
                for channel in 0..<Self.channelCount {
                    let value = FilmCounterRandom.lognormalFromMeanStd(
                        mean: 1.0,
                        std: microStructureSigma,
                        seed: seed32,
                        pixel: UInt32(pixel),
                        layer: 0,
                        channel: UInt32(channel)
                    )
                    clumping[pixel * Self.channelCount + channel] = Double(value)
                }
            }
            if microStructureBlur > 0.4 {
                clumping = SpatialEffects.gaussianFilter(
                    rgb: clumping, width: width, height: height, sigma: Double(microStructureBlur)
                )
            }
            for index in 0..<output.count { output[index] *= clumping[index] }
        }

        // --- the minimum density ------------------------------------------
        for pixel in 0..<pixels {
            for channel in 0..<Self.channelCount {
                output[pixel * Self.channelCount + channel] -= Double(densityMin[channel])
            }
        }

        // --- the final blur ------------------------------------------------
        if params.blur > 0 {
            output = SpatialEffects.gaussianFilter(
                rgb: output, width: width, height: height, sigma: params.blur
            )
        }
        return output
    }

    /// The particle model of one layer of one channel.
    ///
    /// - Parameters:
    ///   - plane: the density of the layer, one value per pixel.
    ///   - layer: the index of the emulsion layer.
    ///   - channel: the index of the colour channel.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    ///   - seed: the seed of the pipeline.
    /// - Returns: the density of the developed grains, one value per pixel.
    private func particleModel(
        plane: [Double],
        layer: Int,
        channel: Int,
        width: Int,
        height: Int,
        seed: UInt64
    ) -> [Double] {
        let pixelCount = width * height
        let index = layer * Self.channelCount + channel
        let densityMax = Double(densityMaxLayers[index])
        let nParticles = Double(nParticlesPerPixel[index])
        let uniformity = Double(uniformity[channel])
        let od = Double(odParticle[index])
        let seed32 = UInt32(truncatingIfNeeded: StochasticSeed.grainLayer(
            seed: seed, channel: channel, layer: layer
        ))

        var grain = [Double](repeating: 0, count: pixelCount)
        for pixel in 0..<pixelCount {
            let value = Swift.min(Swift.max(plane[pixel] / densityMax, 1e-6), 1.0 - 1e-6)
            let saturation = 1.0 - value * uniformity * (1.0 - 1e-6)
            let particles = FilmCounterRandom.poisson(
                lambda: Float(nParticles / saturation),
                seed: seed32,
                pixel: UInt32(pixel),
                layer: UInt32(layer),
                channel: UInt32(channel)
            )
            let developed = FilmCounterRandom.binomial(
                n: particles,
                p: Float(value),
                seed: seed32,
                pixel: UInt32(pixel),
                layer: UInt32(layer),
                channel: UInt32(channel)
            )
            grain[pixel] = Double(developed) * od * saturation
        }

        // The blur of the dye clouds.
        let sigma = Double(blurSigma[index])
        if sigma > 0 {
            grain = SpatialEffects.filterPlane(
                grain, width: width, height: height, sigma: sigma
            )
        }
        return grain
    }

    /// Splits the density of the pixels between the emulsion layers.
    ///
    /// This is the same interpolation as the one of the CPU reference
    /// (``Grain/interpolateLayers``); it is repeated here so that the plan
    /// holds the whole data the GPU needs.
    ///
    /// - Parameters:
    ///   - channel: the index of the channel.
    ///   - densityCMY: the densities, three interleaved values per pixel.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    /// - Returns: the density of every layer, one plane per layer.
    func interpolateLayers(
        channel: Int,
        densityCMY: [Double],
        width: Int,
        height: Int
    ) -> [[Double]] {
        let samples = sampleCount
        let pixels = width * height
        var planes = [[Double]](
            repeating: [Double](repeating: 0, count: pixels), count: Self.layerCount
        )
        guard samples > 0 else { return planes }

        // The axis of the interpolation.
        var axis = [Double](repeating: 0, count: samples)
        for sample in 0..<samples {
            let value = Double(normalisedCurves[channel * samples + sample])
            axis[sample] = positiveFilm ? -value : value
        }
        var inverseStep = [Double](repeating: 0, count: max(samples - 1, 0))
        for sample in 0..<max(samples - 1, 0) {
            let step = axis[sample + 1] - axis[sample]
            inverseStep[sample] = step != 0 ? 1.0 / step : 0
        }

        for pixel in 0..<pixels {
            let density = densityCMY[pixel * Self.channelCount + channel]
            let x = positiveFilm ? -density : density
            if x <= axis[0] {
                for layer in 0..<Self.layerCount {
                    planes[layer][pixel] = Double(
                        layerCurves[(0 * Self.layerCount + layer) * Self.channelCount + channel]
                    )
                }
            } else if x >= axis[samples - 1] {
                for layer in 0..<Self.layerCount {
                    planes[layer][pixel] = Double(
                        layerCurves[
                            ((samples - 1) * Self.layerCount + layer) * Self.channelCount + channel
                        ]
                    )
                }
            } else {
                let index = Numerics.searchSortedRight(axis, x)
                let low = index - 1
                let t = (x - axis[low]) * inverseStep[low]
                for layer in 0..<Self.layerCount {
                    let yLow = Double(
                        layerCurves[(low * Self.layerCount + layer) * Self.channelCount + channel]
                    )
                    let yHigh = Double(
                        layerCurves[((low + 1) * Self.layerCount + layer) * Self.channelCount + channel]
                    )
                    planes[layer][pixel] = yLow + t * (yHigh - yLow)
                }
            }
        }
        return planes
    }
}
