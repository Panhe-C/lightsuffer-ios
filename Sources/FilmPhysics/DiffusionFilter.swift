//
//  DiffusionFilter.swift
//  light suffer胶片 — iOS app
//
//  The diffusion filters of the camera and of the enlarger: the per family
//  point spread function (a core, a halo and a bloom group of isotropic
//  exponentials) and the energy conserving scattering it applies.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The parameters of a diffusion filter.
///
/// Upstream reference: `spektrafilm.runtime.params_schema.DiffusionFilterParams`.
public struct DiffusionFilterParams: Equatable, Sendable {
    /// Whether the filter is applied at all.
    public var active: Bool
    /// The family of the filter (`glimmerglass`, `black_pro_mist`,
    /// `pro_mist` or `cinebloom`).
    public var filterFamily: String
    /// The strength of the filter, in commercial stops.
    public var strength: Double
    /// The multiplier on the image plane widths of the PSF.
    public var spatialScale: Double
    /// The additive bias on the warmth axis of the halo.
    public var haloWarmth: Double
    /// The multiplier on the weight of the core group.
    public var coreIntensity: Double
    /// The multiplier on the width of the core group.
    public var coreSize: Double
    /// The multiplier on the weight of the halo group.
    public var haloIntensity: Double
    /// The multiplier on the width of the halo group.
    public var haloSize: Double
    /// The multiplier on the weight of the bloom group.
    public var bloomIntensity: Double
    /// The multiplier on the width of the bloom group.
    public var bloomSize: Double

    public init(
        active: Bool = false,
        filterFamily: String = "black_pro_mist",
        strength: Double = 0.5,
        spatialScale: Double = 1.0,
        haloWarmth: Double = 0.0,
        coreIntensity: Double = 1.0,
        coreSize: Double = 1.0,
        haloIntensity: Double = 1.0,
        haloSize: Double = 1.0,
        bloomIntensity: Double = 1.0,
        bloomSize: Double = 1.0
    ) {
        self.active = active
        self.filterFamily = filterFamily
        self.strength = strength
        self.spatialScale = spatialScale
        self.haloWarmth = haloWarmth
        self.coreIntensity = coreIntensity
        self.coreSize = coreSize
        self.haloIntensity = haloIntensity
        self.haloSize = haloSize
        self.bloomIntensity = bloomIntensity
        self.bloomSize = bloomSize
    }
}

/// The diffusion filters of the camera and of the enlarger.
///
/// Upstream reference: `spektrafilm.model.diffusion`.
///
/// The model is energy conserving: the filter only redistributes the light
/// between the unscattered population (`1 - p_s`) and the scattered one
/// (`p_s`, convolved with the per family point spread function). The point
/// spread function is
///
/// ```
/// K_s(r) = w_c * K_core(r) + w_h * K_halo(r) + w_b * K_bloom(r)
/// K_x(r) = sum_k w_x[k] * exp(-r / lambda_x[k]) / (2 pi lambda_x[k]^2)
/// ```
///
/// where every group is a small geometric progression of isotropic
/// exponentials. The halo is colour tinted: the warmth axis redistributes
/// the energy of the halo sub components per channel (and conserves it).
public enum DiffusionFilter {

    // MARK: - The families

    /// One group (core, halo or bloom) of the point spread function.
    public struct Group: Equatable, Sendable {
        /// The central decay constant of the group, in micrometres.
        public var lambdaUM: Double
        /// The spread of the geometric progression of the sub components.
        public var spread: Double
        /// The number of sub components of the group.
        public var nComponents: Int
        /// The tail exponent of the bloom group.
        public var alpha: Double

        public init(lambdaUM: Double, spread: Double, nComponents: Int, alpha: Double = 3.0) {
            self.lambdaUM = lambdaUM
            self.spread = spread
            self.nComponents = nComponents
            self.alpha = alpha
        }
    }

    /// The shape of a family of filters.
    public struct Family: Equatable, Sendable {
        /// The core group.
        public var core: Group
        /// The halo group.
        public var halo: Group
        /// The bloom group.
        public var bloom: Group
        /// The weight of the core group.
        public var wCore: Double
        /// The weight of the halo group.
        public var wHalo: Double
        /// The weight of the bloom group.
        public var wBloom: Double
        /// The base warmth of the halo of the family.
        public var haloWarmthBase: Double

        public init(
            core: Group,
            halo: Group,
            bloom: Group,
            wCore: Double,
            wHalo: Double,
            wBloom: Double,
            haloWarmthBase: Double
        ) {
            self.core = core
            self.halo = halo
            self.bloom = bloom
            self.wCore = wCore
            self.wHalo = wHalo
            self.wBloom = wBloom
            self.haloWarmthBase = haloWarmthBase
        }
    }

    /// The per family shapes of the point spread function.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.diffusion._DIFFUSION_FILTER_SHAPES`.
    public static let families: [String: Family] = [
        "glimmerglass": Family(
            core: Group(lambdaUM: 10.0, spread: 1.5, nComponents: 2),
            halo: Group(lambdaUM: 50.0, spread: 2.0, nComponents: 3),
            bloom: Group(lambdaUM: 260.0, spread: 2.5, nComponents: 4, alpha: 3.2),
            wCore: 0.60,
            wHalo: 0.30,
            wBloom: 0.10,
            haloWarmthBase: 0.0
        ),
        "black_pro_mist": Family(
            core: Group(lambdaUM: 16.0, spread: 1.5, nComponents: 2),
            halo: Group(lambdaUM: 95.0, spread: 2.0, nComponents: 3),
            bloom: Group(lambdaUM: 380.0, spread: 2.5, nComponents: 4, alpha: 3.5),
            wCore: 0.40,
            wHalo: 0.47,
            wBloom: 0.13,
            haloWarmthBase: 0.65
        ),
        "pro_mist": Family(
            core: Group(lambdaUM: 14.0, spread: 1.5, nComponents: 2),
            halo: Group(lambdaUM: 150.0, spread: 2.0, nComponents: 3),
            bloom: Group(lambdaUM: 650.0, spread: 2.5, nComponents: 4, alpha: 2.9),
            wCore: 0.28,
            wHalo: 0.42,
            wBloom: 0.30,
            haloWarmthBase: 0.40
        ),
        "cinebloom": Family(
            core: Group(lambdaUM: 20.0, spread: 1.5, nComponents: 2),
            halo: Group(lambdaUM: 200.0, spread: 2.0, nComponents: 3),
            bloom: Group(lambdaUM: 1000.0, spread: 2.5, nComponents: 4, alpha: 2.5),
            wCore: 0.22,
            wHalo: 0.30,
            wBloom: 0.48,
            haloWarmthBase: 0.85
        ),
    ]

    /// The names of the families of filters.
    public static var familyNames: [String] { Array(families.keys) }

    /// The per family gain on the shared scatter fraction table.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.diffusion._DIFFUSION_FAMILY_TOTAL_GAIN`.
    public static let familyTotalGain: [String: Double] = [
        "glimmerglass": 0.65,
        "black_pro_mist": 0.75,
        "pro_mist": 1.05,
        "cinebloom": 1.00,
    ]

    /// The commercial filter stops of the scatter fraction table.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.diffusion._DIFFUSION_STRENGTH_BREAKPOINTS` and
    /// `_DIFFUSION_STRENGTH_TOTAL_FRACTION`.
    public static let strengthBreakpoints: [Double] = [0.125, 0.25, 0.5, 1.0, 2.0]
    /// The deflected fraction of the photons at the breakpoints.
    public static let strengthTotalFraction: [Double] = [0.10, 0.20, 0.35, 0.55, 0.75]

    /// The warmth axis of the halo.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.diffusion._HALO_CHANNEL_WARMTH_AXIS`.
    public static let haloChannelWarmthAxis: [Double] = [1.30, 0.15, -1.45]

    // MARK: - The strength

    /// The deflected fraction of the photons of a filter.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.diffusion._strength_to_scatter`.
    ///
    /// - Parameters:
    ///   - strength: the strength of the filter, in commercial stops.
    ///   - family: the family of the filter.
    /// - Returns: the scattered fraction `p_s`.
    public static func scatterFraction(strength: Double, family: String) -> Double {
        guard strength > 0 else { return 0 }
        let logStrength = log2(max(strength, 1e-6))
        var logBreaks = [Double](repeating: 0, count: strengthBreakpoints.count)
        for index in 0..<strengthBreakpoints.count {
            logBreaks[index] = log2(strengthBreakpoints[index])
        }
        let base = Numerics.interpolate(
            x: logStrength, axis: logBreaks, values: strengthTotalFraction
        )
        let gain = familyTotalGain[family] ?? 1.0
        return min(max(base * gain, 0.0), 0.99)
    }

    // MARK: - The point spread function

    /// The family configuration with the per group overrides applied.
    ///
    /// Upstream reference: `spektrafilm.model.diffusion._resolve_family_cfg`.
    ///
    /// - Parameters:
    ///   - family: the family of the filter.
    ///   - params: the parameters of the filter (the per group overrides).
    /// - Returns: the resolved configuration.
    public static func resolveFamily(
        _ family: String,
        params: DiffusionFilterParams
    ) -> Family? {
        guard let base = families[family] else { return nil }
        let coreIntensity = max(params.coreIntensity, 0.0)
        let haloIntensity = max(params.haloIntensity, 0.0)
        let bloomIntensity = max(params.bloomIntensity, 0.0)
        let coreSize = max(params.coreSize, 1e-6)
        let haloSize = max(params.haloSize, 1e-6)
        let bloomSize = max(params.bloomSize, 1e-6)
        if coreIntensity == 1.0, haloIntensity == 1.0, bloomIntensity == 1.0,
            coreSize == 1.0, haloSize == 1.0, bloomSize == 1.0
        {
            return base
        }
        let wCore = base.wCore * coreIntensity
        let wHalo = base.wHalo * haloIntensity
        let wBloom = base.wBloom * bloomIntensity
        let total = wCore + wHalo + wBloom
        guard total > 0 else { return base }
        return Family(
            core: Group(
                lambdaUM: base.core.lambdaUM * coreSize,
                spread: base.core.spread,
                nComponents: base.core.nComponents,
                alpha: base.core.alpha
            ),
            halo: Group(
                lambdaUM: base.halo.lambdaUM * haloSize,
                spread: base.halo.spread,
                nComponents: base.halo.nComponents,
                alpha: base.halo.alpha
            ),
            bloom: Group(
                lambdaUM: base.bloom.lambdaUM * bloomSize,
                spread: base.bloom.spread,
                nComponents: base.bloom.nComponents,
                alpha: base.bloom.alpha
            ),
            wCore: wCore / total,
            wHalo: wHalo / total,
            wBloom: wBloom / total,
            haloWarmthBase: base.haloWarmthBase
        )
    }

    /// The sub components (decay constants and weights) of a group.
    ///
    /// Upstream reference: `spektrafilm.model.diffusion._expand_group`.
    ///
    /// - Parameters:
    ///   - group: the group to expand.
    ///   - bloom: whether the group is the bloom group (its weights follow a
    ///     power law schedule).
    /// - Returns: the decay constants (in micrometres) and the weights.
    public static func expandGroup(_ group: Group, bloom: Bool) -> (lambdas: [Double], weights: [Double]) {
        let n = max(group.nComponents, 1)
        if n == 1 || group.spread <= 1.0 {
            return ([group.lambdaUM], [1.0])
        }
        let logLow = log(group.lambdaUM / group.spread)
        let logHigh = log(group.lambdaUM * group.spread)
        var lambdas = [Double](repeating: 0, count: n)
        for index in 0..<n {
            let t = n == 1 ? 0.0 : Double(index) / Double(n - 1)
            lambdas[index] = exp(logLow + t * (logHigh - logLow))
        }
        var weights = [Double](repeating: 0, count: n)
        if bloom {
            let exponent = 2.0 - group.alpha
            for index in 0..<n {
                weights[index] = pow(lambdas[index], exponent)
            }
        } else {
            for index in 0..<n { weights[index] = 1.0 }
        }
        var total = 0.0
        for weight in weights { total += weight }
        if total > 0 {
            for index in 0..<n { weights[index] /= total }
        }
        return (lambdas, weights)
    }

    /// The per channel weights of the halo.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.diffusion._halo_channel_weights`.
    ///
    /// The redistribution conserves the energy of the halo: the modulated
    /// weights are clipped and renormalised so that their sum is the sum of
    /// the input weights.
    ///
    /// - Parameters:
    ///   - weights: the weights of the halo sub components.
    ///   - warmth: the warmth of the halo.
    /// - Returns: three rows of weights, one per channel.
    public static func haloChannelWeights(_ weights: [Double], warmth: Double) -> [[Double]] {
        let n = weights.count
        guard n >= 2 else { return [weights, weights, weights] }
        let clampedWarmth = min(max(warmth, -1.5), 1.5)
        var gradient = [Double](repeating: 0, count: n)
        for index in 0..<n {
            gradient[index] = n == 1 ? 0.0 : -1.0 + 2.0 * Double(index) / Double(n - 1)
        }
        var weightSum = 0.0
        var gradientSum = 0.0
        for index in 0..<n {
            weightSum += weights[index]
            gradientSum += gradient[index] * weights[index]
        }
        let average = weightSum > 0 ? gradientSum / weightSum : 0.0
        for index in 0..<n {
            gradient[index] -= average
        }
        let targetTotal = weightSum
        var output = [[Double]](repeating: [Double](repeating: 0, count: n), count: 3)
        for channel in 0..<3 {
            var raw = [Double](repeating: 0, count: n)
            for index in 0..<n {
                raw[index] = weights[index]
                    * (1.0 + clampedWarmth * haloChannelWarmthAxis[channel] * gradient[index])
                if raw[index] < 0 { raw[index] = 0 }
            }
            var sum = 0.0
            for value in raw { sum += value }
            if sum > 0 {
                for index in 0..<n {
                    output[channel][index] = raw[index] * (targetTotal / sum)
                }
            } else {
                for index in 0..<n { output[channel][index] = weights[index] }
            }
        }
        return output
    }

    /// The largest decay constant of the bloom group, in micrometres.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.diffusion._bloom_max_lambda_um`.
    public static func bloomMaxLambdaUM(
        _ family: String,
        params: DiffusionFilterParams
    ) -> Double {
        guard let resolved = resolveFamily(family, params: params) else { return 0 }
        return resolved.bloom.lambdaUM * resolved.bloom.spread
    }

    /// The per channel point spread function of a filter.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.diffusion.diffusion_filter_psf`.
    ///
    /// - Parameters:
    ///   - shape: the shape of the (square) kernel.
    ///   - family: the family of the filter.
    ///   - spatialScale: the multiplier on the image plane widths.
    ///   - pixelSizeUM: the size of a pixel, in micrometres.
    ///   - haloWarmth: the additive bias on the warmth axis of the halo.
    ///   - params: the parameters of the filter (the per group overrides).
    /// - Returns: the kernel, one plane per channel.
    public static func psf(
        shape: Int,
        family: String,
        spatialScale: Double,
        pixelSizeUM: Double,
        haloWarmth: Double,
        params: DiffusionFilterParams
    ) -> [[Double]]? {
        guard let resolved = resolveFamily(family, params: params) else { return nil }
        let scale = max(spatialScale, 1e-6)
        let centre = shape / 2

        let core = expandGroup(resolved.core, bloom: false)
        let halo = expandGroup(resolved.halo, bloom: false)
        let bloom = expandGroup(resolved.bloom, bloom: true)
        let warmth = resolved.haloWarmthBase + haloWarmth
        let haloPerChannel = haloChannelWeights(halo.weights, warmth: warmth)

        let coreLambdas = core.lambdas.map { $0 * scale / pixelSizeUM }
        let haloLambdas = halo.lambdas.map { $0 * scale / pixelSizeUM }
        let bloomLambdas = bloom.lambdas.map { $0 * scale / pixelSizeUM }

        var kernel = [[Double]](repeating: [Double](repeating: 0, count: shape * shape), count: 3)
        for row in 0..<shape {
            for column in 0..<shape {
                let dx = Double(column - centre)
                let dy = Double(row - centre)
                let radius = sqrt(dx * dx + dy * dy)
                let index = row * shape + column
                let coreValue = resolved.wCore * exponentialSum(
                    radius: radius, lambdas: coreLambdas, weights: core.weights
                )
                let bloomValue = resolved.wBloom * exponentialSum(
                    radius: radius, lambdas: bloomLambdas, weights: bloom.weights
                )
                for channel in 0..<3 {
                    let haloValue = resolved.wHalo * exponentialSum(
                        radius: radius, lambdas: haloLambdas, weights: haloPerChannel[channel]
                    )
                    kernel[channel][index] = coreValue + haloValue + bloomValue
                }
            }
        }
        // The upstream normalises every channel of the kernel on its own sum.
        for channel in 0..<3 {
            var sum = 0.0
            for value in kernel[channel] { sum += value }
            if sum != 0 {
                for index in 0..<kernel[channel].count {
                    kernel[channel][index] /= sum
                }
            }
        }
        return kernel
    }

    /// The sum of the isotropic exponentials of a group.
    ///
    /// Upstream reference: the `_exp_sum` helper of `_radial_components`.
    private static func exponentialSum(
        radius: Double,
        lambdas: [Double],
        weights: [Double]
    ) -> Double {
        var total = 0.0
        for index in 0..<lambdas.count {
            let lambda = max(lambdas[index], 1e-6)
            total += weights[index] * exp(-radius / lambda) / (2.0 * .pi * lambda * lambda)
        }
        return total
    }

    // MARK: - The application

    /// Applies a diffusion filter to an image.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.diffusion.apply_diffusion_filter_um`.
    ///
    /// ```
    /// E_out = (1 - p_s) * E_in + p_s * (K_s * E_in)
    /// ```
    ///
    /// - Parameters:
    ///   - image: the interleaved samples of the image.
    ///   - width: the width of the image.
    ///   - height: the height of the image.
    ///   - params: the parameters of the filter.
    ///   - pixelSizeUM: the size of a pixel, in micrometres.
    /// - Returns: the scattered image.
    public static func apply(
        image: [Double],
        width: Int,
        height: Int,
        params: DiffusionFilterParams,
        pixelSizeUM: Double
    ) -> [Double] {
        guard params.active, params.strength > 0, params.spatialScale > 0 else { return image }
        guard pixelSizeUM > 0 else { return image }
        guard families[params.filterFamily] != nil else { return image }
        let pScatter = scatterFraction(strength: params.strength, family: params.filterFamily)
        guard pScatter > 0 else { return image }

        // The truncation budget of the kernel: a single 2D exponential has
        // 99.95 % of its energy inside eight decay constants.
        let bloomMaxLambdaPX = bloomMaxLambdaUM(params.filterFamily, params: params)
            * params.spatialScale / pixelSizeUM
        var radius = Int(ceil(max(8.0 * bloomMaxLambdaPX, 5.0)))
        radius = min(radius, max(min(height, width) / 2 - 1, 1))

        let shape = 2 * radius + 1
        guard let kernel = psf(
            shape: shape,
            family: params.filterFamily,
            spatialScale: params.spatialScale,
            pixelSizeUM: pixelSizeUM,
            haloWarmth: params.haloWarmth,
            params: params
        ) else { return image }

        var blurred = [Double](repeating: 0, count: image.count)
        for channel in 0..<3 {
            var plane = [Double](repeating: 0, count: width * height)
            for index in 0..<(width * height) {
                plane[index] = image[index * 3 + channel]
            }
            let filtered = convolveSame(
                plane: plane,
                width: width,
                height: height,
                kernel: kernel[channel],
                kernelShape: shape,
                radius: radius
            )
            for index in 0..<(width * height) {
                blurred[index * 3 + channel] = filtered[index]
            }
        }

        var output = [Double](repeating: 0, count: image.count)
        for index in 0..<image.count {
            output[index] = (1.0 - pScatter) * image[index] + pScatter * blurred[index]
        }
        return output
    }

    /// The `same` convolution of a plane with a square kernel.
    ///
    /// The upstream uses `scipy.signal.fftconvolve(..., mode="same")` on a
    /// reflect padded image; the port evaluates the very same (linear)
    /// convolution directly, which agrees with the FFT to the round off of
    /// the transform.
    ///
    /// The padding of the upstream is `numpy.pad(..., mode="reflect")`, i.e.
    /// the *half sample symmetric* reflection (`d c b a | a b c d | d c b a`
    /// without the repeated edge sample) — which is **not** the `reflect`
    /// mode of SciPy that the Gaussian filter of the upstream uses (that one
    /// repeats the edge sample).
    ///
    /// - Parameters:
    ///   - plane: the samples of the image, row major.
    ///   - width: the width of the image.
    ///   - height: the height of the image.
    ///   - kernel: the kernel, row major.
    ///   - kernelShape: the (square) shape of the kernel.
    ///   - radius: the radius of the kernel, i.e. `(shape - 1) / 2`.
    /// - Returns: the convolved image.
    static func convolveSame(
        plane: [Double],
        width: Int,
        height: Int,
        kernel: [Double],
        kernelShape: Int,
        radius: Int
    ) -> [Double] {
        let horizontalTable = reflectTableFor(width)
        let verticalTable = reflectTableFor(height)
        var output = [Double](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                var sum = 0.0
                for u in 0..<kernelShape {
                    let sourceRow = reflected(row + radius - u, table: verticalTable)
                    let kernelBase = u * kernelShape
                    for v in 0..<kernelShape {
                        let sourceColumn = reflected(column + radius - v, table: horizontalTable)
                        sum += plane[sourceRow * width + sourceColumn] * kernel[kernelBase + v]
                    }
                }
                output[row * width + column] = sum
            }
        }
        return output
    }

    /// The `numpy.pad(..., mode="reflect")` index of an axis.
    ///
    /// The half sample symmetric reflection: the index `-1` maps to `1`,
    /// the index `n` maps to `n - 2` and so on, with the period
    /// `2 (n - 1)`.
    static func numpyReflectIndex(_ index: Int, _ count: Int) -> Int {
        if count <= 1 { return 0 }
        let period = 2 * (count - 1)
        var folded = index % period
        if folded < 0 { folded += period }
        if folded >= count { folded = period - folded }
        return folded
    }

    /// The reflection table of an axis (the `numpy.pad` convention).
    ///
    /// The period of the half sample symmetric reflection is `2 (n - 1)`.
    private static func reflectTableFor(_ count: Int) -> [Int] {
        let period = count > 1 ? 2 * (count - 1) : 1
        var table = [Int](repeating: 0, count: period)
        for index in 0..<period {
            table[index] = numpyReflectIndex(index, count)
        }
        return table
    }

    /// The reflected index of `index` on an axis with the given table.
    private static func reflected(_ index: Int, table: [Int]) -> Int {
        let period = table.count
        var folded = index % period
        if folded < 0 { folded += period }
        return table[folded]
    }
}
