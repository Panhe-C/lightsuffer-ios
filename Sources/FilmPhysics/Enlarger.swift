//
//  Enlarger.swift
//  light suffer胶片 — iOS app
//
//  The enlarger: the filtered illuminant of the printing stage and the
//  mid grey exposure normalisation.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The enlarger optics: the colour filters and the exposure normalisation.
public enum Enlarger {

    // MARK: - Illuminant

    /// Filters the enlarger light source with the CMY dichroic filters.
    ///
    /// Upstream reference: `spektrafilm.model.color_filters.color_enlarger`
    /// and `spektrafilm.model.color_filters.DichroicFilters.apply_cc`.
    ///
    /// The filter values are Kodak CC units (100 units = 1.0 density, i.e. a
    /// 90 % reduction of the transmittance):
    ///
    /// ```
    /// dimmed[l, c] = 1 - (1 - filter[l, c]) · (1 - 10 ** (-cc[c] / 100))
    /// filtered[l]  = light_source[l] · Π_c dimmed[l, c]
    /// ```
    ///
    /// - Parameters:
    ///   - lightSource: the illuminant spectrum, one value per wavelength.
    ///   - dichroicFilters: the transmittance of the CMY filters,
    ///     `[wavelength][channel]`.
    ///   - filterCC: the CC filter values (C, M, Y).
    /// - Returns: the filtered illuminant, one value per wavelength.
    public static func filteredIlluminant(
        lightSource: [Double],
        dichroicFilters: [[Double]],
        filterCC: [Double]
    ) -> [Double] {
        let transmittance = filterCC.map { pow(10.0, -$0 / 100.0) }
        var filtered = [Double](repeating: 0, count: lightSource.count)
        for wavelength in 0..<lightSource.count {
            var total = 1.0
            for channel in 0..<min(3, dichroicFilters[wavelength].count) {
                let filter = dichroicFilters[wavelength][channel]
                let dimmed = 1 - (1 - filter) * (1 - transmittance[channel])
                total *= dimmed
            }
            filtered[wavelength] = lightSource[wavelength] * total
        }
        return filtered
    }

    // MARK: - Exposure normalisation

    /// Computes the exposure factor that normalises the print exposure
    /// against a mid grey reference.
    ///
    /// Upstream reference: `spektrafilm.runtime.stages.printing._exposure_factor`.
    ///
    /// ```
    /// light  = 10 ** (-density_spectral_midgray) · print_illuminant
    /// raw    = light · print_sensitivity
    /// factor = 1 / geometric_mean(raw)
    /// ```
    ///
    /// - Parameters:
    ///   - sensitivity: the spectral sensitivity of the paper,
    ///     `[wavelength][channel]`.
    ///   - printIlluminant: the filtered enlarger illuminant.
    ///   - densitySpectralMidgray: the spectral density of the mid grey
    ///     reference patch, one value per wavelength.
    /// - Returns: the exposure factor.
    public static func exposureFactor(
        sensitivity: [[Double]],
        printIlluminant: [Double],
        densitySpectralMidgray: [Double]
    ) -> Double {
        let light = Spectral.densityToLight(density: densitySpectralMidgray, light: printIlluminant)
        var raw = [Double](repeating: 0, count: 3)
        for channel in 0..<3 {
            var total = 0.0
            for wavelength in 0..<min(sensitivity.count, printIlluminant.count) {
                total += light[wavelength] * sensitivity[wavelength][channel]
            }
            raw[channel] = Swift.max(total, 1e-10)
        }
        return 1.0 / Numerics.geometricMean(raw)
    }

    /// Selects the exposure factor the printing stage has to apply.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.printing.PrintingStage._compute_exposure_factor_midgray`.
    ///
    /// - Parameters:
    ///   - factorMidgray: the factor of the plain mid grey reference.
    ///   - factorMidgrayComp: the factor of the exposure compensated mid grey
    ///     reference (`nil` when the print exposure is not compensated).
    ///   - printExposureCompensation: whether the print exposure compensates
    ///     the camera exposure.
    ///   - normalizePrintExposure: whether the print exposure is normalised
    ///     against the mid grey reference.
    /// - Returns: the exposure factor to apply.
    public static func exposureFactorUsed(
        factorMidgray: Double,
        factorMidgrayComp: Double?,
        printExposureCompensation: Bool,
        normalizePrintExposure: Bool
    ) -> Double {
        if printExposureCompensation && !normalizePrintExposure {
            return (factorMidgrayComp ?? 1.0) / factorMidgray
        } else if normalizePrintExposure && printExposureCompensation {
            return factorMidgrayComp ?? 1.0
        } else if normalizePrintExposure && !printExposureCompensation {
            return factorMidgray
        } else {
            return 1.0
        }
    }
}
