//
//  Halation.swift
//  light suffer胶片 — iOS app
//
//  The halation and the scatter of the negative: the in emulsion scatter,
//  the back reflection halation and the highlight boost that reconstructs
//  the pre clip irradiance.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The parameters of the halation and the scatter of the negative.
///
/// Upstream reference: `spektrafilm.runtime.params_schema.HalationParams`.
public struct HalationParams: Equatable, Sendable {
    /// Whether the halation and the scatter are applied at all.
    public var active: Bool
    /// The amount of the in emulsion scatter.
    public var scatterAmount: Double
    /// The multiplier on the image plane widths of the scatter.
    public var scatterSpatialScale: Double
    /// The amount of the back reflection halation.
    public var halationAmount: Double
    /// The multiplier on the image plane widths of the halation.
    public var halationSpatialScale: Double
    /// The width of the Gaussian core of the scatter, in micrometres.
    public var scatterCoreUM: [Double]
    /// The decay constant of the exponential tail of the scatter, in micrometres.
    public var scatterTailUM: [Double]
    /// The weight of the exponential tail of the scatter.
    public var scatterTailWeight: [Double]
    /// The highlight boost, in stops.
    public var boostEV: Double
    /// The range of the highlight boost, in `[0, 1]`.
    public var boostRange: Double
    /// The protection of the mid grey of the highlight boost, in stops.
    public var protectEV: Double
    /// The strength of the halation, per channel.
    public var halationStrength: [Double]
    /// The width of the first halation bounce, in micrometres.
    public var halationFirstSigmaUM: [Double]
    /// The number of halation bounces.
    public var halationNBounces: Int
    /// The decay of the halation bounces.
    public var halationBounceDecay: Double
    /// Whether the halation is renormalised.
    public var halationRenormalize: Bool

    public init(
        active: Bool = true,
        scatterAmount: Double = 1.0,
        scatterSpatialScale: Double = 1.0,
        halationAmount: Double = 1.0,
        halationSpatialScale: Double = 1.0,
        scatterCoreUM: [Double] = [2.2, 2.0, 1.6],
        scatterTailUM: [Double] = [9.3, 9.7, 9.1],
        scatterTailWeight: [Double] = [0.78, 0.65, 0.67],
        boostEV: Double = 0.0,
        boostRange: Double = 0.3,
        protectEV: Double = 4.0,
        halationStrength: [Double] = [0.05, 0.015, 0.0],
        halationFirstSigmaUM: [Double] = [65.0, 65.0, 65.0],
        halationNBounces: Int = 3,
        halationBounceDecay: Double = 0.5,
        halationRenormalize: Bool = true
    ) {
        self.active = active
        self.scatterAmount = scatterAmount
        self.scatterSpatialScale = scatterSpatialScale
        self.halationAmount = halationAmount
        self.halationSpatialScale = halationSpatialScale
        self.scatterCoreUM = scatterCoreUM
        self.scatterTailUM = scatterTailUM
        self.scatterTailWeight = scatterTailWeight
        self.boostEV = boostEV
        self.boostRange = boostRange
        self.protectEV = protectEV
        self.halationStrength = halationStrength
        self.halationFirstSigmaUM = halationFirstSigmaUM
        self.halationNBounces = halationNBounces
        self.halationBounceDecay = halationBounceDecay
        self.halationRenormalize = halationRenormalize
    }
}

/// The halation and the scatter of the negative.
///
/// Upstream reference: `spektrafilm.model.diffusion.apply_halation_um` and
/// `spektrafilm.utils.numba_boost_hightlights.boost_highlights`.
public enum Halation {

    /// The size of a pixel of the negative, in micrometres.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.services.resize.ResizingService.crop_and_rescale`.
    ///
    /// ```
    /// pixel_size_um = film_format_mm * 1000 / max(height, width)
    /// ```
    ///
    /// - Parameters:
    ///   - filmFormatMM: the width of the film frame, in millimetres.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    /// - Returns: the size of a pixel, in micrometres.
    public static func pixelSizeUM(filmFormatMM: Double, width: Int, height: Int) -> Double {
        let longest = max(width, height)
        guard longest > 0 else { return 0 }
        return filmFormatMM * 1000 / Double(longest)
    }

    /// Applies the highlight boost to the raw response of the negative.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.numba_boost_hightlights.boost_highlights`.
    ///
    /// The boost reconstructs the irradiance that hit the emulsion before
    /// the sensor clipped it: the response is normalised by the maximum of
    /// the image, the boost curve is applied in the normalised space and the
    /// result is scaled back.
    ///
    /// - Parameters:
    ///   - raw: the raw response of the negative, three values per pixel.
    ///   - boostEV: the strength of the boost, in stops.
    ///   - boostRange: the range of the boost, in `[0, 1]`.
    ///   - protectEV: the protection of the mid grey, in stops.
    ///   - midgray: the raw domain mid grey reference.
    /// - Returns: the boosted response.
    public static func boostHighlights(
        raw: [Double],
        boostEV: Double,
        boostRange: Double,
        protectEV: Double,
        midgray: Double = 0.184
    ) -> [Double] {
        guard boostEV != 0 else { return raw }
        var maxRaw = -Double.infinity
        for value in raw where !value.isNaN {
            maxRaw = Swift.max(maxRaw, value)
        }
        guard maxRaw != 0, !maxRaw.isInfinite else { return raw }
        let rawX0 = min(max(midgray * pow(2.0, protectEV), 0.0), maxRaw)
        guard rawX0 != maxRaw else { return raw }

        let a = pow(28.0, 1.0 - boostRange)
        let x0 = rawX0 / maxRaw
        let denominator = exp(a * (1.0 - x0)) - a * (1.0 - x0) - 1.0
        guard denominator > 0 else { return raw }
        let k = (pow(2.0, boostEV) - 1.0) / denominator
        let inverseMaxRaw = 1.0 / maxRaw
        let boostScale = k * maxRaw

        var output = [Double](repeating: 0, count: raw.count)
        for index in 0..<raw.count {
            let value = raw[index]
            if value <= rawX0 {
                output[index] = value
            } else {
                let dx = (value - rawX0) * inverseMaxRaw
                output[index] = value + boostScale * (exp(a * dx) - a * dx - 1.0)
            }
        }
        return output
    }

    /// Applies the in emulsion scatter and the back reflection halation.
    ///
    /// Upstream reference: `spektrafilm.model.diffusion.apply_halation_um`.
    ///
    /// The ordering is scatter then halation: the scatter propagates the
    /// irradiance through the absorbing emulsion as an energy preserving
    /// mixture of a Gaussian core and an exponential tail, and the halation
    /// adds the back reflected light as an additive sum of `N` Gaussians
    /// with `sqrt(k)` spaced widths.
    ///
    /// - Parameters:
    ///   - raw: the raw response of the negative, three values per pixel.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    ///   - params: the parameters of the halation.
    ///   - pixelSizeUM: the size of a pixel, in micrometres.
    /// - Returns: the scattered and bloomed response.
    public static func apply(
        raw: [Double],
        width: Int,
        height: Int,
        params: HalationParams,
        pixelSizeUM: Double
    ) -> [Double] {
        guard params.active else { return raw }
        guard pixelSizeUM > 0 else { return raw }
        var result = raw

        // 1. The scatter pass.
        let scatterAmount = params.scatterAmount
        let scatterScale = params.scatterSpatialScale
        let tailWeight = params.scatterTailWeight
        let corePixels = params.scatterCoreUM.map { $0 * scatterScale / pixelSizeUM }
        let tailPixels = params.scatterTailUM.map { $0 * scatterScale / pixelSizeUM }
        let hasCore = corePixels.contains { $0 > 0 }
        let hasTail = tailPixels.contains { $0 > 0 }
        if scatterAmount > 0, hasCore || hasTail {
            let core = SpatialEffects.gaussianFilter(
                rgb: result,
                width: width,
                height: height,
                sigma: corePixels.map { max($0, 1e-6) }
            )
            let tail = SpatialEffects.exponentialFilter(
                rgb: result,
                width: width,
                height: height,
                decayConstant: tailPixels.map { max($0, 1e-6) }
            )
            var scattered = [Double](repeating: 0, count: result.count)
            for index in 0..<result.count {
                let channel = index % 3
                let weight = channel < tailWeight.count ? tailWeight[channel] : 0
                scattered[index] = (1.0 - weight) * core[index] + weight * tail[index]
            }
            var updated = [Double](repeating: 0, count: result.count)
            for index in 0..<result.count {
                updated[index] = (1.0 - scatterAmount) * result[index] + scatterAmount * scattered[index]
            }
            result = updated
        }

        // 2. The halation pass.
        let halationAmount = params.halationAmount
        let halationScale = params.halationSpatialScale
        let strength = params.halationStrength.map { $0 * halationAmount }
        let sigmaPixels = params.halationFirstSigmaUM.map { $0 * halationScale / pixelSizeUM }
        let bounces = params.halationNBounces
        let decay = params.halationBounceDecay
        let hasStrength = strength.contains { $0 > 0 }
        let hasSigma = sigmaPixels.contains { $0 > 0 }
        if bounces >= 1, hasStrength, hasSigma {
            var weights = [Double](repeating: 0, count: bounces)
            var total = 0.0
            for index in 0..<bounces {
                weights[index] = pow(decay, Double(index))
                total += weights[index]
            }
            if total > 0 {
                for index in 0..<bounces { weights[index] /= total }
            }
            var blur = [Double](repeating: 0, count: result.count)
            for index in 0..<bounces {
                let sigma = sigmaPixels.map { max($0 * sqrt(Double(index + 1)), 1e-6) }
                let component = SpatialEffects.gaussianFilter(
                    rgb: result, width: width, height: height, sigma: sigma
                )
                for position in 0..<blur.count {
                    blur[position] += weights[index] * component[position]
                }
            }
            var updated = [Double](repeating: 0, count: result.count)
            for position in 0..<result.count {
                let channel = position % 3
                let amount = channel < strength.count ? strength[channel] : 0
                updated[position] = result[position] + amount * blur[position]
            }
            if params.halationRenormalize {
                for position in 0..<updated.count {
                    let channel = position % 3
                    let amount = channel < strength.count ? strength[channel] : 0
                    updated[position] /= (1.0 + amount)
                }
            }
            result = updated
        }

        return result
    }
}
