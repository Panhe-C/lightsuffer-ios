//
//  ColorReference.swift
//  light suffer胶片 — iOS app
//
//  The black / white reference of the print: the densities of the darkest
//  and the brightest patch of the negative, used to correct the exposure and
//  the scanned tristimulus values.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The black and white reference of the print.
///
/// Upstream reference: `spektrafilm.runtime.services.color_reference.ColorReferenceService`.
///
/// With both corrections disabled (the slice 1 configuration) the service is
/// an identity: the printing exposure and the scanned XYZ values are not
/// touched. The reference densities are nevertheless computed, exactly like
/// the upstream service does, so that the values can be compared with the
/// reference fixtures.
public struct ColorReference: Equatable, Sendable {

    /// The scanner black level, in the encoded (sRGB) domain.
    public var blackLevel: Double
    /// The scanner white level, in the encoded (sRGB) domain.
    public var whiteLevel: Double
    /// Whether the black level correction is active.
    public var blackCorrection: Bool
    /// Whether the white level correction is active.
    public var whiteCorrection: Bool

    /// The log exposure of the paper for the black patch of the negative.
    public var logRawPrintBlack: [Double]?
    /// The log exposure of the paper for the white patch of the negative.
    public var logRawPrintWhite: [Double]?

    /// The luminance of the black reference, once the references are updated.
    public private(set) var yBlack: Double?
    /// The luminance of the white reference, once the references are updated.
    public private(set) var yWhite: Double?

    public init(
        blackLevel: Double = 0.01,
        whiteLevel: Double = 0.98,
        blackCorrection: Bool = false,
        whiteCorrection: Bool = false
    ) {
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.blackCorrection = blackCorrection
        self.whiteCorrection = whiteCorrection
    }

    /// `true` when neither the black nor the white correction is active.
    public var isIdentity: Bool { !blackCorrection && !whiteCorrection }

    /// Updates the black and white reference luminances.
    ///
    /// Upstream reference:
    /// `ColorReferenceService._update_cmy_black_white_references`.
    ///
    /// - Parameters:
    ///   - printProfile: the profile of the paper.
    ///   - cmyToLogXYZ: the conversion of the scanning stage, used to turn
    ///     the reference densities into tristimulus values.
    public mutating func updateReferences(
        printProfile: Profile,
        cmyToLogXYZ: ([Double]) -> [Double]
    ) {
        guard !isIdentity else { return }
        guard let logRawPrintBlack, let logRawPrintWhite else { return }

        let cmyBlack = DensityCurves.interpolateExposureToDensity(
            logExposureRGB: logRawPrintBlack,
            densityCurves: printProfile.data.densityCurves,
            logExposure: printProfile.data.logExposure,
            gammaFactor: 1.0
        )
        let cmyWhite = DensityCurves.interpolateExposureToDensity(
            logExposureRGB: logRawPrintWhite,
            densityCurves: printProfile.data.densityCurves,
            logExposure: printProfile.data.logExposure,
            gammaFactor: 1.0
        )
        let logXYZBlack = cmyToLogXYZ(cmyBlack)
        let logXYZWhite = cmyToLogXYZ(cmyWhite)
        yBlack = pow(10.0, logXYZBlack[1])
        yWhite = pow(10.0, logXYZWhite[1])
    }

    /// The slope and the offset of the black / white correction.
    ///
    /// Upstream reference: `ColorReferenceService._correction_fucntion`.
    private func correctionFunction() -> (slope: Double, offset: Double)? {
        guard !isIdentity else { return nil }
        guard let yBlack, let yWhite else { return nil }
        var whiteLevel = self.whiteLevel
        var blackLevel = self.blackLevel
        if blackCorrection && !whiteCorrection {
            whiteLevel = yWhite
        }
        if whiteCorrection && !blackCorrection {
            blackLevel = yBlack
        }
        let slope = (whiteLevel - blackLevel) / (yWhite - yBlack + 1e-10)
        let offset = blackLevel - slope * yBlack
        return (slope, offset)
    }

    /// The correction of the print exposure.
    ///
    /// Upstream reference:
    /// `ColorReferenceService.black_white_printing_exposure_correction`.
    ///
    /// - Parameter printProfile: the profile of the paper.
    /// - Returns: the exposure correction factor (1.0 when the correction is off).
    public func printingExposureCorrection(printProfile: Profile) -> Double {        guard !isIdentity else { return 1.0 }
        guard printProfile.info.type == .negative else { return 1.0 }
        guard let correction = correctionFunction() else { return 1.0 }
        let midgray = -log10(0.184)
        let midgrayCorrected = (0.184 - correction.offset) / correction.slope
        let densityMidgrayCorrected = -log10(midgrayCorrected)

        // The mean density curve of the paper, sampled against the density.
        var densityCurveAverage = [Double](repeating: 0, count: printProfile.data.densityCurves.count)
        for sample in printProfile.data.densityCurves.indices {
            densityCurveAverage[sample] = Numerics.nanMean(printProfile.data.densityCurves[sample])
        }
        let densityMinAverage = Numerics.nanMean(printProfile.data.baseDensity)

        let logExposure = printProfile.data.logExposure
        let logExposureMidgrayCorrected = Numerics.interpolate(
            x: densityMidgrayCorrected - densityMinAverage,
            axis: densityCurveAverage,
            values: logExposure
        )
        let logExposureMidgray = Numerics.interpolate(
            x: midgray - densityMinAverage,
            axis: densityCurveAverage,
            values: logExposure
        )
        return pow(10.0, logExposureMidgrayCorrected - logExposureMidgray)
    }

    /// The correction of the exposure of the camera.
    ///
    /// Upstream reference:
    /// `ColorReferenceService.black_white_filming_exposure_correction`.
    ///
    /// The correction is only active for a positive film that is scanned
    /// directly; a negative (the print and scan path) is never corrected.
    ///
    /// - Parameters:
    ///   - film: the profile of the film.
    ///   - print: the profile of the paper.
    ///   - scanFilm: whether the film is scanned directly.
    /// - Returns: the exposure correction factor (1.0 when the correction is off).
    public func filmingExposureCorrection(
        film: Profile,
        print: Profile,
        scanFilm: Bool
    ) -> Double {
        guard !isIdentity else { return 1.0 }
        guard film.info.type != .negative else { return 1.0 }
        guard scanFilm, film.info.type == .positive else { return 1.0 }
        guard let correction = correctionFunction() else { return 1.0 }

        let midgray = -log10(0.184)
        let midgrayCorrected = (0.184 - correction.offset) / correction.slope
        let densityMidgrayCorrected = -log10(midgrayCorrected)

        var densityCurveAverage = [Double](repeating: 0, count: film.data.densityCurves.count)
        for sample in film.data.densityCurves.indices {
            densityCurveAverage[sample] = Numerics.nanMean(film.data.densityCurves[sample])
        }
        let densityMinAverage = Numerics.nanMean(film.data.baseDensity)
        let logExposure = film.data.logExposure

        // The upstream interpolates on the *mirrored* density curve.
        let mirroredCurve = densityCurveAverage.map { -$0 }
        let mirroredAxis = logExposure
        let logExposureMidgrayCorrected = Numerics.interpolate(
            x: -(densityMidgrayCorrected - densityMinAverage),
            axis: mirroredCurve,
            values: mirroredAxis
        )
        let logExposureMidgray = Numerics.interpolate(
            x: -(midgray - densityMinAverage),
            axis: mirroredCurve,
            values: mirroredAxis
        )
        let exposureCorrection = pow(10.0, logExposureMidgrayCorrected - logExposureMidgray)
        return 1.0 / exposureCorrection
    }

    /// The correction of the scanned tristimulus values.
    ///
    /// Upstream reference: `ColorReferenceService.black_white_xyz_correction`.
    ///
    /// - Parameter xyz: the scanned tristimulus values, three values per pixel.
    /// - Returns: the corrected tristimulus values, three values per pixel.
    public func xyzCorrection(xyz: [Double]) -> [Double] {
        guard !isIdentity else { return xyz }
        guard let correction = correctionFunction() else { return xyz }
        var corrected = xyz
        let pixels = xyz.count / 3
        for pixel in 0..<pixels {
            let y = xyz[pixel * 3 + 1]
            let yCorrected = Swift.min(Swift.max(correction.slope * y + correction.offset, 0), 1)
            let scale = yCorrected / (y + 1e-10)
            for channel in 0..<3 {
                corrected[pixel * 3 + channel] = xyz[pixel * 3 + channel] * scale
            }
        }
        return corrected
    }
}
