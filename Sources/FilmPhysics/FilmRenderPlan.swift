//
//  FilmRenderPlan.swift
//  light suffer胶片 — iOS app
//
//  The precomputed data of a render: everything the GPU needs that does not
//  depend on the pixels of the image.
//
//  The plan is built **once** per (parameters, stock) pair and is then
//  evaluated per pixel; the Metal kernel and the pure Swift plan evaluator
//  implement the very same evaluation.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

// MARK: - The uniform curve

/// A characteristic curve sampled on a uniform log exposure grid.
///
/// The grid of the upstream profiles is **already uniform** (the log exposure
/// axis of every shipped profile is a `linspace` of 256 samples), so the
/// plan stores the samples of the profile as they are: the evaluation is
/// then exact (no resampling error) and it costs one division and one
/// multiply per lookup.
///
/// The values are stored in `Float32`: they are the payload of the GPU
/// buffers, so the plan evaluator and the Metal kernel see exactly the same
/// numbers.
public struct UniformCurve: Equatable, Sendable {

    /// The log exposure of the first sample.
    public var start: Float
    /// The step of the grid, in log exposure units.
    public var step: Float
    /// The number of samples per channel.
    public var count: Int
    /// The samples, `3 * count` values, channel major.
    public var values: [Float]

    public init(start: Float, step: Float, count: Int, values: [Float]) {
        self.start = start
        self.step = step
        self.count = count
        self.values = values
    }

    /// Builds a curve from the samples of a profile.
    ///
    /// - Parameters:
    ///   - samples: the values, `[sample][channel]`.
    ///   - logExposure: the log exposure axis of the samples.
    ///   - gamma: the gamma factor of the density curves (the axis of the
    ///     upstream kernel is `log_exposure / gamma`).
    public init(samples: [[Double]], logExposure: [Double], gamma: Double = 1.0) {
        let count = samples.count
        let channels = samples.first?.count ?? 3
        var values = [Float](repeating: 0, count: count * channels)
        for sample in 0..<count {
            for channel in 0..<channels where sample < samples.count {
                values[channel * count + sample] = Float(samples[sample][channel])
            }
        }
        let start = logExposure.first ?? 0
        let end = logExposure.last ?? start
        let step = count > 1 ? (end - start) / Double(count - 1) : 1
        self.init(
            start: Float(start / gamma),
            step: Float(step / gamma),
            count: count,
            values: values
        )
    }

    /// The value of a channel at a given log exposure.
    ///
    /// This is the exact evaluation of the upstream interpolation kernel
    /// (`fast_interp`): the values below the first sample are clamped to it,
    /// the values above the last sample are clamped to it, and the
    /// interpolation in between is linear.
    public func sample(_ x: Double, channel: Int) -> Double {
        guard count > 0 else { return 0 }
        let base = channel * count
        let first = Double(start)
        if x <= first { return Double(values[base]) }
        let last = first + Double(step) * Double(count - 1)
        if x >= last { return Double(values[base + count - 1]) }
        let position = (x - first) / Double(step)
        var index = Int(position.rounded(.down))
        if index < 0 { index = 0 }
        if index > count - 2 { index = count - 2 }
        let fraction = position - Double(index)
        let low = Double(values[base + index])
        let high = Double(values[base + index + 1])
        return low + fraction * (high - low)
    }

    /// The three channel values at a given log exposure.
    public func sample(_ x: Double) -> [Double] {
        (0..<3).map { sample(x, channel: $0) }
    }
}

// MARK: - The gamut compression

/// The precomputed data of the output gamut compression (the CAM16-UCS
/// chroma reduction of the upstream engine).
///
/// The maximum in-gamut chroma table is built by the CPU with the very same
/// builder as the upstream engine (``CAM16UCSCMaxTable``), so the GPU and
/// the CPU share the table bit for bit.
public struct PlanGamutCompression: Equatable, Sendable {

    /// The chroma Reinhard knee.
    public var knee: ReinhardKnee
    /// The one-sided lightness Reinhard knee (`nil` disables it).
    public var lightnessKnee: ReinhardKnee?
    /// The maximum in-gamut chroma table, `[lightness][hue]`.
    public var cMax: [Float]
    /// The number of lightness samples of the table.
    public var cMaxLightnessCount: Int
    /// The number of hue samples of the table.
    public var cMaxHueCount: Int
    /// The first lightness of the table.
    public var cMaxLightnessStart: Float
    /// The step of the lightness axis of the table.
    public var cMaxLightnessStep: Float
    /// The first hue of the table (in radians).
    public var cMaxHueStart: Float
    /// The step of the hue axis of the table (in radians).
    public var cMaxHueStep: Float
    /// The CAM16-UCS lightness of the whitepoint of the output colourspace.
    public var whiteJp: Float
    /// The tristimulus values of the whitepoint of the output colourspace.
    public var whiteXYZ: [Float]
    /// The adapting field luminance, in cd/m².
    public var la: Float
    /// The luminance factor of the background.
    public var yb: Float

    public init(
        knee: ReinhardKnee,
        lightnessKnee: ReinhardKnee?,
        cMax: [Float],
        cMaxLightnessCount: Int,
        cMaxHueCount: Int,
        cMaxLightnessStart: Float,
        cMaxLightnessStep: Float,
        cMaxHueStart: Float,
        cMaxHueStep: Float,
        whiteJp: Float,
        whiteXYZ: [Float],
        la: Float,
        yb: Float
    ) {
        self.knee = knee
        self.lightnessKnee = lightnessKnee
        self.cMax = cMax
        self.cMaxLightnessCount = cMaxLightnessCount
        self.cMaxHueCount = cMaxHueCount
        self.cMaxLightnessStart = cMaxLightnessStart
        self.cMaxLightnessStep = cMaxLightnessStep
        self.cMaxHueStart = cMaxHueStart
        self.cMaxHueStep = cMaxHueStep
        self.whiteJp = whiteJp
        self.whiteXYZ = whiteXYZ
        self.la = la
        self.yb = yb
    }
}

// MARK: - The plan

/// The precomputed data of a render.
///
/// The plan holds everything the GPU needs that does **not** depend on the
/// pixels of the image:
///
/// * the hanatos 2025 lookup table of the film (the spectral upsampling),
/// * the colour matrices of the input and of the output,
/// * the characteristic curves of the film and of the paper (on their
///   uniform log exposure grid),
/// * the DIR coupler chemistry,
/// * the spectral tables of the printing and of the scanning stages
///   (the channel densities, the sensitivities, the illuminants, the colour
///   matching functions),
/// * the exposure factor of the enlarger and the preflash,
/// * the black / white reference of the print,
/// * the table of the output gamut compression.
///
/// The values are stored in `Float32`: the plan is the payload of the GPU
/// buffers, so the pure Swift plan evaluator (``FilmPlanEvaluator``) and the
/// Metal kernel evaluate exactly the same numbers.
public struct FilmRenderPlan: Sendable {

    // MARK: The spectral upsampling

    /// The size of the (square) hanatos 2025 lookup table.
    public var tcLUTSize: Int
    /// The hanatos 2025 lookup table, `size * size * 3` values, indexed by
    /// `(i * size + j) * 3 + channel`.
    public var tcLUT: [Float]
    /// The RGB to XYZ matrix of the filming stage, nine values, row major.
    ///
    /// The matrix is the chromatic adaptation (CAT16) of the input
    /// colourspace to the reference illuminant of the film, composed with
    /// the RGB to XYZ matrix of the colourspace.
    public var inputRGBToXYZ: [Float]
    /// The decoding of the input: 0 (none), 1 (sRGB), 2 (ProPhoto RGB).
    public var inputCCTF: Int

    // MARK: The exposure of the negative

    /// The exposure compensation of the camera, as a linear factor.
    public var exposureScale: Float
    /// The black / white correction of the exposure of the camera.
    public var filmingScale: Float
    /// Whether the highlight boost is active.
    public var boostActive: Bool
    /// The strength of the highlight boost, in stops.
    public var boostEV: Float
    /// The range of the highlight boost.
    public var boostRange: Float
    /// The protection of the mid grey of the highlight boost, in stops.
    public var protectEV: Float

    // MARK: The development of the negative

    /// The normalised characteristic curves of the film.
    public var filmCurve: UniformCurve
    /// The characteristic curves of the film, before the DIR couplers.
    public var filmCurveBeforeCouplers: UniformCurve
    /// Whether the DIR couplers are active.
    public var couplersActive: Bool
    /// The inhibitor matrix of the DIR couplers, nine values, row major.
    ///
    /// The row index is the donor layer, the column index the receiving
    /// layer.
    public var couplerMatrix: [Float]
    /// Whether the emulsion is a positive (slide) stock.
    public var couplerPositive: Bool
    /// The maximum density of every channel of the film.
    public var densityMax: [Float]

    // MARK: The printing

    /// The spectral density of the image forming layer of the negative,
    /// `wavelength * 3 + channel`.
    public var filmChannelDensity: [Float]
    /// The base density of the negative, one value per wavelength.
    public var filmBaseDensity: [Float]
    /// The spectral sensitivity of the paper, `wavelength * 3 + channel`.
    public var printSensitivity: [Float]
    /// The filtered illuminant of the enlarger, one value per wavelength.
    public var printIlluminant: [Float]
    /// The mid grey exposure normalisation factor of the enlarger.
    public var exposureFactor: Float
    /// The preflash contribution of the enlarger, three values.
    public var preflash: [Float]
    /// The exposure of the enlarger.
    public var printExposure: Float
    /// The black / white correction of the exposure of the paper.
    public var printingExposureCorrection: Float
    /// The characteristic curves of the paper (the fitted model).
    public var printCurve: UniformCurve

    // MARK: The scanning

    /// The spectral density of the image forming layer of the paper,
    /// `wavelength * 3 + channel`.
    public var printChannelDensity: [Float]
    /// The base density of the paper, one value per wavelength.
    public var printBaseDensity: [Float]
    /// The illuminant of the scanner, one value per wavelength.
    public var scanIlluminant: [Float]
    /// The CIE 1931 2° colour matching functions, `wavelength * 3 + component`.
    public var colourMatchingFunctions: [Float]
    /// The normalisation of the illuminant of the scanner.
    public var scanNormalization: Float
    /// The XYZ to output RGB matrix, nine values, row major.
    ///
    /// **Row `i` holds the RGB response to the `i`-th XYZ basis vector**, i.e.
    /// the conversion is the row vector product `rgb = xyz · matrix`.
    public var xyzToRGB: [Float]
    /// The matrix of the output transfer function, nine values, row major.
    ///
    /// The conversion is the column vector product `rgb = matrix · rgb`.
    public var srgbToSRGB: [Float]
    /// The linear sRGB to XYZ matrix of the gamut compression, nine values,
    /// row major.
    ///
    /// It is the CAT02 adaptation of the whitepoint of the sRGB colourspace
    /// onto itself, composed with the RGB to XYZ matrix of the colourspace.
    public var gamutRGBToXYZ: [Float]
    /// The XYZ to linear sRGB matrix of the gamut compression, nine values,
    /// row major.
    public var gamutXYZToRGB: [Float]
    /// Whether the output is encoded with the sRGB transfer function.
    public var outputEncoded: Bool
    /// The slope of the black / white correction of the scanned tristimulus
    /// values (1.0 when the correction is inactive).
    public var colorReferenceSlope: Float
    /// The offset of the black / white correction of the scanned tristimulus
    /// values (0.0 when the correction is inactive).
    public var colorReferenceOffset: Float

    // MARK: The output gamut compression

    /// The output gamut compression (`nil` when it is inactive).
    public var gamutCompression: PlanGamutCompression?

    // MARK: The metadata

    /// The digested parameters of the render.
    public var params: PipelineParams

    // MARK: - The builder

    /// Builds the plan of a render.
    ///
    /// - Parameter params: the parameters of the simulation (they are
    ///   digested by the pipeline, exactly like the CPU reference does).
    /// - Returns: the plan of the render.
    public static func build(params: PipelineParams) throws -> FilmRenderPlan {
        let pipeline = try FilmPipeline(params: params)
        return try FilmRenderPlan(pipeline: pipeline)
    }

    /// Builds the plan of a render from an initialised pipeline.
    ///
    /// - Parameter pipeline: the pipeline, whose digested parameters and
    ///   precomputed inputs the plan reuses.
    public init(pipeline: FilmPipeline) throws {
        let params = pipeline.params
        let inputs = pipeline.inputs
        let film = params.film
        let printProfile = params.print

        // --- the spectral upsampling -----------------------------------
        self.tcLUTSize = pipeline.tcLUT.size
        self.tcLUT = pipeline.tcLUT.values.map { Float($0) }

        guard let inputColourSpace = RGBColourspace.named(params.io.inputColorSpace) else {
            throw PipelineError.invalidInputs(
                "the input colour space '\(params.io.inputColorSpace)' is not supported"
            )
        }
        let illuminants = try Resources.illuminants()
        let colourMatchingFunctions = try Resources.colourMatchingFunctions()
        let referenceIlluminantXY = Illuminants.chromaticity(
            of: film.info.referenceIlluminant,
            illuminants: illuminants,
            colourMatchingFunctions: colourMatchingFunctions
        )
        // The same composition as `ColourScience.rgbToXYZ`: the chromatic
        // adaptation is applied *after* the RGB to XYZ matrix.
        let adaptation = ChromaticAdaptationTransform.cat16.matrix(
            from: inputColourSpace.whitepointXYZ,
            to: ColourScience.xyToXYZ(referenceIlluminantXY)
        )
        let rgbToXYZ = Matrix.multiply(adaptation, inputColourSpace.matrixRGBToXYZ)
        self.inputRGBToXYZ = rgbToXYZ.flatMap { $0.map { Float($0) } }
        switch (params.io.inputCCTFDecoding, inputColourSpace.name) {
        case (false, _):
            self.inputCCTF = 0
        case (true, "sRGB"):
            self.inputCCTF = 1
        case (true, "ProPhoto RGB"):
            self.inputCCTF = 2
        default:
            self.inputCCTF = 0
        }

        // --- the exposure of the negative -------------------------------
        self.exposureScale = Float(pow(2.0, params.camera.exposureCompensationEV))
        let halation = params.filmRender.halation
        self.boostActive = halation.boostEV != 0
        self.boostEV = Float(halation.boostEV)
        self.boostRange = Float(halation.boostRange)
        self.protectEV = Float(halation.protectEV)

        // The black / white reference of the scan. The pipeline computes it
        // in the printing stage; the plan computes it once, here.
        var colorReference = inputs.scanner.colorReference
        if params.io.scanFilm {
            colorReference.updateFilmReferences(film: film) { cmy in
                Scanning.cmyToLogXYZ(
                    cmy: cmy,
                    channelDensity: film.data.channelDensity,
                    baseDensity: film.data.baseDensity,
                    scanIlluminant: inputs.spectral.scanIlluminant,
                    colourMatchingFunctions: inputs.spectral.colourMatchingFunctions,
                    normalization: inputs.spectral.scanIlluminantNormalization
                )
            }
        }
        self.filmingScale = Float(
            colorReference.filmingExposureCorrection(
                film: film, print: printProfile, scanFilm: params.io.scanFilm
            )
        )

        // --- the development of the negative ----------------------------
        let normalised = DensityCurves.normalized(film.data.densityCurves)
        let gamma = params.filmRender.densityCurveGamma
        self.filmCurve = UniformCurve(
            samples: normalised, logExposure: film.data.logExposure, gamma: gamma
        )

        let couplers = params.filmRender.dirCouplers
        let positive = film.info.type == .positive
        self.couplersActive = couplers.active
        self.couplerPositive = positive
        var matrix = Couplers.matrix(couplers)
        for row in 0..<3 {
            for column in 0..<3 {
                matrix[row][column] *= couplers.amount
            }
        }
        self.couplerMatrix = matrix.flatMap { $0.map { Float($0) } }
        self.densityMax = (0..<3).map { channel in
            Float(Numerics.nanMax(normalised.map { $0[channel] }))
        }
        if couplers.active {
            let curvesBeforeCouplers = Couplers.densityCurvesBeforeCouplers(
                densityCurves: normalised,
                logExposure: film.data.logExposure,
                matrix: matrix,
                positive: positive
            )
            self.filmCurveBeforeCouplers = UniformCurve(
                samples: curvesBeforeCouplers,
                logExposure: film.data.logExposure,
                gamma: gamma
            )
        } else {
            self.filmCurveBeforeCouplers = UniformCurve(
                samples: normalised, logExposure: film.data.logExposure, gamma: gamma
            )
        }

        // --- the printing -----------------------------------------------
        let printSensitivity = printProfile.data.logSensitivity.map { row in
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

        self.filmChannelDensity = film.data.channelDensity.flatMap { $0.map { Float($0) } }
        self.filmBaseDensity = film.data.baseDensity.map { Float($0) }
        self.printSensitivity = sensitivity.flatMap { $0.map { Float($0) } }
        self.printIlluminant = printIlluminant.map { Float($0) }
        self.exposureFactor = Float(exposureFactor)
        self.preflash = preflash.map { Float($0) }
        self.printExposure = Float(params.enlarger.printExposure)

        // The black / white reference of the print (the same computation as
        // the one of the printing stage).
        let cmyFilmBlack = inputs.filmRender.grain.densityMin.map { -$0 }
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
        colorReference.updateReferences(printProfile: printProfile) { cmy in
            Scanning.cmyToLogXYZ(
                cmy: cmy,
                channelDensity: printProfile.data.channelDensity,
                baseDensity: printProfile.data.baseDensity,
                scanIlluminant: inputs.spectral.scanIlluminant,
                colourMatchingFunctions: inputs.spectral.colourMatchingFunctions,
                normalization: inputs.spectral.scanIlluminantNormalization
            )
        }
        self.printingExposureCorrection = Float(
            colorReference.printingExposureCorrection(printProfile: printProfile)
        )
        if let correction = colorReference.correctionFunction() {
            self.colorReferenceSlope = Float(correction.slope)
            self.colorReferenceOffset = Float(correction.offset)
        } else {
            self.colorReferenceSlope = 1
            self.colorReferenceOffset = 0
        }

        let printCurves = DensityCurves.evaluateFittedDensity(
            logExposure: printProfile.data.logExposure,
            model: printProfile.data.densityCurvesModel,
            profileType: printProfile.info.type
        )
        self.printCurve = UniformCurve(
            samples: printCurves, logExposure: printProfile.data.logExposure, gamma: 1.0
        )

        // --- the scanning -----------------------------------------------
        self.printChannelDensity = printProfile.data.channelDensity.flatMap {
            $0.map { Float($0) }
        }
        self.printBaseDensity = printProfile.data.baseDensity.map { Float($0) }
        self.scanIlluminant = inputs.spectral.scanIlluminant.map { Float($0) }
        self.colourMatchingFunctions = inputs.spectral.colourMatchingFunctions.flatMap {
            $0.map { Float($0) }
        }
        self.scanNormalization = Float(inputs.spectral.scanIlluminantNormalization)
        self.xyzToRGB = inputs.scanner.xyzToRGB.flatMap { $0.map { Float($0) } }
        self.srgbToSRGB = inputs.scanner.srgbToSRGB.flatMap { $0.map { Float($0) } }
        // The matrices of the gamut compression: the CAT02 adaptation of the
        // whitepoint of the sRGB colourspace onto itself (the identity) and
        // the matrices of the colourspace.
        let srgbWhite = ColourScience.xyToXYZ(RGBColourspace.sRGB.whitepoint)
        let srgbAdaptation = ChromaticAdaptationTransform.cat02.matrix(
            from: srgbWhite, to: srgbWhite
        )
        self.gamutRGBToXYZ = Matrix.multiply(
            srgbAdaptation, RGBColourspace.sRGB.matrixRGBToXYZ
        ).flatMap { $0.map { Float($0) } }
        self.gamutXYZToRGB = Matrix.multiply(
            RGBColourspace.sRGB.matrixXYZToRGB, srgbAdaptation
        ).flatMap { $0.map { Float($0) } }
        // The CPU reference always encodes the output with the sRGB transfer
        // function: the upstream scanning stage ignores the
        // `io.output_cctf_encoding` flag, and the port reproduces it.
        self.outputEncoded = true

        // --- the output gamut compression --------------------------------
        if let spec = inputs.scanner.resolvedOutputGamutCompress, spec.active {
            let table = CAM16UCSCMaxTable.shared(for: .sRGB)
            let lightnessStep = (110.0 - 1.0) / Double(CAM16UCSCMaxTable.lightnessCount - 1)
            let hueStep = 2.0 * Double.pi / Double(CAM16UCSCMaxTable.hueCount)
            self.gamutCompression = PlanGamutCompression(
                knee: spec.knee,
                lightnessKnee: spec.lightnessCompression,
                cMax: table.values.map { Float($0) },
                cMaxLightnessCount: CAM16UCSCMaxTable.lightnessCount,
                cMaxHueCount: CAM16UCSCMaxTable.hueCount,
                cMaxLightnessStart: Float(1.0),
                cMaxLightnessStep: Float(lightnessStep),
                cMaxHueStart: Float(-Double.pi),
                cMaxHueStep: Float(hueStep),
                whiteJp: Float(table.whiteJp),
                whiteXYZ: ColourScience.xyToXYZ(RGBColourspace.sRGB.whitepoint).map {
                    Float($0)
                },
                la: Float(GamutCompression.cam16UCSViewingConditions.LA),
                yb: Float(GamutCompression.cam16UCSViewingConditions.Yb)
            )
        } else {
            self.gamutCompression = nil
        }

        self.params = params
    }
}
