//
//  Printing.swift
//  light suffer胶片 — iOS app
//
//  The printing stage: the negative is printed on the paper and the paper
//  is developed.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The printing stage of the pipeline.
public enum Printing {

    /// The exposure of the paper for a given CMY density of the negative.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.printing.PrintingStage._film_cmy_to_print_log_raw`.
    ///
    /// ```
    /// density_spectral = film_channel_density · cmy_density + film_base_density
    /// light            = 10 ** (-density_spectral) · print_illuminant
    /// raw              = light · print_sensitivity
    /// raw             *= exposure_factor
    /// raw             += preflash
    /// log_raw          = log10(max(raw, 0) + 1e-10)
    /// ```
    ///
    /// - Parameters:
    ///   - cmyFilmDensity: the densities of the negative, three values per pixel.
    ///   - filmChannelDensity: the spectral density of the negative,
    ///     `[wavelength][channel]`.
    ///   - filmBaseDensity: the base density of the negative, one value per wavelength.
    ///   - printSensitivity: the spectral sensitivity of the paper,
    ///     `[wavelength][channel]`.
    ///   - printIlluminant: the filtered enlarger illuminant.
    ///   - exposureFactor: the mid grey exposure normalisation factor.
    ///   - preflash: the preflash contribution per channel.
    /// - Returns: the log10 exposure of the paper, three values per pixel.
    public static func filmCMYToPrintLogRaw(
        cmyFilmDensity: [Double],
        filmChannelDensity: [[Double]],
        filmBaseDensity: [Double],
        printSensitivity: [[Double]],
        printIlluminant: [Double],
        exposureFactor: Double,
        preflash: [Double] = [0, 0, 0]
    ) -> [Double] {
        let wavelengths = min(filmChannelDensity.count, printIlluminant.count)
        let densitySpectral = Spectral.densitySpectral(
            channelDensity: filmChannelDensity,
            densityCMY: cmyFilmDensity,
            baseDensity: filmBaseDensity
        )
        let light = Spectral.densityToLight(
            density: densitySpectral, wavelengths: wavelengths, light: printIlluminant
        )
        var raw = Spectral.contractWithSensitivity(
            light: light, wavelengths: wavelengths, sensitivity: printSensitivity
        )
        for index in 0..<raw.count {
            raw[index] = raw[index] * exposureFactor + preflash[index % 3]
        }
        return log10Floor(raw)
    }

    /// The preflash contribution of the enlarger.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.printing.PrintingStage._compute_raw_preflash`.
    ///
    /// - Parameters:
    ///   - lightSource: the illuminant spectrum of the enlarger.
    ///   - dichroicFilters: the transmittance of the CMY filters.
    ///   - filterCC: the CC filter values (C, M, Y) used for the preflash.
    ///   - filmBaseDensity: the base density of the negative.
    ///   - printSensitivity: the spectral sensitivity of the paper.
    ///   - preflashExposure: the preflash exposure.
    /// - Returns: the preflash contribution per channel.
    public static func rawPreflash(
        lightSource: [Double],
        dichroicFilters: [[Double]],
        filterCC: [Double],
        filmBaseDensity: [Double],
        printSensitivity: [[Double]],
        preflashExposure: Double
    ) -> [Double] {
        guard preflashExposure > 0 else { return [0, 0, 0] }
        let preflashIlluminant = Enlarger.filteredIlluminant(
            lightSource: lightSource, dichroicFilters: dichroicFilters, filterCC: filterCC
        )
        let light = Spectral.densityToLight(density: filmBaseDensity, light: preflashIlluminant)
        var raw = [Double](repeating: 0, count: 3)
        for channel in 0..<3 {
            var total = 0.0
            for wavelength in 0..<min(printSensitivity.count, light.count) {
                total += light[wavelength] * printSensitivity[wavelength][channel]
            }
            raw[channel] = total * preflashExposure
        }
        return raw
    }

    /// Develops the exposed paper into CMY densities.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.printing.PrintingStage.develop` and
    /// `spektrafilm.model.develop.develop_print_morph`.
    ///
    /// With the density curve morph inactive the stage evaluates the fitted
    /// (sum of CDFs) model of the paper profile and interpolates the log
    /// exposure of the paper with it.
    ///
    /// - Parameters:
    ///   - logRaw: the log10 exposure of the paper, three values per pixel.
    ///   - printProfile: the profile of the paper.
    /// - Returns: the developed densities, three values per pixel.
    public static func develop(
        logRaw: [Double],
        printProfile: Profile
    ) -> [Double] {
        let curves = DensityCurves.evaluateFittedDensity(
            logExposure: printProfile.data.logExposure,
            model: printProfile.data.densityCurvesModel,
            profileType: printProfile.info.type
        )
        return DensityCurves.interpolateExposureToDensity(
            logExposureRGB: logRaw,
            densityCurves: curves,
            logExposure: printProfile.data.logExposure,
            gammaFactor: 1.0
        )
    }

    /// Converts a linear exposure into a log exposure, clamping the negative
    /// values the way the upstream pipeline does.
    ///
    /// Upstream reference: `numpy.log10(numpy.fmax(raw, 0.0) + 1e-10)`.
    public static func log10Floor(_ values: [Double]) -> [Double] {
        values.map { value in
            log10(Swift.max(value, 0.0) + 1e-10)
        }
    }

}
