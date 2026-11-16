import XCTest
@testable import FilmPhysics

final class PrintCurvesMorphTests: XCTestCase {
    func testAllPrintMediaAndControlsMatchUpstreamCurves() throws {
        let fixture = try JSONValue.load(named: "chemistry")
        let media = try XCTUnwrap(fixture["curves"]?.arrayElements)
        XCTAssertEqual(media.count, 8)
        var maximum = 0.0
        for medium in media {
            let stock = try XCTUnwrap(medium["stock"]?.string)
            let profile = try ProfileLoader.load(stock: stock)
            let cases = try XCTUnwrap(medium["cases"]?.arrayElements)
            XCTAssertEqual(cases.count, 12)
            for entry in cases {
                let name = try XCTUnwrap(entry["name"]?.string)
                let params = try XCTUnwrap(entry["params"]).printCurvesMorphParams()
                let expected = try XCTUnwrap(entry["density"]?.flatDoubles)
                let curves = try PrintCurvesMorph.evaluate(
                    logExposure: profile.data.logExposure,
                    model: profile.data.densityCurvesModel,
                    params: params, profileType: profile.info.type
                )
                let error = maxAbsoluteDifference(curves.flatMap { $0 }, expected)
                maximum = max(maximum, error)
                XCTAssertLessThan(error, 5e-7, "\(stock) / \(name)")
                if name == "defaults" || name == "off" {
                    XCTAssertEqual(curves, DensityCurves.evaluateFittedDensity(
                        logExposure: profile.data.logExposure,
                        model: profile.data.densityCurvesModel, profileType: profile.info.type
                    ), "defaults must preserve the previous curve exactly")
                }
            }
        }
        print("CHEMISTRY-CURVES 8 media x 12 cases: max absolute error \(maximum)")
    }

    func testPipelineAndBothPlanEvaluatorsMatchUpstream() throws {
        let fixture = try JSONValue.load(named: "chemistry")
        let imageRecord = try XCTUnwrap(fixture["image"])
        let input = RGBImage(
            width: try XCTUnwrap(imageRecord["width"]?.int),
            height: try XCTUnwrap(imageRecord["height"]?.int),
            data: try XCTUnwrap(imageRecord.flatDoubles)
        )
        let entries = try XCTUnwrap(fixture["pipelines"]?.arrayElements)
        XCTAssertEqual(entries.count, 10)
        for entry in entries {
            let name = try XCTUnwrap(entry["name"]?.string)
            let film = try ProfileLoader.load(stock: try XCTUnwrap(entry["film_profile"]?.string))
            let paper = try ProfileLoader.load(stock: try XCTUnwrap(entry["print_profile"]?.string))
            let params = try makePipelineParams(fixture: entry, film: film, print: paper)
            let pipeline = try FilmPipeline(params: params)
            let result = try pipeline.process(rgbIn: input)
            let plan = try FilmRenderPlan(pipeline: pipeline)
            let replay = try FilmPlanEvaluator.evaluate(plan: plan, rgbIn: input)
            let float32 = try FilmPlanEvaluatorFloat32.evaluate(plan: plan, rgbIn: input)
            let taps = try XCTUnwrap(entry["taps"])
            let pairs: [(String, [Double])] = [
                ("log_e_film", result.logEFilm.data), ("cmy_film", result.cmyFilm.data),
                ("log_e_print", result.logEPrint.data), ("cmy_print", result.cmyPrint.data),
            ]
            for (tap, data) in pairs {
                guard let expected = taps[tap]?.flatDoubles else { continue }
                XCTAssertLessThan(maxAbsoluteDifference(data, expected), 1e-5, "\(name): \(tap)")
            }
            let expected = try XCTUnwrap(taps["rgb_out"]?.flatDoubles)
            let pythonError = deltaE(result.rgbOut.data, expected)
            XCTAssertLessThan(pythonError.mean, 0.01, name)
            XCTAssertLessThan(pythonError.max, 0.05, name)
            for produced in [replay, float32] {
                let error = deltaE(result.rgbOut.data, produced.rgbOut.data)
                XCTAssertLessThan(error.mean, 0.01, name)
                XCTAssertLessThan(error.max, 0.05, name)
                if !params.io.scanFilm {
                    XCTAssertLessThan(
                        maxAbsoluteDifference(result.cmyPrint.data, produced.cmyPrint.data),
                        1e-5, name
                    )
                }
            }
            var control = params
            control.printRender.densityCurvesMorph.active = false
            let controlPipeline = try FilmPipeline(params: control)
            let controlPlan = try FilmRenderPlan(pipeline: controlPipeline)
            XCTAssertEqual(plan.printingExposureCorrection, controlPlan.printingExposureCorrection)
            XCTAssertEqual(plan.colorReferenceSlope, controlPlan.colorReferenceSlope)
            XCTAssertEqual(plan.colorReferenceOffset, controlPlan.colorReferenceOffset)
            let controlResult = try controlPipeline.process(rgbIn: input)
            XCTAssertEqual(result.logEFilm, controlResult.logEFilm)
            XCTAssertEqual(result.cmyFilm, controlResult.cmyFilm)
            XCTAssertEqual(result.logEPrint, controlResult.logEPrint)
            if params.io.scanFilm {
                XCTAssertEqual(result.rgbOut, controlResult.rgbOut)
            } else if params.printRender.densityCurvesMorph.active {
                XCTAssertGreaterThan(
                    maxAbsoluteDifference(result.rgbOut.data, controlResult.rgbOut.data), 0.01
                )
            }
            print("CHEMISTRY-PIPELINE \(name): Python mean \(pythonError.mean), max \(pythonError.max)")
        }
    }

    func testExhaustionPreservesZeroExposureAndDensityLimitsForBothPolarities() throws {
        let paper = try ProfileLoader.load(stock: "kodak_portra_endura")
        var baseline = PrintCurvesMorphParams(
            gammaFactor: 1.25, gammaFactorFast: 0.7, gammaFactorSlow: 1.6,
            gammaFactorRed: 1.1, gammaFactorGreen: 0.9, gammaFactorBlue: 1.4
        )
        for polarity in [ProfileType.negative, .positive] {
            baseline.developerExhaustion = 0
            let control = try PrintCurvesMorph.evaluate(
                logExposure: [-100, 0, 100], model: paper.data.densityCurvesModel,
                params: baseline, profileType: polarity
            )
            for mix in [1e-9, 0.25, 0.5, 1.0] {
                baseline.developerExhaustion = mix
                let morphed = try PrintCurvesMorph.evaluate(
                    logExposure: [-100, 0, 100], model: paper.data.densityCurvesModel,
                    params: baseline, profileType: polarity
                )
                for channel in 0..<3 {
                    XCTAssertEqual(morphed[1][channel], control[1][channel], accuracy: 2e-9)
                    XCTAssertEqual(morphed[0][channel], control[0][channel], accuracy: 1e-12)
                    XCTAssertEqual(morphed[2][channel], control[2][channel], accuracy: 1e-12)
                }
            }
        }
    }

    func testMalformedModelsAndInvalidParametersFailRatherThanProducingNaN() throws {
        let paper = try ProfileLoader.load(stock: "kodak_portra_endura")
        for value in [0, -1, Double.nan, .infinity] {
            var params = PrintCurvesMorphParams()
            params.gammaFactor = value
            XCTAssertThrowsError(try PrintCurvesMorph.evaluate(
                logExposure: [0], model: paper.data.densityCurvesModel,
                params: params, profileType: .positive
            ))
        }
        for value in [-0.1, 1.1, Double.nan, .infinity] {
            var params = PrintCurvesMorphParams()
            params.developerExhaustion = value
            XCTAssertThrowsError(try PrintCurvesMorph.evaluate(
                logExposure: [0], model: paper.data.densityCurvesModel,
                params: params, profileType: .positive
            ))
        }
        var invalidModel = paper.data.densityCurvesModel
        invalidModel.sigmas[1] = []
        XCTAssertThrowsError(try PrintCurvesMorph.evaluate(
            logExposure: [0], model: invalidModel,
            params: PrintCurvesMorphParams(), profileType: .positive
        ))
        XCTAssertThrowsError(try PrintCurvesMorph.evaluate(
            logExposure: [0], model: DensityCurvesModel(),
            params: PrintCurvesMorphParams(), profileType: .positive
        ))
    }

    private func deltaE(_ lhs: [Double], _ rhs: [Double]) -> (mean: Double, max: Double) {
        let errors = stride(from: 0, to: lhs.count, by: 3).map { index in
            let left = (0..<3).map { min(max(lhs[index + $0], 0), 1) }
            let right = (0..<3).map { min(max(rhs[index + $0], 0), 1) }
            return Colour.deltaE2000(Colour.sRGBToLab(left), Colour.sRGBToLab(right))
        }
        return (errors.reduce(0, +) / Double(errors.count), errors.max() ?? 0)
    }
}
