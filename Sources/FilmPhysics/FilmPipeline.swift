//
//  FilmPipeline.swift
//  light suffer胶片 — iOS app
//
//  The public entry point of the ported pipeline: the whole spektrafilm
//  simulation, from the camera image to the scanned print.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

// MARK: - Parameters

/// The parameters of the camera.
///
/// Upstream reference: `spektrafilm.runtime.params_schema.CameraParams`.
public struct CameraParams: Equatable, Sendable {
    /// The exposure compensation of the camera, in stops.
    public var exposureCompensationEV: Double
    /// Whether the camera meters the image.
    public var autoExposure: Bool
    /// The radius of the lens blur, in micrometres.
    public var lensBlurUM: Double

    public init(
        exposureCompensationEV: Double = 0.0,
        autoExposure: Bool = true,
        lensBlurUM: Double = 0.0
    ) {
        self.exposureCompensationEV = exposureCompensationEV
        self.autoExposure = autoExposure
        self.lensBlurUM = lensBlurUM
    }
}

/// The parameters of the enlarger.
///
/// Upstream reference: `spektrafilm.runtime.params_schema.EnlargerParams`.
public struct EnlargerParams: Equatable, Sendable {
    /// The illuminant of the enlarger.
    public var illuminant: String
    /// The exposure of the enlarger.
    public var printExposure: Double
    /// Whether the print exposure compensates the exposure of the camera.
    public var printExposureCompensation: Bool
    /// Whether the print exposure is normalised against the mid grey reference.
    public var normalizePrintExposure: Bool
    /// The shift of the yellow filter, in Kodak CC units.
    public var yFilterShift: Double
    /// The shift of the magenta filter, in Kodak CC units.
    public var mFilterShift: Double
    /// The neutral yellow filter, in Kodak CC units.
    public var yFilterNeutral: Double
    /// The neutral magenta filter, in Kodak CC units.
    public var mFilterNeutral: Double
    /// The neutral cyan filter, in Kodak CC units.
    public var cFilterNeutral: Double
    /// The radius of the lens blur of the enlarger.
    public var lensBlur: Double
    /// The preflash exposure of the enlarger.
    public var preflashExposure: Double
    /// The shift of the yellow filter of the preflash.
    public var preflashYFilterShift: Double
    /// The shift of the magenta filter of the preflash.
    public var preflashMFilterShift: Double

    public init(
        illuminant: String = "TH-KG3",
        printExposure: Double = 1.0,
        printExposureCompensation: Bool = true,
        normalizePrintExposure: Bool = true,
        yFilterShift: Double = 0.0,
        mFilterShift: Double = 0.0,
        yFilterNeutral: Double = 55,
        mFilterNeutral: Double = 65,
        cFilterNeutral: Double = 0,
        lensBlur: Double = 0.0,
        preflashExposure: Double = 0.0,
        preflashYFilterShift: Double = 0.0,
        preflashMFilterShift: Double = 0.0
    ) {
        self.illuminant = illuminant
        self.printExposure = printExposure
        self.printExposureCompensation = printExposureCompensation
        self.normalizePrintExposure = normalizePrintExposure
        self.yFilterShift = yFilterShift
        self.mFilterShift = mFilterShift
        self.yFilterNeutral = yFilterNeutral
        self.mFilterNeutral = mFilterNeutral
        self.cFilterNeutral = cFilterNeutral
        self.lensBlur = lensBlur
        self.preflashExposure = preflashExposure
        self.preflashYFilterShift = preflashYFilterShift
        self.preflashMFilterShift = preflashMFilterShift
    }
}

/// The parameters of the scanner.
///
/// Upstream reference: `spektrafilm.runtime.params_schema.ScannerParams`.
public struct ScannerParams: Equatable, Sendable {
    /// The radius of the lens blur of the scanner.
    public var lensBlur: Double
    /// Whether the white level correction is applied.
    public var whiteCorrection: Bool
    /// Whether the black level correction is applied.
    public var blackCorrection: Bool
    /// The white level of the scanner, in the encoded domain.
    public var whiteLevel: Double
    /// The black level of the scanner, in the encoded domain.
    public var blackLevel: Double
    /// The sigma of the unsharp mask.
    public var unsharpMaskSigma: Double
    /// The amount of the unsharp mask.
    public var unsharpMaskAmount: Double

    public init(
        lensBlur: Double = 0.0,
        whiteCorrection: Bool = false,
        blackCorrection: Bool = false,
        whiteLevel: Double = 0.98,
        blackLevel: Double = 0.01,
        unsharpMaskSigma: Double = 0.7,
        unsharpMaskAmount: Double = 0.7
    ) {
        self.lensBlur = lensBlur
        self.whiteCorrection = whiteCorrection
        self.blackCorrection = blackCorrection
        self.whiteLevel = whiteLevel
        self.blackLevel = blackLevel
        self.unsharpMaskSigma = unsharpMaskSigma
        self.unsharpMaskAmount = unsharpMaskAmount
    }
}

/// The parameters of the film rendering.
///
/// Upstream reference: `spektrafilm.runtime.params_schema.FilmRenderingParams`.
public struct FilmRenderParams: Equatable, Sendable {
    /// The DIR coupler parameters.
    public var dirCouplers: DirCouplersParams
    /// The gamma factor of the density curves.
    public var densityCurveGamma: Double
    /// The minimum density of the grain, per channel.
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

/// The input / output parameters.
///
/// Upstream reference: `spektrafilm.runtime.params_schema.IOParams`.
public struct IOParams: Equatable, Sendable {
    /// The colourspace of the input image.
    public var inputColorSpace: String
    /// Whether the input image is encoded (and has to be decoded).
    public var inputCCTFDecoding: Bool
    /// The colourspace of the output image.
    public var outputColorSpace: String
    /// Whether the output image is encoded.
    public var outputCCTFEncoding: Bool
    /// The input gamut compression.
    public var inputGamutCompress: InputGamutCompressSpec
    /// The output gamut compression.
    public var outputGamutCompress: OutputGamutCompressSpec
    /// Whether the film is scanned directly (without printing it).
    public var scanFilm: Bool

    public init(
        inputColorSpace: String = "ProPhoto RGB",
        inputCCTFDecoding: Bool = false,
        outputColorSpace: String = "sRGB",
        outputCCTFEncoding: Bool = true,
        inputGamutCompress: InputGamutCompressSpec = InputGamutCompressSpec(),
        outputGamutCompress: OutputGamutCompressSpec = OutputGamutCompressSpec(),
        scanFilm: Bool = false
    ) {
        self.inputColorSpace = inputColorSpace
        self.inputCCTFDecoding = inputCCTFDecoding
        self.outputColorSpace = outputColorSpace
        self.outputCCTFEncoding = outputCCTFEncoding
        self.inputGamutCompress = inputGamutCompress
        self.outputGamutCompress = outputGamutCompress
        self.scanFilm = scanFilm
    }
}

/// The settings of the pipeline.
///
/// Upstream reference: `spektrafilm.runtime.params_schema.SettingsParams`.
public struct SettingsParams: Equatable, Sendable {
    /// The RGB to raw method (`"hanatos2025"`).
    public var rgbToRawMethod: String
    /// Whether the hanatos 2025 band pass window is applied.
    public var applyHanatos2025AdaptationWindow: Bool
    /// Whether the hanatos 2025 log exposure correction surface is applied.
    public var applyHanatos2025AdaptationSurface: Bool
    /// The sigma of the Gaussian blur applied to the spectra.
    public var spectralGaussianBlur: Double
    /// Whether the enlarger uses the 3D LUT approximation.
    public var useEnlargerLUT: Bool
    /// Whether the scanner uses the 3D LUT approximation.
    public var useScannerLUT: Bool
    /// Whether the neutral print filters come from the database.
    public var neutralPrintFiltersFromDatabase: Bool

    public init(
        rgbToRawMethod: String = "hanatos2025",
        applyHanatos2025AdaptationWindow: Bool = true,
        applyHanatos2025AdaptationSurface: Bool = false,
        spectralGaussianBlur: Double = 0.0,
        useEnlargerLUT: Bool = false,
        useScannerLUT: Bool = false,
        neutralPrintFiltersFromDatabase: Bool = true
    ) {
        self.rgbToRawMethod = rgbToRawMethod
        self.applyHanatos2025AdaptationWindow = applyHanatos2025AdaptationWindow
        self.applyHanatos2025AdaptationSurface = applyHanatos2025AdaptationSurface
        self.spectralGaussianBlur = spectralGaussianBlur
        self.useEnlargerLUT = useEnlargerLUT
        self.useScannerLUT = useScannerLUT
        self.neutralPrintFiltersFromDatabase = neutralPrintFiltersFromDatabase
    }
}

/// The parameters of the pipeline.
///
/// Upstream reference: `spektrafilm.runtime.params_schema.RuntimePhotoParams`.
public struct PipelineParams: Equatable, Sendable {
    /// The profile of the negative.
    public var film: Profile
    /// The profile of the paper.
    public var print: Profile
    /// The camera parameters.
    public var camera: CameraParams
    /// The film rendering parameters.
    public var filmRender: FilmRenderParams
    /// The enlarger parameters.
    public var enlarger: EnlargerParams
    /// The scanner parameters.
    public var scanner: ScannerParams
    /// The input / output parameters.
    public var io: IOParams
    /// The settings of the pipeline.
    public var settings: SettingsParams

    public init(
        film: Profile,
        print: Profile,
        camera: CameraParams = CameraParams(),
        filmRender: FilmRenderParams = FilmRenderParams(),
        enlarger: EnlargerParams = EnlargerParams(),
        scanner: ScannerParams = ScannerParams(),
        io: IOParams = IOParams(),
        settings: SettingsParams = SettingsParams()
    ) {
        self.film = film
        self.print = print
        self.camera = camera
        self.filmRender = filmRender
        self.enlarger = enlarger
        self.scanner = scanner
        self.io = io
        self.settings = settings
    }
}

// MARK: - Taps

/// The taps of the pipeline.
public struct FilmTaps: Equatable, Sendable {
    /// The log10 exposure of the negative.
    public var logEFilm: RGBImage
    /// The developed densities of the negative.
    public var cmyFilm: RGBImage
    /// The log10 exposure of the paper.
    public var logEPrint: RGBImage
    /// The developed densities of the print.
    public var cmyPrint: RGBImage
    /// The scanned and encoded print.
    public var rgbOut: RGBImage

    public init(
        logEFilm: RGBImage,
        cmyFilm: RGBImage,
        logEPrint: RGBImage,
        cmyPrint: RGBImage,
        rgbOut: RGBImage
    ) {
        self.logEFilm = logEFilm
        self.cmyFilm = cmyFilm
        self.logEPrint = logEPrint
        self.cmyPrint = cmyPrint
        self.rgbOut = rgbOut
    }
}

// MARK: - Pipeline

/// The whole spektrafilm simulation, from the camera image to the scanned
/// print.
///
/// Upstream reference: `spektrafilm.runtime.pipeline.SimulationPipeline`.
///
/// ```
/// rgb_in ──▶ log_e_film ──▶ cmy_film ──▶ log_e_print ──▶ cmy_print ──▶ rgb_out
/// ```
///
/// The spatial and the stochastic effects (grain, halation, diffusion
/// filters, glare, blur, unsharp mask) are not part of this slice; the
/// pipeline runs the exact spectral path.
public struct FilmPipeline {

    /// The parameters of the pipeline.
    public let params: PipelineParams
    /// The hanatos 2025 lookup table of the film.
    public let tcLUT: HanatosTCLUT
    /// The inputs of the printing and the scanning stages.
    public let inputs: Slice1Inputs

    /// Creates a pipeline.
    ///
    /// - Parameter params: the parameters of the simulation.
    /// - Throws: `PipelineError.invalidInputs` when the parameters are not
    ///   supported by the port.
    public init(params: PipelineParams) throws {
        guard params.settings.rgbToRawMethod == "hanatos2025" else {
            throw PipelineError.invalidInputs(
                "the RGB to raw method '\(params.settings.rgbToRawMethod)' is not ported yet"
            )
        }
        guard !params.io.scanFilm else {
            throw PipelineError.invalidInputs("the direct film scan is not ported yet")
        }
        guard params.camera.autoExposure == false else {
            throw PipelineError.invalidInputs("the auto exposure is not ported yet")
        }
        guard params.camera.lensBlurUM == 0,
              params.enlarger.lensBlur == 0,
              params.scanner.lensBlur == 0
        else {
            throw PipelineError.invalidInputs("the lens blurs are not ported yet")
        }
        guard params.scanner.unsharpMaskSigma == 0, params.scanner.unsharpMaskAmount == 0 else {
            throw PipelineError.invalidInputs("the unsharp mask is not ported yet")
        }
        guard let inputColourSpace = RGBColourspace.named(params.io.inputColorSpace) else {
            throw PipelineError.invalidInputs(
                "the input colour space '\(params.io.inputColorSpace)' is not supported"
            )
        }
        guard RGBColourspace.named(params.io.outputColorSpace) != nil else {
            throw PipelineError.invalidInputs(
                "the output colour space '\(params.io.outputColorSpace)' is not supported"
            )
        }

        self.params = params

        // --- the spectral data -----------------------------------------
        let colourMatchingFunctions = try Resources.colourMatchingFunctions()
        let illuminants = try Resources.illuminants()
        let wavelengths = params.film.data.wavelengths
        guard wavelengths.count == colourMatchingFunctions.count else {
            throw PipelineError.invalidInputs(
                "the spectral sampling of the film profile does not match the bundled colour "
                    + "matching functions"
            )
        }
        let scanIlluminantLabel = params.print.info.viewingIlluminant
        guard let scanIlluminant = illuminants[scanIlluminantLabel] else {
            throw PipelineError.invalidInputs(
                "the illuminant '\(scanIlluminantLabel)' is not bundled with the package"
            )
        }
        guard let enlargerLightSource = illuminants[params.enlarger.illuminant] else {
            throw PipelineError.invalidInputs(
                "the illuminant '\(params.enlarger.illuminant)' is not bundled with the package"
            )
        }
        var normalization = 0.0
        for wavelength in 0..<scanIlluminant.count {
            normalization += scanIlluminant[wavelength] * colourMatchingFunctions[wavelength][1]
        }

        let dichroicFilters = ColorFilters.customDichroicFilters(wavelengths: wavelengths)

        // --- the hanatos 2025 lookup table ------------------------------
        let sensitivity = params.film.data.logSensitivity.map { row in
            Numerics.nanToNum(row.map { pow(10.0, $0) })
        }
        var adaptation = params.film.hanatos2025Adaptation()
        adaptation.applyWindow = params.settings.applyHanatos2025AdaptationWindow
        adaptation.applySurface = params.settings.applyHanatos2025AdaptationSurface
        adaptation.spectralGaussianBlur = params.settings.spectralGaussianBlur
        let spectra = try Resources.hanatosSpectra()
        guard let adaptationIlluminant = illuminants[adaptation.referenceIlluminant] else {
            throw PipelineError.invalidInputs(
                "the illuminant '\(adaptation.referenceIlluminant)' is not bundled with the package"
            )
        }
        let tcLUT = SpectralUpsampling.computeHanatos2025TCLUT(
            sensitivity: sensitivity,
            adaptation: adaptation,
            gamutCompress: params.io.inputGamutCompress,
            spectra: spectra,
            illuminant: adaptationIlluminant,
            wavelengths: wavelengths
        )
        self.tcLUT = tcLUT

        // --- the colour matrices ----------------------------------------
        let referenceIlluminantXY = Illuminants.chromaticity(
            of: params.film.info.referenceIlluminant,
            illuminants: illuminants,
            colourMatchingFunctions: colourMatchingFunctions
        )
        let scanIlluminantXY = Illuminants.chromaticity(
            of: scanIlluminantLabel,
            illuminants: illuminants,
            colourMatchingFunctions: colourMatchingFunctions
        )
        // XYZ -> RGB: the CAT02 adaptation is applied to the input and the
        // (unadapted) sRGB matrix afterwards.
        //
        // Upstream reference: `colour.XYZ_to_RGB`.
        let adaptationMatrix = ChromaticAdaptationTransform.cat02.matrix(
            from: ColourScience.xyToXYZ(scanIlluminantXY),
            to: RGBColourspace.sRGB.whitepointXYZ
        )
        let effectiveXYZToRGB = Matrix.multiply(
            RGBColourspace.sRGB.matrixXYZToRGB,
            adaptationMatrix
        )
        // The port stores the matrix with the RGB response of every XYZ
        // basis vector in its rows (the layout of the reference fixtures).
        var xyzToRGB = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for row in 0..<3 {
            for column in 0..<3 {
                xyzToRGB[row][column] = effectiveXYZToRGB[column][row]
            }
        }
        let srgbToSRGB = ColourScience.matrixRGBToRGB(from: .sRGB, to: .sRGB)

        // --- the neutral print filters ----------------------------------
        var neutralFilterCC = [
            params.enlarger.cFilterNeutral,
            params.enlarger.mFilterNeutral,
            params.enlarger.yFilterNeutral,
        ]
        if params.settings.neutralPrintFiltersFromDatabase,
            let databaseValues = NeutralPrintFilters.lookup(
                printStock: params.print.info.stock,
                illuminant: params.enlarger.illuminant,
                filmStock: params.film.info.stock
            )
        {
            neutralFilterCC = databaseValues
        }

        // --- the print balance reference --------------------------------
        let (midgray, midgrayCompensated) = Filming.densitySpectralMidgray(
            film: params.film,
            lut: tcLUT,
            referenceIlluminant: referenceIlluminantXY,
            gammaFactor: params.filmRender.densityCurveGamma,
            exposureCompensationEV: params.camera.exposureCompensationEV,
            printExposureCompensation: params.enlarger.printExposureCompensation
        )

        // --- the digest of the film rendering ---------------------------
        var digest = Digest.filmRender(for: params.film)
        digest.dirCouplers = params.filmRender.dirCouplers
        digest.densityCurveGamma = params.filmRender.densityCurveGamma

        let spectralInputs = SpectralInputs(
            colourMatchingFunctions: colourMatchingFunctions,
            scanIlluminant: scanIlluminant,
            scanIlluminantNormalization: normalization,
            enlargerLightSource: enlargerLightSource,
            dichroicFilters: dichroicFilters
        )
        let enlargerInputs = EnlargerInputs(
            neutralFilterCC: neutralFilterCC,
            filterShiftCC: [0, params.enlarger.mFilterShift, params.enlarger.yFilterShift],
            preflashFilterShiftCC: [
                0, params.enlarger.preflashMFilterShift, params.enlarger.preflashYFilterShift,
            ],
            printExposure: params.enlarger.printExposure,
            printExposureCompensation: params.enlarger.printExposureCompensation,
            normalizePrintExposure: params.enlarger.normalizePrintExposure,
            preflashExposure: params.enlarger.preflashExposure,
            densitySpectralMidgray: midgray,
            densitySpectralMidgrayComp: midgrayCompensated
        )
        let scannerInputs = ScannerInputs(
            xyzToRGB: xyzToRGB,
            srgbToSRGB: srgbToSRGB,
            outputGamutCompress: params.io.outputGamutCompress.algorithm,
            outputGamutCompressSpec: params.io.outputGamutCompress,
            colorReference: ColorReference(
                blackLevel: params.scanner.blackLevel,
                whiteLevel: params.scanner.whiteLevel,
                blackCorrection: params.scanner.blackCorrection,
                whiteCorrection: params.scanner.whiteCorrection
            )
        )
        let filmRenderInputs = FilmRenderInputs(
            dirCouplers: digest.dirCouplers,
            densityCurveGamma: digest.densityCurveGamma,
            grainDensityMin: params.filmRender.grainDensityMin
        )
        self.inputs = Slice1Inputs(
            spectral: spectralInputs,
            enlarger: enlargerInputs,
            scanner: scannerInputs,
            filmRender: filmRenderInputs
        )
    }

    /// Runs the simulation.
    ///
    /// - Parameter rgbIn: the camera image, in the input colourspace.
    /// - Returns: the taps of the pipeline.
    public func process(rgbIn: RGBImage) throws -> FilmTaps {
        guard rgbIn.data.count == rgbIn.width * rgbIn.height * 3 else {
            throw PipelineError.invalidImageData(
                "expected \(rgbIn.width * rgbIn.height * 3) values for a "
                    + "\(rgbIn.width)x\(rgbIn.height) image, got \(rgbIn.data.count)"
            )
        }
        guard let inputColourSpace = RGBColourspace.named(params.io.inputColorSpace) else {
            throw PipelineError.invalidInputs(
                "the input colour space '\(params.io.inputColorSpace)' is not supported"
            )
        }
        let illuminants = try Resources.illuminants()
        let colourMatchingFunctions = try Resources.colourMatchingFunctions()
        let referenceIlluminantXY = Illuminants.chromaticity(
            of: params.film.info.referenceIlluminant,
            illuminants: illuminants,
            colourMatchingFunctions: colourMatchingFunctions
        )

        // --- the filming stage ------------------------------------------
        let raw = Filming.rawFromRGB(
            rgb: rgbIn.data,
            lut: tcLUT,
            colourspace: inputColourSpace,
            applyCCTFDecoding: params.io.inputCCTFDecoding,
            referenceIlluminant: referenceIlluminantXY
        )
        let colorReference = inputs.scanner.colorReference
        let filmingCorrection = colorReference.filmingExposureCorrection(
            film: params.film,
            print: params.print,
            scanFilm: params.io.scanFilm
        )
        let logEFilm = Filming.expose(
            raw: raw,
            exposureCompensationEV: params.camera.exposureCompensationEV,
            blackWhiteFilmingExposureCorrection: filmingCorrection
        )
        let logEFilmImage = RGBImage(width: rgbIn.width, height: rgbIn.height, data: logEFilm)

        // --- the printing and the scanning stages -----------------------
        let pipeline = try Slice1Pipeline(
            film: params.film, print: params.print, inputs: inputs
        )
        let taps = try pipeline.run(logEFilm: logEFilmImage)
        return FilmTaps(
            logEFilm: logEFilmImage,
            cmyFilm: taps.cmyFilm,
            logEPrint: taps.logEPrint,
            cmyPrint: taps.cmyPrint,
            rgbOut: taps.rgbOut
        )
    }
}
