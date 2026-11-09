//
//  DensityCurves.swift
//  light suffer胶片 — iOS app
//
//  Density curve evaluation: the characteristic curves of a film or paper
//  and the parametric (CDF sum) model used by the print stage.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The characteristic density curves of an emulsion and the interpolation
/// that turns a log exposure into a CMY density.
public enum DensityCurves {

    // MARK: - Curve normalisation

    /// Normalises the density curves per channel by subtracting the minimum
    /// density of the channel (`density_curves - np.nanmin(density_curves, axis=0)`).
    ///
    /// Upstream reference: `spektrafilm.model.develop.develop`.
    ///
    /// - Parameter densityCurves: the raw curves, `[sample][channel]`.
    /// - Returns: the normalised curves, `[sample][channel]`.
    public static func normalized(_ densityCurves: [[Double]]) -> [[Double]] {
        guard !densityCurves.isEmpty else { return [] }
        let channels = densityCurves[0].count
        var minima = [Double](repeating: .infinity, count: channels)
        for sample in densityCurves {
            for channel in 0..<channels where channel < sample.count {
                let value = sample[channel]
                if !value.isNaN { minima[channel] = Swift.min(minima[channel], value) }
            }
        }
        return densityCurves.map { sample in
            sample.enumerated().map { channel, value in
                let minimum = minima[channel]
                return minimum.isFinite ? value - minimum : value
            }
        }
    }

    // MARK: - Exposure to density

    /// Interpolates a log exposure image into CMY densities.
    ///
    /// Upstream reference: `spektrafilm.model.density_curves.interpolate_exposure_to_density`,
    /// which calls the numba kernel `spektrafilm.utils.fast_interp.fast_interp`.
    ///
    /// The upstream kernel differs slightly from `numpy.interp`:
    /// * the axis can be channel specific (`log_exposure[:, None] / gamma_factor`),
    /// * values below / above the axis are clamped to the first / last sample,
    /// * the interpolation is right biased on exact axis hits,
    /// * duplicated axis entries contribute a zero slope.
    ///
    /// - Parameters:
    ///   - logExposureRGB: the log10 exposures, three interleaved values per pixel.
    ///   - densityCurves: the density curves, `[sample][channel]`.
    ///   - logExposure: the log exposure axis, one entry per curve sample.
    ///   - gammaFactor: the per channel gamma factor (a single value is
    ///     broadcast to the three channels).
    /// - Returns: the interpolated densities, three interleaved values per pixel.
    public static func interpolateExposureToDensity(
        logExposureRGB: [Double],
        densityCurves: [[Double]],
        logExposure: [Double],
        gammaFactor: [Double]
    ) -> [Double] {
        let channels = 3
        let samples = logExposure.count
        guard !densityCurves.isEmpty, samples > 0 else {
            return [Double](repeating: 0, count: logExposureRGB.count)
        }

        // The per channel axis is log_exposure / gamma_factor, and the
        // reciprocal of the axis steps (the upstream kernel pre-computes
        // them, using 0 for duplicated axis entries).
        var axis = [[Double]](repeating: [], count: channels)
        var inverseStep = [[Double]](repeating: [], count: channels)
        for channel in 0..<channels {
            let gamma = gammaFactor[channel]
            var channelAxis = [Double](repeating: 0, count: samples)
            for sample in 0..<samples {
                channelAxis[sample] = logExposure[sample] / gamma
            }
            var channelStep = [Double](repeating: 0, count: max(samples - 1, 0))
            for sample in 0..<max(samples - 1, 0) {
                let step = channelAxis[sample + 1] - channelAxis[sample]
                channelStep[sample] = step != 0 ? 1.0 / step : 0
            }
            axis[channel] = channelAxis
            inverseStep[channel] = channelStep
        }

        var result = [Double](repeating: 0, count: logExposureRGB.count)
        let pixels = logExposureRGB.count / channels
        for pixel in 0..<pixels {
            for channel in 0..<channels {
                let x = logExposureRGB[pixel * channels + channel]
                let y: Double
                if x <= axis[channel][0] {
                    y = densityCurves[0][channel]
                } else if x >= axis[channel][samples - 1] {
                    y = densityCurves[samples - 1][channel]
                } else {
                    let index = Numerics.searchSortedRight(axis[channel], x)
                    let low = index - 1
                    let t = (x - axis[channel][low]) * inverseStep[channel][low]
                    y = densityCurves[low][channel]
                        + t * (densityCurves[low + 1][channel] - densityCurves[low][channel])
                }
                result[pixel * channels + channel] = y
            }
        }
        return result
    }

    /// Interpolates a log exposure image into CMY densities with a single
    /// gamma factor for the three channels.
    public static func interpolateExposureToDensity(
        logExposureRGB: [Double],
        densityCurves: [[Double]],
        logExposure: [Double],
        gammaFactor: Double = 1.0
    ) -> [Double] {
        interpolateExposureToDensity(
            logExposureRGB: logExposureRGB,
            densityCurves: densityCurves,
            logExposure: logExposure,
            gammaFactor: [gammaFactor, gammaFactor, gammaFactor]
        )
    }

    // MARK: - Parametric (CDF sum) model

    /// Evaluates the parametric density curve model of a profile.
    ///
    /// Upstream reference: `spektrafilm.utils.morph_curves._evaluate_fitted_density`,
    /// which sums one scaled normal CDF per emulsion layer:
    ///
    /// ```
    /// D(x) = Σ_i A_i · Φ((x - μ_i) / σ_i)
    /// ```
    ///
    /// For positive (slide) emulsions the CDF is mirrored (`Φ(-z)`), because
    /// the silver density is `d_max - d`.
    ///
    /// - Parameters:
    ///   - logExposure: the log exposure samples.
    ///   - model: the parametric model of the profile.
    ///   - profileType: the type of the emulsion the model belongs to.
    /// - Returns: the fitted density curves, `[sample][channel]`.
    public static func evaluateFittedDensity(
        logExposure: [Double],
        model: DensityCurvesModel,
        profileType: ProfileType
    ) -> [[Double]] {
        let channels = model.nChannels
        var fitted = [[Double]](repeating: [Double](repeating: 0, count: channels), count: logExposure.count)
        guard channels > 0 else { return fitted }

        for channel in 0..<channels {
            let centers = model.centers[channel]
            let amplitudes = model.amplitudes[channel]
            let sigmas = model.sigmas[channel]
            let layers = min(centers.count, min(amplitudes.count, sigmas.count))
            for sample in 0..<logExposure.count {
                let x = logExposure[sample]
                var total = 0.0
                for layer in 0..<layers {
                    let z = (x - centers[layer]) / sigmas[layer]
                    let signed = profileType == .positive ? -z : z
                    total += amplitudes[layer] * Numerics.normalCDF(signed)
                }
                fitted[sample][channel] = total
            }
        }
        return fitted
    }
}
