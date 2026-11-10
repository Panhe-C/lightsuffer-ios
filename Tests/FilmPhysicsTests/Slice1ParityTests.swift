//
//  Slice1ParityTests.swift
//  light suffer胶片 — iOS app
//
//  The parity tests of the slice 1 port: the Swift pipeline is fed with the
//  log exposure of the negative captured from the upstream Python engine and
//  every downstream tap is compared with the reference.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class Slice1ParityTests: XCTestCase {

    /// The parameter cases of the reference fixtures.
    private static let cases = [
        "defaults",
        "camera_ev_plus1",
        "print_exposure_and_filter_shifts",
        "dir_couplers_inactive",
    ]

    // MARK: - Helpers

    /// Builds the pipeline inputs of a fixture case.
    private func makeInputs(common: JSONValue, fixture: JSONValue) throws -> Slice1Inputs {
        let spectral = try XCTUnwrap(common["spectral"])
        let illuminants = try XCTUnwrap(common["illuminants"])
        let colour = try XCTUnwrap(common["color"])
        let enlargerCommon = try XCTUnwrap(common["enlarger"])
        let derived = try XCTUnwrap(fixture["derived"])
        let enlargerDerived = try XCTUnwrap(derived["enlarger"])
        let neutral = try XCTUnwrap(derived["neutral_filters_cc"])
        let balance = try XCTUnwrap(derived["print_balance"])
        let params = try XCTUnwrap(fixture["params"])

        let spectralInputs = SpectralInputs(
            colourMatchingFunctions: try XCTUnwrap(spectral["cmfs_cie1931_2deg"]?.doubleRows),
            scanIlluminant: try XCTUnwrap(illuminants["scan_illuminant_spectrum"]?.doubles),
            scanIlluminantNormalization: try XCTUnwrap(illuminants["scan_normalization"]?.double),
            enlargerLightSource: try XCTUnwrap(enlargerDerived["light_source_spectrum"]?.doubles),
            dichroicFilters: try XCTUnwrap(
                enlargerCommon["dichroic_filter_transmittance_cmy"]?.doubleRows
            )
        )

        let enlargerParams = try XCTUnwrap(params["enlarger"])
        let enlargerInputs = EnlargerInputs(
            neutralFilterCC: [
                try XCTUnwrap(neutral["c"]?.double),
                try XCTUnwrap(neutral["m"]?.double),
                try XCTUnwrap(neutral["y"]?.double),
            ],
            filterShiftCC: [
                0,
                try XCTUnwrap(enlargerParams["m_filter_shift"]?.double),
                try XCTUnwrap(enlargerParams["y_filter_shift"]?.double),
            ],
            preflashFilterShiftCC: [
                0,
                try XCTUnwrap(enlargerParams["preflash_m_filter_shift"]?.double),
                try XCTUnwrap(enlargerParams["preflash_y_filter_shift"]?.double),
            ],
            printExposure: try XCTUnwrap(enlargerParams["print_exposure"]?.double),
            printExposureCompensation: try XCTUnwrap(
                enlargerParams["print_exposure_compensation"]?.bool
            ),
            normalizePrintExposure: try XCTUnwrap(
                enlargerParams["normalize_print_exposure"]?.bool
            ),
            preflashExposure: try XCTUnwrap(enlargerParams["preflash_exposure"]?.double),
            densitySpectralMidgray: try XCTUnwrap(balance["density_spectral_midgray"]?.doubles),
            densitySpectralMidgrayComp: balance["density_spectral_midgray_comp"]?.doubles
        )

        let scannerParams = try XCTUnwrap(params["scanner"])
        let ioParams = try XCTUnwrap(params["io"])
        let scannerInputs = ScannerInputs(
            xyzToRGB: try XCTUnwrap(colour["scanning_xyz_to_rgb"]?.doubleRows),
            srgbToSRGB: try XCTUnwrap(colour["srgb_to_srgb_matrix"]?.doubleRows),
            outputGamutCompress: try XCTUnwrap(
                ioParams["output_gamut_compress"]?["algorithm"]?.string
            ),
            colorReference: ColorReference(
                blackLevel: try XCTUnwrap(scannerParams["black_level"]?.double),
                whiteLevel: try XCTUnwrap(scannerParams["white_level"]?.double),
                blackCorrection: try XCTUnwrap(scannerParams["black_correction"]?.bool),
                whiteCorrection: try XCTUnwrap(scannerParams["white_correction"]?.bool)
            )
        )

        let filmParams = try XCTUnwrap(params["film_render"])
        let dirCouplersParams = try XCTUnwrap(filmParams["dir_couplers"])
        let grainParams = try XCTUnwrap(filmParams["grain"])
        var digest = Digest.filmRender(for: try ProfileLoader.load(stock: "kodak_portra_400"))
        digest.dirCouplers.active = try XCTUnwrap(dirCouplersParams["active"]?.bool)
        digest.dirCouplers.amount = try XCTUnwrap(dirCouplersParams["amount"]?.double)
        digest.dirCouplers.diffusionSizeUM = try XCTUnwrap(
            dirCouplersParams["diffusion_size_um"]?.double
        )
        digest.densityCurveGamma = try XCTUnwrap(filmParams["density_curve_gamma"]?.double)

        let filmRenderInputs = FilmRenderInputs(
            dirCouplers: digest.dirCouplers,
            densityCurveGamma: digest.densityCurveGamma,
            grain: try filmParams.grainParams(),
            pixelSizeUM: try XCTUnwrap(derived["pixel_size_um"]?.double)
        )

        return Slice1Inputs(
            spectral: spectralInputs,
            enlarger: enlargerInputs,
            scanner: scannerInputs,
            filmRender: filmRenderInputs
        )
    }

    /// Converts an encoded sRGB image into CIELAB, clipping the encoded
    /// values to the [0, 1] range first.
    private func labImage(_ rgb: [Double]) -> [LabColour] {
        stride(from: 0, to: rgb.count, by: 3).map { index in
            let clipped = (0..<3).map { channel -> Double in
                Swift.min(Swift.max(rgb[index + channel], 0), 1)
            }
            return Colour.sRGBToLab(clipped)
        }
    }

    // MARK: - Tests

    /// The Swift pipeline reproduces every downstream tap of the reference.
    func testPipelineMatchesTheReferenceTaps() throws {
        let common = try JSONValue.load(named: "slice1_common")
        let film = try ProfileLoader.load(stock: "kodak_portra_400")
        let printProfile = try ProfileLoader.load(stock: "kodak_portra_endura")

        for name in Self.cases {
            let fixture = try JSONValue.load(named: "slice1_\(name)")
            let taps = try XCTUnwrap(fixture["taps"])
            let inputs = try makeInputs(common: common, fixture: fixture)
            let pipeline = try Slice1Pipeline(film: film, print: printProfile, inputs: inputs)

            // Inject the log exposure of the negative captured upstream.
            let logEFilmValues = try XCTUnwrap(taps["log_e_film"]?.flatDoubles)
            let width = 12
            let height = 12
            let logEFilm = RGBImage(
                width: width, height: height, data: logEFilmValues
            )
            let result = try pipeline.run(logEFilm: logEFilm)

            // --- the density taps -------------------------------------
            let referenceCMYFilm = try XCTUnwrap(taps["cmy_film"]?.flatDoubles)
            let referenceLogEPrint = try XCTUnwrap(taps["log_e_print"]?.flatDoubles)
            let referenceCMYPrint = try XCTUnwrap(taps["cmy_print"]?.flatDoubles)
            let referenceRGBOut = try XCTUnwrap(taps["rgb_out"]?.flatDoubles)

            let cmyFilmError = maxAbsoluteDifference(result.cmyFilm.data, referenceCMYFilm)
            let logEPrintError = maxAbsoluteDifference(result.logEPrint.data, referenceLogEPrint)
            let cmyPrintError = maxAbsoluteDifference(result.cmyPrint.data, referenceCMYPrint)

            // --- the scanned image -------------------------------------
            let referenceLab = labImage(referenceRGBOut)
            let producedLab = labImage(result.rgbOut.data)
            var deltaESum = 0.0
            var deltaEMax = 0.0
            for index in 0..<referenceLab.count {
                let deltaE = Colour.deltaE2000(referenceLab[index], producedLab[index])
                deltaESum += deltaE
                deltaEMax = Swift.max(deltaEMax, deltaE)
            }
            let deltaEMean = deltaESum / Double(referenceLab.count)
            let rgbAbsoluteError = maxAbsoluteDifference(result.rgbOut.data, referenceRGBOut)

            print("""

                [slice1 parity] \(name)
                  cmy_film    : max abs error \(cmyFilmError)
                  log_e_print : max abs error \(logEPrintError)
                  cmy_print   : max abs error \(cmyPrintError)
                  rgb_out     : max abs error \(rgbAbsoluteError), \
                mean dE2000 \(deltaEMean), max dE2000 \(deltaEMax)

                """)

            XCTAssertLessThan(cmyFilmError, 5e-6, "\(name): cmy_film")
            XCTAssertLessThan(logEPrintError, 5e-6, "\(name): log_e_print")
            XCTAssertLessThan(cmyPrintError, 5e-6, "\(name): cmy_print")
            XCTAssertLessThan(deltaEMean, 0.5, "\(name): rgb_out mean dE2000")
            // The tightened gate: the reference fixtures are rounded to seven
            // significant digits, so the port stays far below the 0.5 gate.
            XCTAssertLessThan(deltaEMean, 0.01, "\(name): rgb_out mean dE2000")
            XCTAssertLessThan(deltaEMax, 0.05, "\(name): rgb_out max dE2000")
        }
    }

    /// The print balance reference of the fixture is reproduced.
    func testPrintBalanceReferenceIsReproduced() throws {
        let fixture = try JSONValue.load(named: "slice1_defaults")
        let derived = try XCTUnwrap(fixture["derived"])
        let reference = try XCTUnwrap(derived["print_black_white_reference"])

        // The black and the white patch of the negative.
        let film = try ProfileLoader.load(stock: "kodak_portra_400")
        let printProfile = try ProfileLoader.load(stock: "kodak_portra_endura")
        let common = try JSONValue.load(named: "slice1_common")
        let inputs = try makeInputs(common: common, fixture: fixture)

        // The pipeline exposes the black and the white reference internally;
        // recompute them here with the same helper the pipeline uses.
        let sensitivity = printProfile.data.logSensitivity.map { row in
            Numerics.nanToNum(row.map { pow(10.0, $0) })
        }
        let neutral = try XCTUnwrap(derived["neutral_filters_cc"])
        let filterCC = [
            try XCTUnwrap(neutral["c"]?.double),
            try XCTUnwrap(neutral["m"]?.double),
            try XCTUnwrap(neutral["y"]?.double),
        ]
        let enlargerDerived = try XCTUnwrap(derived["enlarger"])
        let illuminant = Enlarger.filteredIlluminant(
            lightSource: try XCTUnwrap(enlargerDerived["light_source_spectrum"]?.doubles),
            dichroicFilters: try XCTUnwrap(
                try XCTUnwrap(common["enlarger"])["dichroic_filter_transmittance_cmy"]?.doubleRows
            ),
            filterCC: filterCC
        )
        let balance = try XCTUnwrap(derived["print_balance"])
        let factor = Enlarger.exposureFactor(
            sensitivity: sensitivity,
            printIlluminant: illuminant,
            densitySpectralMidgray: try XCTUnwrap(balance["density_spectral_midgray"]?.doubles)
        )
        let factorComp = Enlarger.exposureFactor(
            sensitivity: sensitivity,
            printIlluminant: illuminant,
            densitySpectralMidgray: try XCTUnwrap(
                balance["density_spectral_midgray_comp"]?.doubles
            )
        )
        let exposureFactor = Enlarger.exposureFactorUsed(
            factorMidgray: factor,
            factorMidgrayComp: factorComp,
            printExposureCompensation: inputs.enlarger.printExposureCompensation,
            normalizePrintExposure: inputs.enlarger.normalizePrintExposure
        )

        let cmyBlack = inputs.filmRender.grain.densityMin.map { -$0 }
        let cmyWhite = (0..<3).map { channel in
            Numerics.nanMax(film.data.densityCurves.map { $0[channel] })
        }
        let logRawBlack = Printing.filmCMYToPrintLogRaw(
            cmyFilmDensity: cmyBlack,
            filmChannelDensity: film.data.channelDensity,
            filmBaseDensity: film.data.baseDensity,
            printSensitivity: sensitivity,
            printIlluminant: illuminant,
            exposureFactor: exposureFactor
        )
        let logRawWhite = Printing.filmCMYToPrintLogRaw(
            cmyFilmDensity: cmyWhite,
            filmChannelDensity: film.data.channelDensity,
            filmBaseDensity: film.data.baseDensity,
            printSensitivity: sensitivity,
            printIlluminant: illuminant,
            exposureFactor: exposureFactor
        )

        let blackError = maxAbsoluteDifference(
            logRawBlack, try XCTUnwrap(reference["log_raw_print_black"]?.doubles)
        )
        let whiteError = maxAbsoluteDifference(
            logRawWhite, try XCTUnwrap(reference["log_raw_print_white"]?.doubles)
        )
        print("[slice1 parity] print black / white reference: \(blackError) / \(whiteError)")
        XCTAssertLessThan(blackError, 1e-6)
        XCTAssertLessThan(whiteError, 1e-6)
    }

    /// The exposure factor of the fixture is reproduced.
    func testExposureFactorIsReproduced() throws {
        for name in Self.cases {
            let fixture = try JSONValue.load(named: "slice1_\(name)")
            let derived = try XCTUnwrap(fixture["derived"])
            let enlargerDerived = try XCTUnwrap(derived["enlarger"])
            let balance = try XCTUnwrap(derived["print_balance"])
            let printProfile = try ProfileLoader.load(stock: "kodak_portra_endura")
            let sensitivity = printProfile.data.logSensitivity.map { row in
                Numerics.nanToNum(row.map { pow(10.0, $0) })
            }
            let illuminant = try XCTUnwrap(enlargerDerived["filtered_illuminant_spectrum"]?.doubles)
            let factorMidgray = Enlarger.exposureFactor(
                sensitivity: sensitivity,
                printIlluminant: illuminant,
                densitySpectralMidgray: try XCTUnwrap(
                    balance["density_spectral_midgray"]?.doubles
                )
            )
            let factorMidgrayComp = Enlarger.exposureFactor(
                sensitivity: sensitivity,
                printIlluminant: illuminant,
                densitySpectralMidgray: try XCTUnwrap(
                    balance["density_spectral_midgray_comp"]?.doubles
                )
            )
            let params = try XCTUnwrap(fixture["params"])
            let enlargerParams = try XCTUnwrap(params["enlarger"])
            let factor = Enlarger.exposureFactorUsed(
                factorMidgray: factorMidgray,
                factorMidgrayComp: factorMidgrayComp,
                printExposureCompensation: try XCTUnwrap(
                    enlargerParams["print_exposure_compensation"]?.bool
                ),
                normalizePrintExposure: try XCTUnwrap(
                    enlargerParams["normalize_print_exposure"]?.bool
                )
            )
            let reference = try XCTUnwrap(enlargerDerived["exposure_factor_used"]?.doubles?[0])
            print("[slice1 parity] \(name): exposure factor \(factor) (reference \(reference))")
            XCTAssertEqual(factor, reference, accuracy: 1e-6)
        }
    }

    /// The black and white correction of the scanner runs.
    ///
    /// The reference fixtures disable it, so the port only has to stay
    /// consistent with the upstream formulation.
    func testBlackAndWhiteCorrectionRuns() throws {
        let common = try JSONValue.load(named: "slice1_common")
        let fixture = try JSONValue.load(named: "slice1_defaults")
        let film = try ProfileLoader.load(stock: "kodak_portra_400")
        let printProfile = try ProfileLoader.load(stock: "kodak_portra_endura")
        var inputs = try makeInputs(common: common, fixture: fixture)
        inputs.scanner.colorReference.blackCorrection = true
        inputs.scanner.colorReference.whiteCorrection = true
        let pipeline = try Slice1Pipeline(film: film, print: printProfile, inputs: inputs)

        let taps = try XCTUnwrap(fixture["taps"])
        let logEFilm = RGBImage(
            width: 12, height: 12, data: try XCTUnwrap(taps["log_e_film"]?.flatDoubles)
        )
        let result = try pipeline.run(logEFilm: logEFilm)

        // The corrected image stays finite and in the same ballpark.
        XCTAssertTrue(result.rgbOut.data.allSatisfy { $0.isFinite })
        let reference = try XCTUnwrap(taps["rgb_out"]?.flatDoubles)
        let difference = meanAbsoluteDifference(result.rgbOut.data, reference)
        print("[slice1 parity] black / white correction: mean abs difference \(difference)")
        XCTAssertLessThan(difference, 0.1)
    }
}
