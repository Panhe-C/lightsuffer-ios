//
//  SpatialEffects.swift
//  light suffer胶片 — iOS app
//
//  The image space helpers of the spatial effects: the separable Gaussian
//  filter (the FIR and the Young & van Vliet IIR paths), the exponential
//  filter (the Gaussian mixture surrogate of an isotropic 2D exponential
//  PSF) and the unsharp mask.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The image space filters of the ported pipeline.
///
/// Upstream reference:
///
/// * `spektrafilm.utils.fast_gaussian_filter.fast_gaussian_filter` — the
///   per channel 2D Gaussian filter. It dispatches on the sigma: a fused
///   separable FIR below 3 pixels and a recursive Young & van Vliet IIR
///   above it. The boundary mode is SciPy's `reflect`
///   (`d c b a | a b c d | d c b a`).
/// * `spektrafilm.utils.fast_gaussian_filter.fast_exponential_filter` — the
///   Gaussian mixture surrogate of the isotropic 2D exponential PSF
///   `exp(-r / lambda) / (2 pi lambda^2)`.
/// * `spektrafilm.model.diffusion.apply_unsharp_mask` — the unsharp mask of
///   the scanner.
public enum SpatialEffects {

    // MARK: - Boundary handling

    /// The SciPy / NumPy `reflect` boundary index.
    ///
    /// Upstream reference: `spektrafilm.utils.fast_gaussian_filter._reflect`.
    ///
    /// The reflection is the "half sample symmetric" one: the index `-1`
    /// maps to `0`, `-2` to `1` and `n` to `n - 1`.
    ///
    /// - Parameters:
    ///   - index: the (possibly out of range) index.
    ///   - count: the number of samples of the axis.
    /// - Returns: the reflected index, in `0 ..< count`.
    public static func reflectIndex(_ index: Int, _ count: Int) -> Int {
        if count <= 0 { return 0 }
        if index >= 0 && index < count { return index }
        if index < 0 && index >= -count { return -index - 1 }
        if index >= count && index < 2 * count { return 2 * count - 1 - index }
        let period = 2 * count
        var folded = index % period
        if folded < 0 { folded += period }
        if folded < count { return folded }
        return period - 1 - folded
    }

    /// The reflection table of an axis of `count` samples.
    ///
    /// The table holds the reflected indices of `0 ..< 2 * count`; an index
    /// outside of that range is folded with the period `2 * count` first.
    private static func reflectTable(_ count: Int) -> [Int] {
        var table = [Int](repeating: 0, count: 2 * count)
        for index in 0..<(2 * count) {
            table[index] = reflectIndex(index, count)
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

    // MARK: - The Gaussian filter

    /// The 1D Gaussian kernel of the FIR path.
    ///
    /// Upstream reference: `spektrafilm.utils.fast_gaussian_filter._gaussian_kernel_1d`.
    ///
    /// The radius is `int(truncate * sigma + 0.5)` and the kernel is
    /// normalised to a unit sum.
    ///
    /// - Parameters:
    ///   - sigma: the standard deviation, in pixels.
    ///   - truncate: the truncation of the kernel, in standard deviations.
    /// - Returns: the kernel and its radius.
    public static func gaussianKernel(sigma: Double, truncate: Double) -> (kernel: [Double], radius: Int) {
        let radius = Int(truncate * sigma + 0.5)
        guard radius > 0 else {
            // The upstream kernel of a radius of zero is the single value
            // `exp(0) = 1`, normalised to one.
            return ([1.0], 0)
        }
        let size = 2 * radius + 1
        var kernel = [Double](repeating: 0, count: size)
        var total = 0.0
        for index in 0..<size {
            let x = Double(index - radius)
            let value = exp(-0.5 * (x / sigma) * (x / sigma))
            kernel[index] = value
            total += value
        }
        for index in 0..<size {
            kernel[index] /= total
        }
        return (kernel, radius)
    }

    /// Filters a two dimensional plane with a Gaussian.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.fast_gaussian_filter._dispatch_2d`.
    ///
    /// - Parameters:
    ///   - plane: the samples, row major.
    ///   - width: the width of the plane.
    ///   - height: the height of the plane.
    ///   - sigma: the standard deviation, in pixels.
    ///   - truncate: the truncation of the FIR kernel.
    /// - Returns: the filtered plane.
    public static func filterPlane(
        _ plane: [Double],
        width: Int,
        height: Int,
        sigma: Double,
        truncate: Double = 3.0
    ) -> [Double] {
        guard sigma > 0, width > 0, height > 0 else { return plane }
        if sigma >= smallSigmaMax {
            return iirFilter(plane, width: width, height: height, sigma: sigma)
        }
        return firFilter(plane, width: width, height: height, sigma: sigma, truncate: truncate)
    }

    /// The largest sigma the FIR path is used for.
    ///
    /// Upstream reference: `spektrafilm.utils.fast_gaussian_filter.SMALL_SIGMA_MAX`.
    public static let smallSigmaMax = 3.0

    /// The fused separable FIR Gaussian of the upstream.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.fast_gaussian_filter._gaussian_filter_2d_small`.
    ///
    /// The vertical pass runs first, then the horizontal one; the sums are
    /// accumulated in the same order as the upstream kernel, so the results
    /// agree to the last bits.
    private static func firFilter(
        _ plane: [Double],
        width: Int,
        height: Int,
        sigma: Double,
        truncate: Double
    ) -> [Double] {
        guard sigma > 0 else { return plane }
        let (kernel, radius) = gaussianKernel(sigma: sigma, truncate: truncate)
        let verticalTable = reflectTable(height)
        let horizontalTable = reflectTable(width)

        // The vertical pass.
        var intermediate = [Double](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                var sum = 0.0
                for offset in -radius...radius {
                    let source = reflected(row + offset, table: verticalTable)
                    sum += plane[source * width + column] * kernel[offset + radius]
                }
                intermediate[row * width + column] = sum
            }
        }

        // The horizontal pass.
        var output = [Double](repeating: 0, count: width * height)
        for row in 0..<height {
            let base = row * width
            for column in 0..<width {
                var sum = 0.0
                for offset in -radius...radius {
                    let source = reflected(column + offset, table: horizontalTable)
                    sum += intermediate[base + source] * kernel[offset + radius]
                }
                output[base + column] = sum
            }
        }
        return output
    }

    /// The coefficients of the Young & van Vliet recursive Gaussian.
    ///
    /// Upstream reference: `spektrafilm.utils.fast_gaussian_filter._yvv_coeffs`.
    ///
    /// - Parameter sigma: the standard deviation, in pixels.
    /// - Returns: the four coefficients of the recursion.
    public static func youngVanVlietCoefficients(
        sigma: Double
    ) -> (b: Double, b1: Double, b2: Double, b3: Double) {
        let q: Double
        if sigma >= 2.5 {
            q = 0.98711 * sigma - 0.96330
        } else {
            q = 3.97156 - 4.14554 * sqrt(1.0 - 0.26891 * sigma)
        }
        let q2 = q * q
        let q3 = q2 * q
        let b0 = 1.57825 + 2.44413 * q + 1.4281 * q2 + 0.422205 * q3
        let b1 = 2.44413 * q + 2.85619 * q2 + 1.26661 * q3
        let b2 = -(1.4281 * q2 + 1.26661 * q3)
        let b3 = 0.422205 * q3
        let b = 1.0 - (b1 + b2 + b3) / b0
        return (b, b1 / b0, b2 / b0, b3 / b0)
    }

    /// The recursive (Young & van Vliet) Gaussian of the upstream.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.fast_gaussian_filter._gaussian_filter_2d_large`.
    ///
    /// The horizontal sweep runs first, then the vertical one; both sweeps
    /// run forwards and then backwards. The boundary handling is the sample
    /// replication of the upstream.
    private static func iirFilter(
        _ plane: [Double],
        width: Int,
        height: Int,
        sigma: Double
    ) -> [Double] {
        guard sigma > 0 else { return plane }
        if sigma < 0.5 {
            // The recursion is unstable below half a pixel: the upstream
            // falls back to the direct FIR.
            return firFilter(plane, width: width, height: height, sigma: sigma, truncate: 3.0)
        }
        let coefficients = youngVanVlietCoefficients(sigma: sigma)
        let b = coefficients.b
        let b1 = coefficients.b1
        let b2 = coefficients.b2
        let b3 = coefficients.b3

        // The horizontal sweep.
        var intermediate = [Double](repeating: 0, count: width * height)
        for row in 0..<height {
            let base = row * width
            var w1 = plane[base]
            var w2 = w1
            var w3 = w1
            for column in 0..<width {
                let value = b * plane[base + column] + b1 * w1 + b2 * w2 + b3 * w3
                intermediate[base + column] = value
                w3 = w2
                w2 = w1
                w1 = value
            }
            var y1 = intermediate[base + width - 1]
            var y2 = y1
            var y3 = y1
            var column = width - 1
            while column >= 0 {
                let value = b * intermediate[base + column] + b1 * y1 + b2 * y2 + b3 * y3
                intermediate[base + column] = value
                y3 = y2
                y2 = y1
                y1 = value
                column -= 1
            }
        }

        // The vertical sweep.
        var output = [Double](repeating: 0, count: width * height)
        for column in 0..<width {
            var s1 = intermediate[column]
            var s2 = s1
            var s3 = s1
            for row in 0..<height {
                let index = row * width + column
                let value = b * intermediate[index] + b1 * s1 + b2 * s2 + b3 * s3
                output[index] = value
                s3 = s2
                s2 = s1
                s1 = value
            }
            var r1 = output[(height - 1) * width + column]
            var r2 = r1
            var r3 = r1
            var row = height - 1
            while row >= 0 {
                let index = row * width + column
                let value = b * output[index] + b1 * r1 + b2 * r2 + b3 * r3
                output[index] = value
                r3 = r2
                r2 = r1
                r1 = value
                row -= 1
            }
        }
        return output
    }

    /// Filters an interleaved RGB image with a Gaussian.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.fast_gaussian_filter.fast_gaussian_filter`.
    ///
    /// - Parameters:
    ///   - rgb: the interleaved samples of the image.
    ///   - width: the width of the image.
    ///   - height: the height of the image.
    ///   - sigma: the standard deviation, in pixels. A single value applies
    ///     to the three channels, three values are used per channel.
    ///   - truncate: the truncation of the FIR kernel.
    /// - Returns: the filtered image.
    public static func gaussianFilter(
        rgb: [Double],
        width: Int,
        height: Int,
        sigma: Double,
        truncate: Double = 3.0
    ) -> [Double] {
        gaussianFilter(rgb: rgb, width: width, height: height, sigma: [sigma], truncate: truncate)
    }

    /// Filters an interleaved RGB image with a per channel Gaussian.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.fast_gaussian_filter.fast_gaussian_filter` (the
    /// per channel branch of `_apply_per_channel`).
    ///
    /// - Parameters:
    ///   - rgb: the interleaved samples of the image.
    ///   - width: the width of the image.
    ///   - height: the height of the image.
    ///   - sigma: the standard deviations, in pixels: one value for the
    ///     three channels or one value per channel.
    ///   - truncate: the truncation of the FIR kernel.
    /// - Returns: the filtered image.
    public static func gaussianFilter(
        rgb: [Double],
        width: Int,
        height: Int,
        sigma: [Double],
        truncate: Double = 3.0
    ) -> [Double] {
        guard width > 0, height > 0 else { return rgb }
        let channels = sigma.count == 1 ? 1 : sigma.count
        guard channels == 1 || channels == 3 else { return rgb }
        var output = [Double](repeating: 0, count: rgb.count)
        var plane = [Double](repeating: 0, count: width * height)
        for channel in 0..<3 {
            let channelSigma = channels == 1 ? sigma[0] : sigma[channel]
            for row in 0..<height {
                let base = row * width
                for column in 0..<width {
                    plane[base + column] = rgb[(base + column) * 3 + channel]
                }
            }
            let filtered = filterPlane(
                plane, width: width, height: height, sigma: channelSigma, truncate: truncate
            )
            for row in 0..<height {
                let base = row * width
                for column in 0..<width {
                    output[(base + column) * 3 + channel] = filtered[base + column]
                }
            }
        }
        return output
    }

    // MARK: - The exponential filter

    /// The Gaussian mixture fit of the isotropic 2D exponential PSF.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.fast_gaussian_filter._EXPONENTIAL_GAUSSIAN_FITS`.
    ///
    /// Every entry is an (amplitude, sigma to decay ratio) pair; the
    /// amplitudes sum to 0.9999 (and not to one), which the port reproduces
    /// exactly.
    public static let exponentialGaussianFits: [(amplitude: Double, sigmaRatio: Double)] = [
        (0.1633, 0.5360),
        (0.6496, 1.5236),
        (0.1870, 2.7684),
    ]

    /// Filters a two dimensional plane with the exponential surrogate.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.fast_gaussian_filter.fast_exponential_filter` (the
    /// two dimensional branch of `_apply_per_channel`).
    ///
    /// - Parameters:
    ///   - plane: the samples of the plane, row major.
    ///   - width: the width of the plane.
    ///   - height: the height of the plane.
    ///   - decayConstant: the decay constant of the exponential PSF, in pixels.
    ///   - truncate: the truncation of the FIR kernel.
    /// - Returns: the filtered plane.
    public static func exponentialFilterPlane(
        _ plane: [Double],
        width: Int,
        height: Int,
        decayConstant: Double,
        truncate: Double = 3.0
    ) -> [Double] {
        var result: [Double]? = nil
        for fit in exponentialGaussianFits {
            let component = filterPlane(
                plane,
                width: width,
                height: height,
                sigma: fit.sigmaRatio * decayConstant,
                truncate: truncate
            )
            if let current = result {
                var accumulated = current
                for index in 0..<accumulated.count {
                    accumulated[index] += fit.amplitude * component[index]
                }
                result = accumulated
            } else {
                result = component.map { fit.amplitude * $0 }
            }
        }
        return result ?? plane
    }

    /// Filters an interleaved RGB image with the exponential surrogate.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.fast_gaussian_filter.fast_exponential_filter`.
    ///
    /// - Parameters:
    ///   - rgb: the interleaved samples of the image.
    ///   - width: the width of the image.
    ///   - height: the height of the image.
    ///   - decayConstant: the decay constant of the exponential PSF, in
    ///     pixels: one value for the three channels or one value per channel.
    ///   - truncate: the truncation of the FIR kernel.
    /// - Returns: the filtered image.
    public static func exponentialFilter(
        rgb: [Double],
        width: Int,
        height: Int,
        decayConstant: [Double],
        truncate: Double = 3.0
    ) -> [Double] {
        guard !decayConstant.isEmpty else { return rgb }
        var result: [Double]? = nil
        for fit in exponentialGaussianFits {
            let sigma = decayConstant.count == 1
                ? [fit.sigmaRatio * decayConstant[0]]
                : decayConstant.map { fit.sigmaRatio * $0 }
            let component = gaussianFilter(
                rgb: rgb, width: width, height: height, sigma: sigma, truncate: truncate
            )
            if let current = result {
                var accumulated = current
                for index in 0..<accumulated.count {
                    accumulated[index] += fit.amplitude * component[index]
                }
                result = accumulated
            } else {
                result = component.map { fit.amplitude * $0 }
            }
        }
        return result ?? rgb
    }

    // MARK: - The unsharp mask

    /// The unsharp mask of the scanner.
    ///
    /// Upstream reference: `spektrafilm.model.diffusion.apply_unsharp_mask`.
    ///
    /// ```
    /// image_sharp = image + amount * (image - gaussian_blur(image, sigma))
    /// ```
    ///
    /// - Parameters:
    ///   - rgb: the interleaved samples of the image.
    ///   - width: the width of the image.
    ///   - height: the height of the image.
    ///   - sigma: the standard deviation of the blur, in pixels.
    ///   - amount: the strength of the sharpening.
    /// - Returns: the sharpened image.
    public static func unsharpMask(
        rgb: [Double],
        width: Int,
        height: Int,
        sigma: Double,
        amount: Double
    ) -> [Double] {
        guard sigma > 0, amount > 0 else { return rgb }
        let blurred = gaussianFilter(rgb: rgb, width: width, height: height, sigma: sigma)
        var output = [Double](repeating: 0, count: rgb.count)
        for index in 0..<rgb.count {
            output[index] = rgb[index] + amount * (rgb[index] - blurred[index])
        }
        return output
    }
}
