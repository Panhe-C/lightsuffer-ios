//
//  Pipeline.swift
//  light suffer胶片 — iOS app
//
//  The public entry point of the ported pipeline: the slice 1 of the
//  spektrafilm simulation, from the log exposure of the negative to the
//  scanned print.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

// MARK: - Image

/// A plain image buffer with three interleaved components per pixel.
///
/// The pixels are stored row major, the first pixel of a row being the left
/// most one.
public struct RGBImage: Equatable, Sendable {
    /// The width of the image, in pixels.
    public var width: Int
    /// The height of the image, in pixels.
    public var height: Int
    /// The pixel data, three interleaved values per pixel.
    public var data: [Double]

    /// Creates an image.
    ///
    /// The data is expected to hold exactly `width * height * 3` values; use
    /// ``make(width:height:data:)`` to get a validated image.
    public init(width: Int, height: Int, data: [Double]) {
        self.width = width
        self.height = height
        self.data = data
    }

    /// Creates an image and validates its size.
    ///
    /// - Throws: `PipelineError.invalidImageData` when the data does not hold
    ///   exactly `width * height * 3` values.
    public static func make(width: Int, height: Int, data: [Double]) throws -> RGBImage {
        guard width >= 0, height >= 0 else {
            throw PipelineError.invalidImageData("the image dimensions must not be negative")
        }
        guard data.count == width * height * 3 else {
            throw PipelineError.invalidImageData(
                "expected \(width * height * 3) values for a \(width)x\(height) image, got \(data.count)"
            )
        }
        return RGBImage(width: width, height: height, data: data)
    }

    /// The number of pixels of the image.
    public var pixelCount: Int { width * height }

    /// The value of a pixel component.
    public subscript(x: Int, y: Int, channel: Int) -> Double {
        data[(y * width + x) * 3 + channel]
    }
}

/// The errors of the ported pipeline.
public enum PipelineError: Error, CustomStringConvertible {
    /// The image data does not match its dimensions.
    case invalidImageData(String)
    /// The inputs do not match the profiles.
    case invalidInputs(String)

    public var description: String {
        switch self {
        case let .invalidImageData(reason):
            return "invalid image data: \(reason)"
        case let .invalidInputs(reason):
            return "invalid pipeline inputs: \(reason)"
        }
    }
}

// MARK: - Inputs

/// The spectral data the pipeline needs.
public struct SpectralInputs: Equatable, Sendable {
    /// The CIE 1931 2° colour matching functions, `[wavelength][XYZ]`.
    public var colourMatchingFunctions: [[Double]]
    /// The illuminant of the scanner (the viewing illuminant of the paper),
    /// one value per wavelength.
    public var scanIlluminant: [Double]
    /// The normalisation of the scan illuminant, i.e. the sum of the
    /// illuminant weighted by the y-bar colour matching function.
    public var scanIlluminantNormalization: Double
    /// The light source of the enlarger (TH-KG3), one value per wavelength.
    public var enlargerLightSource: [Double]
    /// The transmittance of the CMY dichroic filters of the enlarger,
    /// `[wavelength][channel]`.
    public var dichroicFilters: [[Double]]

    public init(
        colourMatchingFunctions: [[Double]],
        scanIlluminant: [Double],
        scanIlluminantNormalization: Double,
        enlargerLightSource: [Double],
        dichroicFilters: [[Double]]
    ) {
        self.colourMatchingFunctions = colourMatchingFunctions
        self.scanIlluminant = scanIlluminant
        self.scanIlluminantNormalization = scanIlluminantNormalization
        self.enlargerLightSource = enlargerLightSource
        self.dichroicFilters = dichroicFilters
    }
}

/// The enlarger settings of the printing stage.
public struct EnlargerInputs: Equatable, Sendable {
    /// The neutral CC filter values (C, M, Y) of the enlarger.
    public var neutralFilterCC: [Double]
    /// The CC filter shifts (C, M, Y) the user applied on top of the neutral values.
    public var filterShiftCC: [Double]
    /// The CC filter shifts (C, M, Y) of the preflash.
    public var preflashFilterShiftCC: [Double]
    /// The exposure of the enlarger.
    public var printExposure: Double
    /// Whether the print exposure compensates the exposure of the camera.
    public var printExposureCompensation: Bool
    /// Whether the print exposure is normalised against the mid grey reference.
    public var normalizePrintExposure: Bool
    /// The preflash exposure of the enlarger.
    public var preflashExposure: Double
    /// The spectral density of the mid grey reference of the negative.
    ///
    /// The upstream engine computes it from the 0.184 grey patch during the
    /// filming stage (it needs the spectral upsampling of the camera image,
    /// which is not part of slice 1), so it is an explicit input here.
    public var densitySpectralMidgray: [Double]
    /// The spectral density of the exposure compensated mid grey reference.
    public var densitySpectralMidgrayComp: [Double]?

    public init(
        neutralFilterCC: [Double] = [0, 0, 0],
        filterShiftCC: [Double] = [0, 0, 0],
        preflashFilterShiftCC: [Double] = [0, 0, 0],
        printExposure: Double = 1.0,
        printExposureCompensation: Bool = true,
        normalizePrintExposure: Bool = true,
        preflashExposure: Double = 0,
        densitySpectralMidgray: [Double] = [],
        densitySpectralMidgrayComp: [Double]? = nil
    ) {
        self.neutralFilterCC = neutralFilterCC
        self.filterShiftCC = filterShiftCC
        self.preflashFilterShiftCC = preflashFilterShiftCC
        self.printExposure = printExposure
        self.printExposureCompensation = printExposureCompensation
        self.normalizePrintExposure = normalizePrintExposure
        self.preflashExposure = preflashExposure
        self.densitySpectralMidgray = densitySpectralMidgray
        self.densitySpectralMidgrayComp = densitySpectralMidgrayComp
    }
}

/// The scanner settings of the scanning stage.
public struct ScannerInputs: Equatable, Sendable {
    /// The XYZ to output RGB matrix.
    ///
    /// **Row `i` holds the RGB response to the `i`-th XYZ basis vector**, i.e.
    /// the conversion is the row vector product `rgb = xyz · matrix`. This is
    /// the layout of the reference fixtures, which store the matrix the way
    /// `colour.XYZ_to_RGB` returns it.
    public var xyzToRGB: [[Double]]
    /// The matrix the output transfer function applies before the encoding
    /// (`rgb = matrix · rgb`).
    public var srgbToSRGB: [[Double]]
    /// The output gamut compression algorithm (`"off"` in slice 1).
    public var outputGamutCompress: String
    /// The parameters of the output gamut compression.
    ///
    /// When `nil`, the compression is derived from ``outputGamutCompress``
    /// with the upstream default parameters.
    public var outputGamutCompressSpec: OutputGamutCompressSpec?
    /// The black and white reference of the print.
    public var colorReference: ColorReference

    public init(
        xyzToRGB: [[Double]],
        srgbToSRGB: [[Double]],
        outputGamutCompress: String = "off",
        outputGamutCompressSpec: OutputGamutCompressSpec? = nil,
        colorReference: ColorReference = ColorReference()
    ) {
        self.xyzToRGB = xyzToRGB
        self.srgbToSRGB = srgbToSRGB
        self.outputGamutCompress = outputGamutCompress
        self.outputGamutCompressSpec = outputGamutCompressSpec
        self.colorReference = colorReference
    }

    /// The output gamut compression to apply.
    public var resolvedOutputGamutCompress: OutputGamutCompressSpec? {
        if let outputGamutCompressSpec { return outputGamutCompressSpec }
        switch outputGamutCompress {
        case "off": return nil
        case "cam16ucs": return OutputGamutCompressSpec(algorithm: "cam16ucs")
        default: return nil
        }
    }
}

/// The film rendering settings of the development stage.
public struct FilmRenderInputs: Equatable, Sendable {
    /// The DIR coupler parameters.
    public var dirCouplers: DirCouplersParams
    /// The gamma factor of the density curves.
    public var densityCurveGamma: Double
    /// The minimum density of the grain, per channel.
    ///
    /// It defines the black patch of the negative, which the printing stage
    /// uses for the black reference.
    public var grainDensityMin: [Double]

    public init(
        dirCouplers: DirCouplersParams = DirCouplersParams(),
        densityCurveGamma: Double = 1.0,
        grainDensityMin: [Double] = [0.03, 0.03, 0.03]
    ) {
        self.dirCouplers = dirCouplers
        self.densityCurveGamma = densityCurveGamma
        self.grainDensityMin = grainDensityMin
    }
}

/// Everything the slice 1 pipeline needs besides the two profiles.
public struct Slice1Inputs: Equatable, Sendable {
    /// The spectral data.
    public var spectral: SpectralInputs
    /// The enlarger settings.
    public var enlarger: EnlargerInputs
    /// The scanner settings.
    public var scanner: ScannerInputs
    /// The film rendering settings.
    public var filmRender: FilmRenderInputs

    public init(
        spectral: SpectralInputs,
        enlarger: EnlargerInputs,
        scanner: ScannerInputs,
        filmRender: FilmRenderInputs = FilmRenderInputs()
    ) {
        self.spectral = spectral
        self.enlarger = enlarger
        self.scanner = scanner
        self.filmRender = filmRender
    }
}

// MARK: - Taps

/// The taps of the slice 1 pipeline.
public struct Slice1Taps: Equatable, Sendable {
    /// The developed densities of the negative.
    public var cmyFilm: RGBImage
    /// The log10 exposure of the paper.
    public var logEPrint: RGBImage
    /// The developed densities of the print.
    public var cmyPrint: RGBImage
    /// The scanned and encoded print.
    public var rgbOut: RGBImage

    public init(cmyFilm: RGBImage, logEPrint: RGBImage, cmyPrint: RGBImage, rgbOut: RGBImage) {
        self.cmyFilm = cmyFilm
        self.logEPrint = logEPrint
        self.cmyPrint = cmyPrint
        self.rgbOut = rgbOut
    }
}

// MARK: - Pipeline

/// The slice 1 of the spektrafilm pipeline.
///
/// The pipeline starts at the log exposure of the negative (the tap the
/// upstream engine calls `log_e_film`) and runs the three remaining stages:
///
/// ```
/// log_e_film ──▶ filming.develop ──▶ cmy_film
/// cmy_film    ──▶ printing.expose ──▶ log_e_print
/// log_e_print ──▶ printing.develop ──▶ cmy_print
/// cmy_print   ──▶ scanning.scan   ──▶ rgb_out
/// ```
///
/// The spectral upsampling of the camera image (the `rgb_in` → `log_e_film`
/// stage) is not part of slice 1: its result is injected.
public struct Slice1Pipeline {

    /// The profile of the negative.
    public let film: Profile
    /// The profile of the paper.
    public let print: Profile
    /// The data the pipeline needs besides the profiles.
    public let inputs: Slice1Inputs

    /// Creates a pipeline.
    ///
    /// - Throws: `PipelineError.invalidInputs` when the inputs do not match
    ///   the spectral sampling of the profiles.
    public init(film: Profile, print: Profile, inputs: Slice1Inputs) throws {
        let wavelengths = film.data.wavelengths.count
        guard print.data.wavelengths.count == wavelengths else {
            throw PipelineError.invalidInputs(
                "the film and the print profiles must share the same spectral sampling"
            )
        }
        guard inputs.spectral.colourMatchingFunctions.count == wavelengths,
              inputs.spectral.scanIlluminant.count == wavelengths,
              inputs.spectral.enlargerLightSource.count == wavelengths,
              inputs.spectral.dichroicFilters.count == wavelengths
        else {
            throw PipelineError.invalidInputs(
                "the spectral inputs must have \(wavelengths) wavelength samples"
            )
        }
        guard inputs.scanner.xyzToRGB.count == 3, inputs.scanner.srgbToSRGB.count == 3 else {
            throw PipelineError.invalidInputs("the colour matrices must be 3x3")
        }
        guard inputs.scanner.outputGamutCompress == "off"
            || inputs.scanner.outputGamutCompress == "cam16ucs"
        else {
            // Only the "off" and the "cam16ucs" output gamut compressions
            // are ported.
            throw PipelineError.invalidInputs(
                "the output gamut compression '\(inputs.scanner.outputGamutCompress)' is not ported yet"
            )
        }
        self.film = film
        self.print = print
        self.inputs = inputs
    }

    /// Runs the pipeline.
    ///
    /// - Parameter logEFilm: the log10 exposure of the negative.
    /// - Returns: the taps of the pipeline.
    public func run(logEFilm: RGBImage) throws -> Slice1Taps {
        guard logEFilm.data.count == logEFilm.width * logEFilm.height * 3 else {
            throw PipelineError.invalidImageData(
                "expected \(logEFilm.width * logEFilm.height * 3) values for a "
                    + "\(logEFilm.width)x\(logEFilm.height) image, got \(logEFilm.data.count)"
            )
        }
        var colorReference = inputs.scanner.colorReference
        let cmyFilm = developFilm(logEFilm)
        let logEPrint = exposePrint(cmyFilm, colorReference: &colorReference)
        let cmyPrint = developPrint(logEPrint)
        let rgbOut = scanPrint(cmyPrint, colorReference: colorReference)
        return Slice1Taps(
            cmyFilm: cmyFilm, logEPrint: logEPrint, cmyPrint: cmyPrint, rgbOut: rgbOut
        )
    }

    /// Runs the direct scan path: the negative is developed and scanned
    /// directly, without being printed on a paper.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.pipeline.SimulationPipeline._build_topology` (the
    /// `io.scan_film` branch) and
    /// `spektrafilm.runtime.stages.scanning.ScanningStage.scan`.
    ///
    /// ```
    /// log_e_film ──▶ filming.develop ──▶ cmy_film ──▶ scanning.scan ──▶ rgb_out
    /// ```
    ///
    /// The scanning stage uses the **film** (not the paper) channel density,
    /// base density and viewing illuminant, exactly like the upstream
    /// `_return_callable_cmy_to_log_xyz` does when `io.scan_film` is set.
    ///
    /// - Parameters:
    ///   - logEFilm: the log10 exposure of the negative.
    ///   - colorReference: the black / white reference of the scan.
    /// - Returns: the scanned and encoded image.
    public func runScanFilm(
        logEFilm: RGBImage,
        colorReference: ColorReference
    ) throws -> RGBImage {
        guard logEFilm.data.count == logEFilm.width * logEFilm.height * 3 else {
            throw PipelineError.invalidImageData(
                "expected \(logEFilm.width * logEFilm.height * 3) values for a "
                    + "\(logEFilm.width)x\(logEFilm.height) image, got \(logEFilm.data.count)"
            )
        }
        let cmyFilm = developFilm(logEFilm)
        return scanFilm(cmyFilm, colorReference: colorReference)
    }

    // MARK: - Stages

    /// Develops the negative.
    ///
    /// Upstream reference: `spektrafilm.runtime.stages.filming.FilmingStage.develop`
    /// and `spektrafilm.model.develop.develop` (without the grain).
    func developFilm(_ logRaw: RGBImage) -> RGBImage {
        let normalized = DensityCurves.normalized(film.data.densityCurves)
        var density = DensityCurves.interpolateExposureToDensity(
            logExposureRGB: logRaw.data,
            densityCurves: normalized,
            logExposure: film.data.logExposure,
            gammaFactor: inputs.filmRender.densityCurveGamma
        )

        let couplers = inputs.filmRender.dirCouplers
        if couplers.active {
            let positive = film.info.type == .positive
            var matrix = Couplers.matrix(couplers)
            for row in 0..<3 {
                for column in 0..<3 {
                    matrix[row][column] *= couplers.amount
                }
            }
            let curvesBeforeCouplers = Couplers.densityCurvesBeforeCouplers(
                densityCurves: normalized,
                logExposure: film.data.logExposure,
                matrix: matrix,
                positive: positive
            )
            // The maximum density of every channel (`np.nanmax(density_curves, axis=0)`).
            let densityMax = (0..<3).map { channel in
                Numerics.nanMax(normalized.map { $0[channel] })
            }
            let correctedLogRaw = Couplers.exposureCorrection(
                logRaw: logRaw.data,
                densityCMY: density,
                densityMax: densityMax,
                matrix: matrix,
                positive: positive
            )
            density = DensityCurves.interpolateExposureToDensity(
                logExposureRGB: correctedLogRaw,
                densityCurves: curvesBeforeCouplers,
                logExposure: film.data.logExposure,
                gammaFactor: inputs.filmRender.densityCurveGamma
            )
        }

        return RGBImage(width: logRaw.width, height: logRaw.height, data: density)
    }

    /// Exposes the paper.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.printing.PrintingStage.expose`.
    private func exposePrint(_ cmyFilm: RGBImage, colorReference: inout ColorReference) -> RGBImage {
        let printSensitivity = print.data.logSensitivity.map { row in
            row.map { pow(10.0, $0) }
        }
        let sensitivity = printSensitivity.map(Numerics.nanToNum)

        let filterCC = (0..<3).map { channel in
            inputs.enlarger.neutralFilterCC[channel] + inputs.enlarger.filterShiftCC[channel]
        }
        let printIlluminant = Enlarger.filteredIlluminant(
            lightSource: inputs.spectral.enlargerLightSource,
            dichroicFilters: inputs.spectral.dichroicFilters,
            filterCC: filterCC
        )

        let factorMidgray = Enlarger.exposureFactor(
            sensitivity: sensitivity,
            printIlluminant: printIlluminant,
            densitySpectralMidgray: inputs.enlarger.densitySpectralMidgray
        )
        let factorMidgrayComp: Double? = inputs.enlarger.densitySpectralMidgrayComp.map {
            Enlarger.exposureFactor(
                sensitivity: sensitivity,
                printIlluminant: printIlluminant,
                densitySpectralMidgray: $0
            )
        }
        let exposureFactor = Enlarger.exposureFactorUsed(
            factorMidgray: factorMidgray,
            factorMidgrayComp: factorMidgrayComp,
            printExposureCompensation: inputs.enlarger.printExposureCompensation,
            normalizePrintExposure: inputs.enlarger.normalizePrintExposure
        )

        let preflashCC = (0..<3).map { channel in
            inputs.enlarger.neutralFilterCC[channel] + inputs.enlarger.preflashFilterShiftCC[channel]
        }
        let preflash = Printing.rawPreflash(
            lightSource: inputs.spectral.enlargerLightSource,
            dichroicFilters: inputs.spectral.dichroicFilters,
            filterCC: preflashCC,
            filmBaseDensity: film.data.baseDensity,
            printSensitivity: sensitivity,
            preflashExposure: inputs.enlarger.preflashExposure
        )

        // The black and the white patch of the negative, used by the black
        // and white reference of the print.
        let cmyFilmBlack = inputs.filmRender.grainDensityMin.map { -$0 }
        let cmyFilmWhite = (0..<3).map { channel in
            Numerics.nanMax(film.data.densityCurves.map { $0[channel] })
        }

        let logRawBlack = Printing.filmCMYToPrintLogRaw(
            cmyFilmDensity: cmyFilmBlack,
            filmChannelDensity: film.data.channelDensity,
            filmBaseDensity: film.data.baseDensity,
            printSensitivity: sensitivity,
            printIlluminant: printIlluminant,
            exposureFactor: exposureFactor,
            preflash: preflash
        )
        let logRawWhite = Printing.filmCMYToPrintLogRaw(
            cmyFilmDensity: cmyFilmWhite,
            filmChannelDensity: film.data.channelDensity,
            filmBaseDensity: film.data.baseDensity,
            printSensitivity: sensitivity,
            printIlluminant: printIlluminant,
            exposureFactor: exposureFactor,
            preflash: preflash
        )

        colorReference.logRawPrintBlack = logRawBlack
        colorReference.logRawPrintWhite = logRawWhite
        colorReference.updateReferences(
            printProfile: print,
            cmyToLogXYZ: { cmy in
                Scanning.cmyToLogXYZ(
                    cmy: cmy,
                    channelDensity: print.data.channelDensity,
                    baseDensity: print.data.baseDensity,
                    scanIlluminant: inputs.spectral.scanIlluminant,
                    colourMatchingFunctions: inputs.spectral.colourMatchingFunctions,
                    normalization: inputs.spectral.scanIlluminantNormalization
                )
            }
        )

        let logRawPrint = Printing.filmCMYToPrintLogRaw(
            cmyFilmDensity: cmyFilm.data,
            filmChannelDensity: film.data.channelDensity,
            filmBaseDensity: film.data.baseDensity,
            printSensitivity: sensitivity,
            printIlluminant: printIlluminant,
            exposureFactor: exposureFactor,
            preflash: preflash
        )

        let blackWhiteCorrection = colorReference.printingExposureCorrection(printProfile: print)
        let exposure = logRawPrint.map { value -> Double in
            let raw = pow(10.0, value) * inputs.enlarger.printExposure * blackWhiteCorrection
            return log10(Swift.max(raw, 0.0) + 1e-10)
        }
        return RGBImage(width: cmyFilm.width, height: cmyFilm.height, data: exposure)
    }

    /// Develops the paper.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.printing.PrintingStage.develop`.
    private func developPrint(_ logRaw: RGBImage) -> RGBImage {
        let density = Printing.develop(logRaw: logRaw.data, printProfile: print)
        return RGBImage(width: logRaw.width, height: logRaw.height, data: density)
    }

    /// Scans the print.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.scanning.ScanningStage.scan`.
    private func scanPrint(_ cmyPrint: RGBImage, colorReference: ColorReference) -> RGBImage {
        let rgb = Scanning.scan(
            cmy: cmyPrint.data,
            printProfile: print,
            scanIlluminant: inputs.spectral.scanIlluminant,
            normalization: inputs.spectral.scanIlluminantNormalization,
            colourMatchingFunctions: inputs.spectral.colourMatchingFunctions,
            xyzToRGB: inputs.scanner.xyzToRGB,
            srgbToSRGB: inputs.scanner.srgbToSRGB,
            colorReference: colorReference,
            outputGamutCompress: inputs.scanner.resolvedOutputGamutCompress
        )
        return RGBImage(width: cmyPrint.width, height: cmyPrint.height, data: rgb)
    }

    /// Scans the negative directly, without printing it.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.scanning.ScanningStage._density_to_rgb`
    /// (the `io.scan_film` branch) and
    /// `ScanningStage._return_callable_cmy_to_log_xyz`.
    ///
    /// The film is scanned with its own channel density, base density and
    /// viewing illuminant; the glare of the print is not applied (the
    /// upstream sets `glare = None` for a direct film scan).
    private func scanFilm(_ cmyFilm: RGBImage, colorReference: ColorReference) -> RGBImage {
        let rgb = Scanning.scan(
            cmy: cmyFilm.data,
            channelDensity: film.data.channelDensity,
            baseDensity: film.data.baseDensity,
            scanIlluminant: inputs.spectral.scanIlluminant,
            normalization: inputs.spectral.scanIlluminantNormalization,
            colourMatchingFunctions: inputs.spectral.colourMatchingFunctions,
            xyzToRGB: inputs.scanner.xyzToRGB,
            srgbToSRGB: inputs.scanner.srgbToSRGB,
            colorReference: colorReference,
            outputGamutCompress: inputs.scanner.resolvedOutputGamutCompress
        )
        return RGBImage(width: cmyFilm.width, height: cmyFilm.height, data: rgb)
    }
}
