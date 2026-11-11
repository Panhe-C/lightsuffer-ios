//
//  FilmPlanEvaluatorTests.swift
//  light suffer胶片 — iOS app
//
//  The validation of the render plan and of the plan evaluator: the pure
//  Swift evaluation of the precomputed data of a render must reproduce the
//  CPU pipeline tap by tap.
//
//  The test measures two evaluations:
//
//  * the **plan evaluator** (``FilmPlanEvaluator``), which evaluates the
//    plan in `Double` — it measures the error the *plan* makes (the plan
//    stores its data in `Float32`, the payload of the GPU buffers),
//  * the **`Float32` plan evaluator** (``FilmPlanEvaluatorFloat32``), which
//    evaluates the plan the way the GPU does — it measures the error the
//    *Metal kernels* make, and it is the reference the tolerances of the GPU
//    path are derived from.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class FilmPlanEvaluatorTests: XCTestCase {

    // MARK: - The tolerances

    /// The tolerance of the intermediate taps, in absolute terms.
    ///
    /// The chain of the plan is *well conditioned*: every stage is a smooth
    /// function with a bounded derivative, and the values are of the order
    /// of one.  The plan stores its data in `Float32`, so the input of the
    /// chain carries a relative error of `2^-24` ≈ 6e-8; the measured
    /// amplification of the chain (the ratio of the error of a tap to the
    /// `Float32` epsilon of its input) is **3.5** (the measured error of the
    /// worst tap is 2.1e-7, i.e. 3.5 · 6e-8).
    ///
    /// The measured amplification of the chain is larger than that: the
    /// **cubic** lookup of the hanatos 2025 table is sensitive to the
    /// position (its derivative is of the order of 1.5 per cell of the
    /// 192 × 192 table), so a relative error of 6e-8 on the chromaticity is
    /// amplified by about thirty.  The measured maximum of the error of a
    /// tap is **5.3e-6** (the `cmy_print` tap of the slice 2).
    ///
    /// The tolerance is therefore **1e-5**: the measured maximum times a
    /// headroom of **1.9** — the headroom covers the cases that are not in
    /// the fixtures (a curve whose slope is steeper than the ones of the
    /// shipped profiles).  It is a *tight* tolerance: the plan is not
    /// allowed to be sloppy.
    private let tapTolerance = 1e-5

    /// The tolerance of the output, in CIEDE2000.
    ///
    /// The output is the encoded sRGB value: the `Float32` rounding of the
    /// plan (6e-8 relative) is amplified by the **CAM16 round trip** of the
    /// output gamut compression (the forward and the inverse model divide
    /// by quantities of the order of `0.1`): the measured amplification is
    /// of the order of a thousand, i.e. a relative error of 6e-5 on the
    /// encoded value, which is worth about 6e-4 of ΔE₀₀ in the mid tones
    /// and about 1e-2 in the dark ones (where the sRGB transfer function
    /// has a slope of `12.92`).
    ///
    /// The measured maxima (over the four cases of the slice 2, the 148
    /// looks of the catalogue and the ten cases of the slice 5) are
    /// **0.0046** for the mean and **0.0107** for the maximum; the
    /// tolerances are **0.008** (1.7 times the measured maximum) and
    /// **0.021** (twice the measured maximum).
    private let meanDeltaETolerance = 0.008
    private let maxDeltaETolerance = 0.021

    // MARK: - The helpers

    /// The CIELAB image of an encoded sRGB image, clipped to [0, 1].
    private func labImage(_ rgb: [Double]) -> [LabColour] {
        stride(from: 0, to: rgb.count, by: 3).map { index in
            let clipped = (0..<3).map { channel -> Double in
                Swift.min(Swift.max(rgb[index + channel], 0), 1)
            }
            return Colour.sRGBToLab(clipped)
        }
    }

    /// The mean and the maximum CIEDE2000 between two encoded sRGB images.
    private func deltaE(_ reference: [Double], _ produced: [Double]) -> (mean: Double, max: Double) {
        let referenceLab = labImage(reference)
        let producedLab = labImage(produced)
        var sum = 0.0
        var maximum = 0.0
        for index in 0..<referenceLab.count {
            let delta = Colour.deltaE2000(referenceLab[index], producedLab[index])
            sum += delta
            maximum = Swift.max(maximum, delta)
        }
        return (sum / Double(referenceLab.count), maximum)
    }

    /// The measurements of one case.
    private struct Row {
        let id: String
        /// The maximum absolute error of the intermediate taps (the `Float32`
        /// evaluator).
        let taps: Double
        /// The maximum absolute error of the intermediate taps (the plan
        /// evaluator, in `Double`).
        let planTaps: Double
        /// The mean CIEDE2000 of the output (the `Float32` evaluator).
        let meanDeltaE: Double
        /// The maximum CIEDE2000 of the output (the `Float32` evaluator).
        let maxDeltaE: Double
        /// The mean CIEDE2000 of the output (the plan evaluator).
        let planMeanDeltaE: Double
        /// The maximum absolute error of the output (the `Float32`
        /// evaluator).
        let rgbOut: Double
    }

    /// The measurements of a family of cases.
    private struct Summary {
        var taps = 0.0
        var planTaps = 0.0
        var meanDeltaE = 0.0
        var maxDeltaE = 0.0
        var planMeanDeltaE = 0.0
        var rgbOut = 0.0

        mutating func add(_ row: Row) {
            taps = Swift.max(taps, row.taps)
            planTaps = Swift.max(planTaps, row.planTaps)
            meanDeltaE = Swift.max(meanDeltaE, row.meanDeltaE)
            maxDeltaE = Swift.max(maxDeltaE, row.maxDeltaE)
            planMeanDeltaE = Swift.max(planMeanDeltaE, row.planMeanDeltaE)
            rgbOut = Swift.max(rgbOut, row.rgbOut)
        }
    }

    /// Compares the taps of the plan evaluator with the ones of the CPU.
    ///
    /// - Parameters:
    ///   - id: the identifier of the case.
    ///   - cpu: the taps of the CPU pipeline.
    ///   - planTaps: the taps of the plan evaluator.
    ///   - float32Taps: the taps of the `Float32` plan evaluator.
    ///   - taps: the taps to compare (the ones the case holds).
    /// - Returns: the measurements of the case.
    private func compare(
        id: String,
        cpu: FilmTaps,
        planTaps: FilmPlanTaps,
        float32Taps: FilmPlanTaps,
        taps: [String]
    ) -> Row {
        var worstTap = 0.0
        var worstPlanTap = 0.0
        if taps.contains("log_e_film") {
            let error = maxAbsoluteDifference(cpu.logEFilm.data, float32Taps.logEFilm.data)
            let planError = maxAbsoluteDifference(cpu.logEFilm.data, planTaps.logEFilm.data)
            worstTap = Swift.max(worstTap, error)
            worstPlanTap = Swift.max(worstPlanTap, planError)
            XCTAssertLessThan(error, tapTolerance, "\(id): log_e_film (the float32 plan)")
            XCTAssertLessThan(planError, tapTolerance, "\(id): log_e_film (the plan)")
        }
        if taps.contains("cmy_film") {
            let error = maxAbsoluteDifference(cpu.cmyFilm.data, float32Taps.cmyFilm.data)
            let planError = maxAbsoluteDifference(cpu.cmyFilm.data, planTaps.cmyFilm.data)
            worstTap = Swift.max(worstTap, error)
            worstPlanTap = Swift.max(worstPlanTap, planError)
            XCTAssertLessThan(error, tapTolerance, "\(id): cmy_film (the float32 plan)")
            XCTAssertLessThan(planError, tapTolerance, "\(id): cmy_film (the plan)")
        }
        if taps.contains("log_e_print") {
            let error = maxAbsoluteDifference(cpu.logEPrint.data, float32Taps.logEPrint.data)
            let planError = maxAbsoluteDifference(cpu.logEPrint.data, planTaps.logEPrint.data)
            worstTap = Swift.max(worstTap, error)
            worstPlanTap = Swift.max(worstPlanTap, planError)
            XCTAssertLessThan(error, tapTolerance, "\(id): log_e_print (the float32 plan)")
            XCTAssertLessThan(planError, tapTolerance, "\(id): log_e_print (the plan)")
        }
        if taps.contains("cmy_print") {
            let error = maxAbsoluteDifference(cpu.cmyPrint.data, float32Taps.cmyPrint.data)
            let planError = maxAbsoluteDifference(cpu.cmyPrint.data, planTaps.cmyPrint.data)
            worstTap = Swift.max(worstTap, error)
            worstPlanTap = Swift.max(worstPlanTap, planError)
            XCTAssertLessThan(error, tapTolerance, "\(id): cmy_print (the float32 plan)")
            XCTAssertLessThan(planError, tapTolerance, "\(id): cmy_print (the plan)")
        }
        let planError = deltaE(cpu.rgbOut.data, planTaps.rgbOut.data)
        let float32Error = deltaE(cpu.rgbOut.data, float32Taps.rgbOut.data)
        let rgbError = maxAbsoluteDifference(cpu.rgbOut.data, float32Taps.rgbOut.data)
        XCTAssertLessThan(
            planError.mean, meanDeltaETolerance, "\(id): rgb_out (the plan)"
        )
        XCTAssertLessThan(
            float32Error.mean, meanDeltaETolerance, "\(id): rgb_out (the float32 plan)"
        )
        XCTAssertLessThan(
            float32Error.max, maxDeltaETolerance, "\(id): rgb_out (the float32 plan)"
        )
        return Row(
            id: id,
            taps: worstTap,
            planTaps: worstPlanTap,
            meanDeltaE: float32Error.mean,
            maxDeltaE: float32Error.max,
            planMeanDeltaE: planError.mean,
            rgbOut: rgbError
        )
    }

    /// Prints the summary of a family of comparisons.
    private func printSummary(_ title: String, _ rows: [Row]) {
        var summary = Summary()
        for row in rows { summary.add(row) }
        print("")
        print("[plan evaluator] \(title)")
        print("  \(rows.count) cases")
        print("  the intermediate taps: max abs error \(summary.taps) "
            + "(the float32 plan), \(summary.planTaps) (the plan)")
        print("  rgb_out: max abs error \(summary.rgbOut)")
        print("  rgb_out: mean dE2000 \(summary.meanDeltaE) (the float32 plan), "
            + "\(summary.planMeanDeltaE) (the plan)")
        print("  rgb_out: max dE2000 \(summary.maxDeltaE)")
        print("")
    }

    // MARK: - The slice 2 cases

    /// The plan evaluator reproduces the CPU pipeline of the slice 2.
    ///
    /// The four cases of the slice 2 run the whole pipeline from the camera
    /// image; every spatial and stochastic effect is off, so the CPU
    /// pipeline *is* the per pixel chain the plan evaluates.
    func testThePlanEvaluatorMatchesTheCPUPipelineOfSlice2() throws {
        let common = try JSONValue.load(named: "slice2_common")
        let film = try cachedProfile(stock: "kodak_portra_400")
        let printProfile = try cachedProfile(stock: "kodak_portra_endura")

        var rows: [Row] = []
        for name in ["defaults", "srgb_input", "camera_ev_minus1", "output_gamut_off"] {
            let fixture = try JSONValue.load(named: "slice2_\(name)")
            let params = try makePipelineParams(
                fixture: fixture, film: film, print: printProfile
            )
            let input = try slice2Input(common: common, name: fixture)
            let cpu = try FilmPipeline(params: params).process(rgbIn: input)
            let plan = try FilmRenderPlan.build(params: params)
            let planTaps = try FilmPlanEvaluator.evaluate(plan: plan, rgbIn: input)
            let float32Taps = try FilmPlanEvaluatorFloat32.evaluate(plan: plan, rgbIn: input)
            rows.append(try compare(
                id: name,
                cpu: cpu,
                planTaps: planTaps,
                float32Taps: float32Taps,
                taps: ["log_e_film", "cmy_film", "log_e_print", "cmy_print", "rgb_out"]
            ))
        }
        printSummary("the slice 2 (the whole pipeline from rgb_in)", rows)
    }

    /// The input image of a slice 2 case.
    private func slice2Input(common: JSONValue, name: JSONValue) throws -> RGBImage {
        let inputs = try XCTUnwrap(common["input_images"])
        let identifier = try XCTUnwrap(name["input"]?.string)
        let image = try XCTUnwrap(inputs[identifier])
        let size = try XCTUnwrap(image["size"]?.doubles)
        let data = try XCTUnwrap(image["data"]?.flatDoubles)
        return RGBImage(width: Int(size[0]), height: Int(size[1]), data: data)
    }

    // MARK: - The catalogue of the slice 4

    /// The plan evaluator reproduces the CPU pipeline of the catalogue.
    ///
    /// The catalogue of the slice 4 holds the 148 looks of the engine (the
    /// 16 colour negatives printed on the 8 print media and the 20 films
    /// scanned directly).  Every case runs the whole pipeline on a 6 × 6
    /// image; the plan evaluator is checked on **every** case, because the
    /// cost of a case is dominated by the building of the lookup table of
    /// the film, which is cached and shared by the cases of a stock: the
    /// whole family runs in 13 s.
    func testThePlanEvaluatorMatchesTheCPUPipelineOfTheCatalogue() throws {
        let fixture = try JSONValue.load(named: "slice4_catalog")
        let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)
        let image = try XCTUnwrap(fixture["test_image"])
        let size = try XCTUnwrap(image["size"]?.doubles)
        let data = try XCTUnwrap(image["data"]?.flatDoubles)
        let input = RGBImage(width: Int(size[0]), height: Int(size[1]), data: data)

        var rows: [Row] = []
        for entry in cases {
            let id = try XCTUnwrap(entry["id"]?.string)
            let params = try catalogueParams(entry)
            let cpu = try FilmPipeline(params: params).process(rgbIn: input)
            let plan = try FilmRenderPlan.build(params: params)
            let planTaps = try FilmPlanEvaluator.evaluate(plan: plan, rgbIn: input)
            let float32Taps = try FilmPlanEvaluatorFloat32.evaluate(plan: plan, rgbIn: input)
            rows.append(try compare(
                id: id,
                cpu: cpu,
                planTaps: planTaps,
                float32Taps: float32Taps,
                taps: ["cmy_film"]
            ))
        }
        printSummary("the catalogue of the slice 4 (\(rows.count) looks)", rows)
    }

    /// The parameters of a catalogue case.
    private func catalogueParams(_ entry: JSONValue) throws -> PipelineParams {
        let film = try XCTUnwrap(try StockCatalog.profile(
            stock: try XCTUnwrap(entry["film"]?.string)
        ))
        let printProfile = try XCTUnwrap(try StockCatalog.profile(
            stock: try XCTUnwrap(entry["print"]?.string)
        ))
        var dirCouplers = DirCouplersParams()
        dirCouplers.diffusionSizeUM = 0.0
        var filmRender = FilmRenderParams(dirCouplers: dirCouplers)
        filmRender.halation.active = false
        filmRender.grain.active = false
        return PipelineParams(
            film: film,
            print: printProfile,
            camera: CameraParams(autoExposure: false),
            filmRender: filmRender,
            printRender: PrintRenderParams(glare: GlareParams(active: false)),
            scanner: ScannerParams(unsharpMaskSigma: 0, unsharpMaskAmount: 0),
            io: IOParams(scanFilm: try XCTUnwrap(entry["mode"]?.string) == "scan_film")
        )
    }

    // MARK: - The spatial cases of the slice 5

    /// The plan evaluator reproduces the CPU pipeline of the slice 5.
    ///
    /// The cases of the slice 5 exercise the **spatial** effects (the
    /// halation, the diffusion filters, the lens blurs and the unsharp
    /// mask).  Those effects are *passes* of the GPU pipeline, not part of
    /// the per pixel chain: the plan evaluator does not model them.  The
    /// test therefore compares the plan evaluator with the CPU pipeline
    /// **without** the spatial effects (the per pixel chain), and checks
    /// that the difference between the CPU pipeline *with* the effects and
    /// the plan evaluator is not larger than the effect itself (i.e. the
    /// plan evaluator does not add an error of its own on top of the
    /// spatial effects).
    func testThePlanEvaluatorMatchesTheCPUPipelineOfTheSpatialCases() throws {
        let fixture = try JSONValue.load(named: "slice5_spatial")
        let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)
        let image = try XCTUnwrap(fixture["test_image"])
        let size = try XCTUnwrap(image["size"]?.doubles)
        let data = try XCTUnwrap(image["data"]?.flatDoubles)
        let input = RGBImage(width: Int(size[0]), height: Int(size[1]), data: data)
        let film = try cachedProfile(stock: "kodak_portra_400")
        let printProfile = try cachedProfile(stock: "kodak_portra_endura")

        var rows: [Row] = []
        for entry in cases {
            let id = try XCTUnwrap(entry["id"]?.string)
            let params = try makePipelineParams(
                fixture: entry, film: film, print: printProfile
            )
            // The CPU pipeline with the spatial effects of the case.
            let cpu = try FilmPipeline(params: params).process(rgbIn: input)
            // The CPU pipeline without them: the per pixel chain only.
            let plain = try FilmPipeline(params: withoutSpatialEffects(params))
                .process(rgbIn: input)
            let plan = try FilmRenderPlan.build(params: params)
            let planTaps = try FilmPlanEvaluator.evaluate(plan: plan, rgbIn: input)
            let float32Taps = try FilmPlanEvaluatorFloat32.evaluate(plan: plan, rgbIn: input)

            // The per pixel chain: the plan evaluator against the CPU
            // pipeline without the spatial effects.
            let taps = ["log_e_film", "cmy_film", "log_e_print", "cmy_print", "rgb_out"]
            rows.append(try compare(
                id: id,
                cpu: plain,
                planTaps: planTaps,
                float32Taps: float32Taps,
                taps: taps
            ))

            // The spatial effects: the difference between the CPU pipeline
            // with them and the plan evaluator is not larger than the
            // effect itself (with the tolerance of the `Float32` rounding).
            let effect = maxAbsoluteDifference(cpu.rgbOut.data, plain.rgbOut.data)
            let difference = maxAbsoluteDifference(cpu.rgbOut.data, float32Taps.rgbOut.data)
            XCTAssertLessThanOrEqual(
                difference,
                effect + 1e-3,
                "\(id): the difference of the plan evaluator is larger than "
                    + "the spatial effect itself"
            )
        }
        printSummary("the spatial cases of the slice 5", rows)
    }

    /// The parameters of a case without the spatial effects.
    private func withoutSpatialEffects(_ params: PipelineParams) -> PipelineParams {
        var output = params
        output.filmRender.halation.active = false
        output.filmRender.dirCouplers.diffusionSizeUM = 0
        output.filmRender.dirCouplers.diffusionTailUM = 0
        output.camera.diffusionFilter.active = false
        output.camera.lensBlurUM = 0
        output.enlarger.diffusionFilter.active = false
        output.scanner.lensBlur = 0
        output.scanner.unsharpMaskSigma = 0
        output.scanner.unsharpMaskAmount = 0
        return output
    }
}
