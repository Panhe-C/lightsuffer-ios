//
//  Grain.swift
//  light suffer胶片 — iOS app
//
//  The grain of the negative: the stochastic particle model of the upstream
//  engine.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

// MARK: - The parameters

/// The parameters of the grain of the negative.
///
/// Upstream reference: `spektrafilm.runtime.params_schema.GrainParams`.
///
/// The upstream values are the defaults of the dataclass; the GUI exposes
/// every one of them as a live parameter.
public struct GrainParams: Equatable, Sendable {
    /// Whether the grain is applied at all.
    public var active: Bool
    /// Whether the grain is modelled per emulsion sub layer.
    ///
    /// When it is off, the upstream uses the single layer model
    /// (`apply_grain_to_density`); when it is on (the upstream default), the
    /// three layer model is used (`apply_grain_to_density_layers`).
    public var sublayersActive: Bool
    /// The area of a silver halide particle, in square micrometres.
    public var particleAreaUM2: Double
    /// The per channel scale of the particle area.
    public var particleScale: [Double]
    /// The per sub layer scale of the particle area.
    public var particleScaleLayers: [Double]
    /// The minimum density of the grain, per channel.
    public var densityMin: [Double]
    /// The uniformity of the grain, per channel.
    ///
    /// A value of one is a perfectly uniform emulsion, a lower value spreads
    /// the particle sizes.
    public var uniformity: [Double]
    /// The sigma of the blur of the grain, in pixels.
    public var blur: Double
    /// The blur of the dye clouds of a sub layer, in micrometres.
    public var blurDyeCloudsUM: Double
    /// The micro structure of the grain: the blur of the clumping field, in
    /// micrometres, and the standard deviation of the clumping, in nanometres.
    public var microStructure: [Double]
    /// The number of sub layers of the single layer model.
    public var nSubLayers: Int

    public init(
        active: Bool = true,
        sublayersActive: Bool = true,
        particleAreaUM2: Double = 0.2,
        particleScale: [Double] = [1.6, 1.6, 3.2],
        particleScaleLayers: [Double] = [2.0, 1.0, 0.5],
        densityMin: [Double] = [0.03, 0.03, 0.03],
        uniformity: [Double] = [0.97, 0.99, 0.97],
        blur: Double = 0.65,
        blurDyeCloudsUM: Double = 1.0,
        microStructure: [Double] = [0.2, 30.0],
        nSubLayers: Int = 1
    ) {
        self.active = active
        self.sublayersActive = sublayersActive
        self.particleAreaUM2 = particleAreaUM2
        self.particleScale = particleScale
        self.particleScaleLayers = particleScaleLayers
        self.densityMin = densityMin
        self.uniformity = uniformity
        self.blur = blur
        self.blurDyeCloudsUM = blurDyeCloudsUM
        self.microStructure = microStructure
        self.nSubLayers = nSubLayers
    }
}

// MARK: - The model

/// The grain of the negative: the stochastic particle model of the upstream.
///
/// Upstream reference: `spektrafilm.model.grain`.
///
/// The model develops the emulsion as a population of silver halide
/// particles:
///
/// 1. the density of a pixel is split between the emulsion layers (the
///    `density_curves_layers` of the profile),
/// 2. every layer draws the number of particles it holds from a Poisson
///    distribution and the number of particles that develop from a binomial
///    distribution,
/// 3. the layers are summed, modulated by the micro structure of the
///    emulsion and blurred.
///
/// The upstream draws from the SciPy `poisson` and `binom` generators (the
/// `use_fast_stats` variants of `spektrafilm.utils.fast_stats` are broken for
/// the scalar number of trials the model uses); the port draws from its own
/// seeded generator, with the algorithms of the **fast kernels** of the
/// upstream — i.e. with the normal approximations of the exact generators,
/// not with the exact generators themselves.
///
/// The difference between the two is a **model difference**, and the
/// reference fixture measures it explicitly: the grain is compared with the
/// upstream twice, against the fast kernels (the algorithm the port
/// reproduces) and against the exact SciPy generators (the default path of
/// the upstream), and the difference between the two upstream aggregates is
/// added to the tolerance of the second comparison (in quadrature).  The
/// measured deviations and the list of the statistics they touch are
/// documented in `docs/PORTING.md` (§3.4).
public enum Grain {

    /// The number of channels of the emulsion.
    private static let channels = 3

    /// The number of sub layers of the emulsion model.
    private static let subLayers = 3

    // MARK: - The entry point

    /// Applies the grain of the negative to the developed densities.
    ///
    /// Upstream reference: `spektrafilm.model.grain.apply_grain`.
    ///
    /// - Parameters:
    ///   - densityCMY: the developed densities, three interleaved values per
    ///     pixel.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    ///   - pixelSizeUM: the size of a pixel of the negative, in micrometres.
    ///   - grain: the parameters of the grain.
    ///   - densityCurves: the **normalised** density curves of the film,
    ///     `[sample][channel]`.
    ///   - densityCurvesLayers: the density curves of the emulsion layers of
    ///     the profile, `[sample][channel][layer]`.
    ///   - positiveFilm: `true` for a slide (a positive emulsion).
    ///   - seed: the seed of the random number generator.
    ///   - sampler: the sampler of the variates of the particles: the fast
    ///     kernels of the upstream (the default, the algorithm the port
    ///     reproduces) or the exact generators of the default path of the
    ///     upstream.
    /// - Returns: the densities with the grain, three interleaved values per
    ///   pixel.
    public static func apply(
        densityCMY: [Double],
        width: Int,
        height: Int,
        pixelSizeUM: Double,
        grain: GrainParams,
        densityCurves: [[Double]],
        densityCurvesLayers: [[[Double]]],
        positiveFilm: Bool,
        seed: UInt64,
        sampler: GrainSampler = .fast
    ) -> [Double] {
        guard grain.active else { return densityCMY }
        guard !densityCMY.isEmpty, width > 0, height > 0 else { return densityCMY }
        guard pixelSizeUM > 0 else {
            // Without a pixel size there is no scale for the particles of
            // the emulsion: the grain is a no-op (the upstream always has a
            // positive pixel size).
            return densityCMY
        }

        if !grain.sublayersActive {
            // The maximum density of every channel of the film.
            let densityMaxCurves = (0..<channels).map { channel -> Double in
                var maximum = -Double.infinity
                for sample in densityCurves where sample.count > channel {
                    let value = sample[channel]
                    if !value.isNaN { maximum = Swift.max(maximum, value) }
                }
                return maximum.isFinite ? maximum : 0
            }
            return applyToDensity(
                densityCMY: densityCMY,
                width: width,
                height: height,
                pixelSizeUM: pixelSizeUM,
                grain: grain,
                densityMaxCurves: densityMaxCurves,
                seed: seed,
                sampler: sampler
            )
        }

        guard !densityCurvesLayers.isEmpty else {
            // Without the curves of the emulsion layers there is nothing to
            // split the density into.
            return densityCMY
        }

        return applyToDensityLayers(
            densityCMY: densityCMY,
            width: width,
            height: height,
            pixelSizeUM: pixelSizeUM,
            grain: grain,
            densityCurves: densityCurves,
            densityCurvesLayers: densityCurvesLayers,
            positiveFilm: positiveFilm,
            seed: seed,
            sampler: sampler
        )
    }

    // MARK: - The single layer model

    /// The single layer model of the grain.
    ///
    /// Upstream reference: `spektrafilm.model.grain.apply_grain_to_density`.
    private static func applyToDensity(
        densityCMY: [Double],
        width: Int,
        height: Int,
        pixelSizeUM: Double,
        grain: GrainParams,
        densityMaxCurves: [Double],
        seed: UInt64,
        sampler: GrainSampler
    ) -> [Double] {
        let densityMin = grain.densityMin
        // The maximum density of every channel, with the minimum density of
        // the grain added.
        var densityMax = densityMaxCurves
        for channel in 0..<channels where channel < densityMax.count {
            densityMax[channel] += densityMin[channel]
        }
        let pixelArea = pixelSizeUM * pixelSizeUM
        // The number of particles a pixel of the negative holds.
        var nParticlesPerPixel = [Double](repeating: 0, count: channels)
        for channel in 0..<channels {
            let particleArea = grain.particleAreaUM2 * grain.particleScale[channel]
            nParticlesPerPixel[channel] = pixelArea / particleArea
        }
        if grain.nSubLayers > 1 {
            for channel in 0..<channels {
                nParticlesPerPixel[channel] /= Double(grain.nSubLayers)
            }
        }

        // The upstream adds the minimum density to the densities in place.
        let pixels = width * height
        var density = densityCMY
        for pixel in 0..<pixels {
            for channel in 0..<channels {
                density[pixel * channels + channel] += densityMin[channel]
            }
        }

        var output = [Double](repeating: 0, count: density.count)
        for channel in 0..<channels {
            var plane = [Double](repeating: 0, count: pixels)
            for pixel in 0..<pixels {
                plane[pixel] = density[pixel * channels + channel]
            }
            for layer in 0..<Swift.max(grain.nSubLayers, 0) {
                let grainPlane = layerParticleModel(
                    density: plane,
                    densityMax: densityMax[channel],
                    nParticlesPerPixel: nParticlesPerPixel[channel],
                    uniformity: grain.uniformity[channel],
                    seed: StochasticSeed.grainLayer(seed: seed, channel: channel, layer: layer),
                    blurParticle: 0,
                    width: width,
                    height: height,
                    sampler: sampler
                )
                for pixel in 0..<pixels {
                    output[pixel * channels + channel] += grainPlane[pixel]
                }
            }
        }

        // The upstream divides by the number of sub layers and removes the
        // minimum density again.
        if grain.nSubLayers > 0 {
            let inverse = 1.0 / Double(grain.nSubLayers)
            for index in 0..<output.count { output[index] *= inverse }
        }
        for pixel in 0..<pixels {
            for channel in 0..<channels {
                output[pixel * channels + channel] -= densityMin[channel]
            }
        }

        // The final blur of the grain.
        if grain.blur > 0.4 {
            output = SpatialEffects.gaussianFilter(
                rgb: output, width: width, height: height, sigma: grain.blur
            )
        }
        return output
    }

    // MARK: - The sub layer model

    /// The sub layer model of the grain.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.grain.apply_grain_to_density_layers`.
    ///
    /// The upstream stores the curves of the layers as
    /// `[sample][layer][channel]`, and the arrays of the model are shaped
    /// `[layer][channel]`.
    private static func applyToDensityLayers(
        densityCMY: [Double],
        width: Int,
        height: Int,
        pixelSizeUM: Double,
        grain: GrainParams,
        densityCurves: [[Double]],
        densityCurvesLayers: [[[Double]]],
        positiveFilm: Bool,
        seed: UInt64,
        sampler: GrainSampler
    ) -> [Double] {
        let pixels = width * height
        let densityMin = grain.densityMin

        // The maximum density of every layer of every channel.
        //
        // The upstream stores the curves of the layers as
        // `[sample][layer][channel]`, so the maximum of a layer is taken
        // over the samples.
        var densityMaxLayers = [[Double]](
            repeating: [Double](repeating: 0, count: channels), count: subLayers
        )
        for layer in 0..<subLayers {
            for channel in 0..<channels {
                var maximum = -Double.infinity
                for sample in densityCurvesLayers where sample.count > layer
                    && sample[layer].count > channel {
                    let value = sample[layer][channel]
                    if !value.isNaN { maximum = Swift.max(maximum, value) }
                }
                densityMaxLayers[layer][channel] = maximum.isFinite ? maximum : 0
            }
        }

        // The total of every channel (over the layers) and the fractions of
        // the maximum density every layer holds.
        var densityMaxTotal = [Double](repeating: 0, count: channels)
        for layer in 0..<subLayers {
            for channel in 0..<channels {
                densityMaxTotal[channel] += densityMaxLayers[layer][channel]
            }
        }
        var densityMaxFractions = [[Double]](
            repeating: [Double](repeating: 0, count: channels), count: subLayers
        )
        for layer in 0..<subLayers {
            for channel in 0..<channels {
                let total = densityMaxTotal[channel]
                densityMaxFractions[layer][channel] =
                    total != 0 ? densityMaxLayers[layer][channel] / total : 0
            }
        }

        // The minimum density of every layer.
        var densityMinLayers = [[Double]](
            repeating: [Double](repeating: 0, count: channels), count: subLayers
        )
        for layer in 0..<subLayers {
            for channel in 0..<channels {
                densityMinLayers[layer][channel] =
                    densityMaxFractions[layer][channel] * densityMin[channel]
            }
        }

        // The maximum density of every layer, with its minimum density added.
        for layer in 0..<subLayers {
            for channel in 0..<channels {
                densityMaxLayers[layer][channel] += densityMinLayers[layer][channel]
            }
        }

        // The number of particles a pixel holds, per layer and per channel.
        let pixelArea = pixelSizeUM * pixelSizeUM
        var nParticlesPerPixel = [[Double]](
            repeating: [Double](repeating: 0, count: channels), count: subLayers
        )
        for layer in 0..<subLayers {
            for channel in 0..<channels {
                let particleArea = grain.particleAreaUM2
                    * grain.particleScale[channel]
                    * grain.particleScaleLayers[layer]
                nParticlesPerPixel[layer][channel] = particleArea != 0
                    ? pixelArea * densityMaxFractions[layer][channel] / particleArea
                    : 0
            }
        }

        var output = [Double](repeating: 0, count: densityCMY.count)
        for channel in 0..<channels {
            // The density of the pixel, split between the emulsion layers.
            let layerPlanes = interpolateLayers(
                channel: channel,
                densityCMY: densityCMY,
                width: width,
                height: height,
                densityCurves: densityCurves,
                densityCurvesLayers: densityCurvesLayers,
                positiveFilm: positiveFilm
            )
            for layer in 0..<subLayers {
                var plane = layerPlanes[layer]
                // The upstream adds the minimum density of the layer to the
                // densities of the stack.
                let minimum = densityMinLayers[layer][channel]
                for index in 0..<plane.count { plane[index] += minimum }
                let grainPlane = layerParticleModel(
                    density: plane,
                    densityMax: densityMaxLayers[layer][channel],
                    nParticlesPerPixel: nParticlesPerPixel[layer][channel],
                    uniformity: grain.uniformity[channel],
                    seed: StochasticSeed.grainLayer(seed: seed, channel: channel, layer: layer),
                    blurParticle: grain.blurDyeCloudsUM,
                    width: width,
                    height: height,
                    sampler: sampler
                )
                for pixel in 0..<pixels {
                    output[pixel * channels + channel] += grainPlane[pixel]
                }
            }
        }

        // The micro structure of the emulsion.
        output = addMicroStructure(
            densityCMY: output,
            microStructure: grain.microStructure,
            pixelSizeUM: pixelSizeUM,
            width: width,
            height: height,
            seed: StochasticSeed.grainLayer(seed: seed, channel: channels, layer: 0)
        )

        // The upstream removes the (global) minimum density again.
        for pixel in 0..<pixels {
            for channel in 0..<channels {
                output[pixel * channels + channel] -= densityMin[channel]
            }
        }

        // The final blur of the grain.
        if grain.blur > 0 {
            output = SpatialEffects.gaussianFilter(
                rgb: output, width: width, height: height, sigma: grain.blur
            )
        }
        return output
    }

    // MARK: - The particle model of a layer

    /// The particle model of one layer of one channel.
    ///
    /// Upstream reference: `spektrafilm.model.grain.layer_particle_model`.
    ///
    /// - Parameters:
    ///   - density: the density of the layer, one value per pixel.
    ///   - densityMax: the maximum density of the layer.
    ///   - nParticlesPerPixel: the number of particles a pixel holds.
    ///   - uniformity: the uniformity of the emulsion of the channel.
    ///   - seed: the seed of the random number generator.
    ///   - blurParticle: the blur of the dye clouds, in micrometres.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    /// - Returns: the density of the developed grains, one value per pixel.
    static func layerParticleModel(
        density: [Double],
        densityMax: Double,
        nParticlesPerPixel: Double,
        uniformity: Double,
        seed: UInt64,
        blurParticle: Double,
        width: Int,
        height: Int,
        sampler: GrainSampler = .fast
    ) -> [Double] {
        let count = density.count
        var generator = RandomGenerator(seed: seed)

        // The probability that a particle develops, and the saturation of the
        // layer.
        var probability = [Double](repeating: 0, count: count)
        var saturation = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let value = Swift.min(Swift.max(density[index] / densityMax, 1e-6), 1.0 - 1e-6)
            probability[index] = value
            saturation[index] = 1.0 - value * uniformity * (1.0 - 1e-6)
        }
        // The optical density of a single particle.
        let odParticle = densityMax / nParticlesPerPixel

        // The number of particles of every pixel (the upstream draws the whole
        // array before the binomial variates).
        var nParticles = [Int](repeating: 0, count: count)
        for index in 0..<count {
            nParticles[index] = sampler == .exact
                ? generator.poissonExact(nParticlesPerPixel / saturation[index])
                : generator.poisson(nParticlesPerPixel / saturation[index])
        }

        // The number of particles that develop.
        var grain = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let variate = sampler == .exact
                ? generator.binomialExact(n: nParticles[index], p: probability[index])
                : generator.binomial(n: nParticles[index], p: probability[index])
            grain[index] = Double(variate) * odParticle * saturation[index]
        }

        // The blur of the dye clouds.
        if blurParticle > 0 {
            grain = SpatialEffects.filterPlane(
                grain,
                width: width,
                height: height,
                sigma: blurParticle * odParticle.squareRoot()
            )
        }
        return grain
    }

    // MARK: - The interpolation of the emulsion layers

    /// Splits the density of the pixels between the emulsion layers.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.density_curves.interp_density_cmy_layers`.
    ///
    /// The density of a pixel is interpolated on the density curve of the
    /// channel (the *normalised* curve of the film), the values being the
    /// densities of the emulsion layers.
    ///
    /// - Parameters:
    ///   - channel: the index of the channel.
    ///   - densityCMY: the densities, three interleaved values per pixel.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    ///   - densityCurves: the normalised density curves, `[sample][channel]`.
    ///   - densityCurvesLayers: the density curves of the layers,
    ///     `[sample][layer][channel]`.
    ///   - positiveFilm: `true` for a slide (a positive emulsion).
    /// - Returns: the density of every layer, one plane per layer.
    static func interpolateLayers(
        channel: Int,
        densityCMY: [Double],
        width: Int,
        height: Int,
        densityCurves: [[Double]],
        densityCurvesLayers: [[[Double]]],
        positiveFilm: Bool
    ) -> [[Double]] {
        let samples = densityCurves.count
        let pixels = width * height
        var planes = [[Double]](
            repeating: [Double](repeating: 0, count: pixels), count: subLayers
        )
        guard samples > 0 else { return planes }

        // The axis of the interpolation: the density curve of the channel
        // (mirrored for a positive emulsion, whose density falls with the
        // exposure).
        var axis = [Double](repeating: 0, count: samples)
        for sample in 0..<samples where sample < densityCurves.count
            && channel < densityCurves[sample].count {
            axis[sample] = positiveFilm
                ? -densityCurves[sample][channel]
                : densityCurves[sample][channel]
        }
        var inverseStep = [Double](repeating: 0, count: max(samples - 1, 0))
        for sample in 0..<max(samples - 1, 0) {
            let step = axis[sample + 1] - axis[sample]
            inverseStep[sample] = step != 0 ? 1.0 / step : 0
        }

        for pixel in 0..<pixels {
            let density = densityCMY[pixel * channels + channel]
            let x = positiveFilm ? -density : density
            if x <= axis[0] {
                for layer in 0..<subLayers {
                    planes[layer][pixel] = densityCurvesLayers[0][layer][channel]
                }
            } else if x >= axis[samples - 1] {
                for layer in 0..<subLayers {
                    planes[layer][pixel] = densityCurvesLayers[samples - 1][layer][channel]
                }
            } else {
                let index = Numerics.searchSortedRight(axis, x)
                let low = index - 1
                let t = (x - axis[low]) * inverseStep[low]
                for layer in 0..<subLayers {
                    let yLow = densityCurvesLayers[low][layer][channel]
                    let yHigh = densityCurvesLayers[low + 1][layer][channel]
                    planes[layer][pixel] = yLow + t * (yHigh - yLow)
                }
            }
        }
        return planes
    }

    // MARK: - The micro structure

    /// The micro structure of the emulsion: the clumping of the dye clouds.
    ///
    /// Upstream reference: `spektrafilm.model.grain.add_micro_structure`.
    ///
    /// - Parameters:
    ///   - densityCMY: the densities, three interleaved values per pixel.
    ///   - microStructure: the blur of the clumping field, in micrometres,
    ///     and the standard deviation of the clumping, in nanometres.
    ///   - pixelSizeUM: the size of a pixel of the negative, in micrometres.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    ///   - seed: the seed of the random number generator.
    /// - Returns: the densities with the micro structure.
    static func addMicroStructure(
        densityCMY: [Double],
        microStructure: [Double],
        pixelSizeUM: Double,
        width: Int,
        height: Int,
        seed: UInt64
    ) -> [Double] {
        guard microStructure.count >= 2, pixelSizeUM > 0 else { return densityCMY }
        let blurPixel = microStructure[0] / pixelSizeUM
        let sigma = microStructure[1] * 0.001 / pixelSizeUM
        guard sigma > 0.05 else { return densityCMY }

        var generator = RandomGenerator(seed: seed)
        var clumping = [Double](repeating: 0, count: densityCMY.count)
        for index in 0..<densityCMY.count {
            clumping[index] = generator.lognormalFromMeanStd(mean: 1.0, std: sigma)
        }
        if blurPixel > 0.4 {
            clumping = SpatialEffects.gaussianFilter(
                rgb: clumping, width: width, height: height, sigma: blurPixel
            )
        }
        var output = densityCMY
        for index in 0..<output.count { output[index] *= clumping[index] }
        return output
    }
}
