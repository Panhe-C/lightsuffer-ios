//
//  Filming.swift
//  light suffer胶片 — iOS app
//
//  The filming stage: the camera image is upsampled to a spectrum, exposed
//  on the negative and turned into a log exposure.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The filming stage of the pipeline.
public enum Filming {

    /// The raw sensor response of the negative for an RGB image.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.filming.FilmingStage._rgb_to_film_raw`.
    ///
    /// The band pass filter of the camera (`camera.filter_uv` /
    /// `camera.filter_ir`) is inactive at the upstream defaults, so only the
    /// spectral upsampling is applied.
    ///
    /// - Parameters:
    ///   - rgb: the RGB values of the image, three interleaved values per pixel.
    ///   - lut: the hanatos 2025 lookup table of the film.
    ///   - colourspace: the colourspace of the values.
    ///   - applyCCTFDecoding: whether the values are encoded.
    ///   - referenceIlluminant: the chromaticity of the reference illuminant
    ///     of the film.
    /// - Returns: the raw responses, three interleaved values per pixel.
    public static func rawFromRGB(
        rgb: [Double],
        lut: HanatosTCLUT,
        colourspace: RGBColourspace,
        applyCCTFDecoding: Bool,
        referenceIlluminant: Chromaticity
    ) -> [Double] {
        SpectralUpsampling.rgbToRaw(
            rgb: rgb,
            lut: lut,
            colourspace: colourspace,
            applyCCTFDecoding: applyCCTFDecoding,
            referenceIlluminant: referenceIlluminant
        )
    }

    /// The log exposure of the negative.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.filming.FilmingStage.expose`.
    ///
    /// ```
    /// raw      = raw · 2 ** exposure_compensation_ev
    /// raw     *= black_white_filming_exposure_correction()
    /// log_raw  = log10(max(raw, 0) + 1e-10)
    /// ```
    ///
    /// The highlight boost (`boost_highlights`), the diffusion filter, the
    /// lens blur and the halation are inactive at the upstream defaults.
    ///
    /// - Parameters:
    ///   - raw: the raw responses of the negative.
    ///   - exposureCompensationEV: the exposure compensation of the camera.
    ///   - blackWhiteFilmingExposureCorrection: the black / white correction
    ///     of the exposure (1.0 when the correction is inactive).
    /// - Returns: the log10 exposures, three interleaved values per pixel.
    public static func expose(
        raw: [Double],
        exposureCompensationEV: Double,
        blackWhiteFilmingExposureCorrection: Double = 1.0
    ) -> [Double] {
        let scale = pow(2.0, exposureCompensationEV) * blackWhiteFilmingExposureCorrection
        return raw.map { value in
            log10(Swift.max(value * scale, 0.0) + 1e-10)
        }
    }

    /// The spectral density of the mid grey patch of the negative.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.filming.FilmingStage._compute_density_spectral_midgray_to_balance_print`
    /// and `FilmingStage._simple_rgb_to_density_spectral`.
    ///
    /// The reference patch is a 0.184 grey; it is upsampled with the *default*
    /// colour space of the upstream helper (sRGB, without CCTF decoding),
    /// whatever the input colour space of the pipeline is, and developed with
    /// the *un-normalised* density curves of the film.
    ///
    /// - Parameters:
    ///   - film: the profile of the negative.
    ///   - lut: the hanatos 2025 lookup table of the film.
    ///   - referenceIlluminant: the chromaticity of the reference illuminant
    ///     of the film.
    ///   - gammaFactor: the gamma factor of the density curves.
    ///   - exposureCompensationEV: the exposure compensation of the camera.
    ///   - printExposureCompensation: whether the print exposure compensates
    ///     the camera exposure.
    /// - Returns: the spectral density of the reference patch and, when the
    ///   print exposure is compensated, of its exposure compensated variant.
    public static func densitySpectralMidgray(
        film: Profile,
        lut: HanatosTCLUT,
        referenceIlluminant: Chromaticity,
        gammaFactor: Double = 1.0,
        exposureCompensationEV: Double = 0.0,
        printExposureCompensation: Bool = true
    ) -> (midgray: [Double], compensated: [Double]?) {
        let midgray = densitySpectralOfPatch(
            value: 0.184,
            film: film,
            lut: lut,
            referenceIlluminant: referenceIlluminant,
            gammaFactor: gammaFactor
        )
        guard printExposureCompensation else { return (midgray, nil) }
        let compensated = densitySpectralOfPatch(
            value: 0.184 * pow(2.0, exposureCompensationEV),
            film: film,
            lut: lut,
            referenceIlluminant: referenceIlluminant,
            gammaFactor: gammaFactor
        )
        return (midgray, compensated)
    }

    /// The spectral density of a neutral patch of the negative.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.filming.FilmingStage._simple_rgb_to_density_spectral`.
    private static func densitySpectralOfPatch(
        value: Double,
        film: Profile,
        lut: HanatosTCLUT,
        referenceIlluminant: Chromaticity,
        gammaFactor: Double
    ) -> [Double] {
        let raw = rawFromRGB(
            rgb: [value, value, value],
            lut: lut,
            colourspace: .sRGB,
            applyCCTFDecoding: false,
            referenceIlluminant: referenceIlluminant
        )
        // The upstream helper uses log10(raw + 1e-10) (without clamping).
        let logRaw = raw.map { log10($0 + 1e-10) }
        let densityCMY = DensityCurves.interpolateExposureToDensity(
            logExposureRGB: logRaw,
            densityCurves: film.data.densityCurves,
            logExposure: film.data.logExposure,
            gammaFactor: gammaFactor
        )
        return Spectral.densitySpectral(
            channelDensity: film.data.channelDensity,
            densityCMY: densityCMY,
            baseDensity: film.data.baseDensity
        )
    }
}
