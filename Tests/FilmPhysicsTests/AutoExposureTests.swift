//
//  AutoExposureTests.swift
//  light suffer胶片 — iOS app
//
//  CPU auto-exposure parity against unmodified upstream Python: all metering
//  methods, the 256-pixel preview, and the complete FilmPipeline path.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class AutoExposureTests: XCTestCase {

    private static let pipelineCases = [
        "autoexposure_pipeline_off",
        "autoexposure_pipeline_center_weighted",
        "autoexposure_pipeline_compensation",
    ]

    private let relativeTolerance = 1e-6
    private let absoluteFloor = 1e-8

    // MARK: - Helpers

    private func assertMatches(
        _ produced: Double,
        _ expected: Double,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let difference = abs(produced - expected)
        let tolerance = Swift.max(
            relativeTolerance * Swift.max(abs(produced), abs(expected)),
            absoluteFloor
        )
        XCTAssertLessThanOrEqual(
            difference,
            tolerance,
            "\(label): produced \(produced), expected \(expected), "
                + "difference \(difference), tolerance \(tolerance)",
            file: file,
            line: line
        )
    }

    private func inputImage(common: JSONValue, named name: String) throws -> RGBImage {
        let record = try XCTUnwrap(common["images"]?[name])
        let size = try XCTUnwrap(record["size"]?.doubles)
        return RGBImage(
            width: Int(size[0]),
            height: Int(size[1]),
            data: try XCTUnwrap(record["data"]?.flatDoubles)
        )
    }

    private func labImage(_ rgb: [Double]) -> [LabColour] {
        stride(from: 0, to: rgb.count, by: 3).map { index in
            let clipped = (0..<3).map { channel in
                Swift.min(Swift.max(rgb[index + channel], 0), 1)
            }
            return Colour.sRGBToLab(clipped)
        }
    }

    private func deltaE(
        _ reference: [Double], _ produced: [Double]
    ) -> (mean: Double, max: Double) {
        let referenceLab = labImage(reference)
        let producedLab = labImage(produced)
        var sum = 0.0
        var maximum = 0.0
        for index in 0..<referenceLab.count {
            let value = Colour.deltaE2000(referenceLab[index], producedLab[index])
            sum += value
            maximum = Swift.max(maximum, value)
        }
        return (sum / Double(referenceLab.count), maximum)
    }

    // MARK: - Preview and metering

    /// The complete upstream previews diagnose the order-0 sampling, and all
    /// recorded method / I/O combinations meet the usual 1e-6 relative gate.
    func testPreviewAndEVParityForEveryRecordedMethodAndIOVariant() throws {
        let common = try JSONValue.load(named: "autoexposure_common")
        let entries = try XCTUnwrap(common["metering"]?.arrayElements)
        XCTAssertEqual(entries.count, 16, "7 methods + unknown, on two I/O variants")

        var checkedPreviews: Set<String> = []
        var maximumRelativeError = 0.0
        var maximumAbsoluteError = 0.0
        var linearMethodEVs: [Double] = []

        for entry in entries {
            let inputName = try XCTUnwrap(entry["input"]?.string)
            let image = try inputImage(common: common, named: inputName)
            let colourspaceName = try XCTUnwrap(entry["input_color_space"]?.string)
            let colourspace = try XCTUnwrap(RGBColourspace.named(colourspaceName))
            let decoding = try XCTUnwrap(entry["input_cctf_decoding"]?.bool)
            let method = try XCTUnwrap(entry["method"]?.string)

            let preview = AutoExposure.smallPreview(image)
            let previewShape = try XCTUnwrap(entry["preview_shape"]?.doubles)
            XCTAssertEqual(preview.height, Int(previewShape[0]), "\(inputName) preview height")
            XCTAssertEqual(preview.width, Int(previewShape[1]), "\(inputName) preview width")
            XCTAssertEqual(Swift.max(image.width, image.height), 320)
            XCTAssertEqual(Swift.max(preview.width, preview.height), 256)

            if checkedPreviews.insert(inputName).inserted {
                let referencePreview = try XCTUnwrap(common["previews"]?[inputName])
                let referenceData = try XCTUnwrap(referencePreview["data"]?.flatDoubles)
                let previewError = maxAbsoluteDifference(preview.data, referenceData)
                print("[auto exposure preview] \(inputName): max abs error \(previewError)")
                // The fixture stores seven significant digits. The bundled
                // skimage 0.26 default filter differs from explicit nearest
                // sampling by less than 9e-16 on this smooth image.
                XCTAssertLessThan(previewError, 5e-6, "\(inputName): preview samples")
            }

            let expected = try XCTUnwrap(entry["ev"]?.double)
            let produced = AutoExposure.meteredEV(
                image: image,
                colourspace: colourspace,
                applyCCTFDecoding: decoding,
                method: method
            )
            let label = "\(inputName) / \(colourspaceName), decoding=\(decoding), \(method)"
            assertMatches(produced, expected, label)

            let absolute = abs(produced - expected)
            maximumAbsoluteError = Swift.max(maximumAbsoluteError, absolute)
            let scale = Swift.max(abs(produced), abs(expected))
            if scale > 0 {
                maximumRelativeError = Swift.max(maximumRelativeError, absolute / scale)
            }
            if inputName == "linear_prophoto", method != common["unknown_method"]?.string {
                linearMethodEVs.append(produced)
            }
        }

        // The deterministic image is deliberately not metering-neutral: all
        // seven upstream methods must exercise materially different EVs.
        XCTAssertEqual(linearMethodEVs.count, 7)
        for first in 0..<linearMethodEVs.count {
            for second in (first + 1)..<linearMethodEVs.count {
                XCTAssertGreaterThan(
                    abs(linearMethodEVs[first] - linearMethodEVs[second]),
                    1e-4,
                    "the fixture should distinguish the seven metering methods"
                )
            }
        }
        print(
            "[auto exposure EV] max relative error \(maximumRelativeError), "
                + "max abs error \(maximumAbsoluteError)"
        )
    }

    /// small_preview is an identity at or below 256, and the upstream Inf
    /// fallback is reproduced for every method on an all-black image.
    func testSmallPreviewIdentityAndBlackImageFallback() {
        let image = RGBImage(width: 4, height: 3, data: [
            0.1, 0.2, 0.3, 0.2, 0.3, 0.4,
            0.3, 0.4, 0.5, 0.4, 0.5, 0.6,
            0.5, 0.6, 0.7, 0.6, 0.7, 0.8,
            0.7, 0.8, 0.9, 0.8, 0.9, 1.0,
            0.9, 1.0, 0.8, 1.0, 0.9, 0.7,
            0.2, 0.4, 0.6, 0.3, 0.5, 0.7,
        ])
        XCTAssertEqual(AutoExposure.smallPreview(image), image)

        let black = RGBImage(width: 4, height: 3, data: [Double](repeating: 0, count: 36))
        for method in AutoExposure.methods + ["unknown"] {
            let ev = AutoExposure.meteredEV(
                image: black,
                colourspace: .proPhotoRGB,
                applyCCTFDecoding: false,
                method: method
            )
            XCTAssertEqual(ev, 0, "\(method): infinite EV must become zero")
        }
    }

    // MARK: - Whole pipeline

    /// AE off, AE on, and AE plus camera compensation all reproduce the
    /// unmodified SimulationPipeline from rgb_in through rgb_out.
    func testFilmPipelineMatchesUpstreamWithAndWithoutAutoExposure() throws {
        let common = try JSONValue.load(named: "autoexposure_common")
        let film = try ProfileLoader.load(stock: "kodak_portra_400")
        let printProfile = try ProfileLoader.load(stock: "kodak_portra_endura")
        var referenceMidgray: [String: [Double]] = [:]
        var referenceMidgrayComp: [String: [Double]] = [:]
        var referenceLogFilm: [String: [Double]] = [:]
        var measuredEV: [String: Double] = [:]

        for name in Self.pipelineCases {
            let fixture = try JSONValue.load(named: name)
            let caseName = try XCTUnwrap(fixture["case"]?.string)
            let params = try makePipelineParams(
                fixture: fixture, film: film, print: printProfile
            )
            let pipeline = try FilmPipeline(params: params)
            let inputName = try XCTUnwrap(fixture["input"]?.string)
            let input = try inputImage(common: common, named: inputName)
            let result = try pipeline.process(rgbIn: input)
            let taps = try XCTUnwrap(fixture["taps"])
            let derived = try XCTUnwrap(fixture["derived"])

            let referenceRGBIn = try XCTUnwrap(taps["rgb_in"]?.flatDoubles)
            let referenceLogEFilm = try XCTUnwrap(taps["log_e_film"]?.flatDoubles)
            let referenceRGBOut = try XCTUnwrap(taps["rgb_out"]?.flatDoubles)
            XCTAssertEqual(maxAbsoluteDifference(input.data, referenceRGBIn), 0)

            let logError = maxAbsoluteDifference(result.logEFilm.data, referenceLogEFilm)
            let rgbError = maxAbsoluteDifference(result.rgbOut.data, referenceRGBOut)
            let colourError = deltaE(referenceRGBOut, result.rgbOut.data)
            print(
                "[auto exposure pipeline] \(caseName): log_e_film max abs \(logError), "
                    + "rgb_out max abs \(rgbError), mean dE2000 \(colourError.mean), "
                    + "max dE2000 \(colourError.max)"
            )
            XCTAssertLessThan(logError, 5e-6, "\(caseName): log_e_film")
            XCTAssertLessThan(colourError.mean, 0.01, "\(caseName): rgb_out mean dE2000")
            XCTAssertLessThan(colourError.max, 0.05, "\(caseName): rgb_out max dE2000")

            let balance = try XCTUnwrap(derived["print_balance"])
            let midgray = try XCTUnwrap(balance["density_spectral_midgray"]?.doubles)
            let midgrayComp = try XCTUnwrap(balance["density_spectral_midgray_comp"]?.doubles)
            XCTAssertLessThan(
                maxAbsoluteDifference(pipeline.inputs.enlarger.densitySpectralMidgray, midgray),
                5e-6,
                "\(caseName): the un-compensated print-balance mid-grey"
            )
            XCTAssertLessThan(
                maxAbsoluteDifference(
                    pipeline.inputs.enlarger.densitySpectralMidgrayComp ?? [], midgrayComp
                ),
                5e-6,
                "\(caseName): compensated print-balance mid-grey uses camera compensation only"
            )
            referenceMidgray[caseName] = midgray
            referenceMidgrayComp[caseName] = midgrayComp
            referenceLogFilm[caseName] = referenceLogEFilm

            let ev = try XCTUnwrap(derived["auto_exposure_ev"]?.double)
            measuredEV[caseName] = ev
            if params.camera.autoExposure {
                assertMatches(
                    AutoExposure.meteredEV(
                        image: input,
                        colourspace: .proPhotoRGB,
                        applyCCTFDecoding: false,
                        method: params.camera.autoExposureMethod
                    ),
                    ev,
                    "\(caseName): pipeline metering EV"
                )
            } else {
                XCTAssertEqual(ev, 0)
            }
            assertMatches(
                try XCTUnwrap(derived["auto_exposure_scale"]?.double),
                pow(2.0, ev),
                "\(caseName): recorded AE scale"
            )
            assertMatches(
                try XCTUnwrap(derived["camera_exposure_scale"]?.double),
                pow(2.0, params.camera.exposureCompensationEV),
                "\(caseName): camera compensation remains a separate scale"
            )
        }

        // The base mid-grey is image-independent in every case. The
        // compensated reference changes only when exposureCompensationEV
        // changes, never because AE metered the input image.
        let offMidgray = try XCTUnwrap(referenceMidgray["off"])
        let aeMidgray = try XCTUnwrap(referenceMidgray["center_weighted"])
        let compensationMidgray = try XCTUnwrap(
            referenceMidgray["center_weighted_plus_compensation"]
        )
        let offMidgrayComp = try XCTUnwrap(referenceMidgrayComp["off"])
        let aeMidgrayComp = try XCTUnwrap(referenceMidgrayComp["center_weighted"])
        let compensationMidgrayComp = try XCTUnwrap(
            referenceMidgrayComp["center_weighted_plus_compensation"]
        )
        // NaN-aware comparison: the spectral profiles contain missing samples.
        XCTAssertEqual(maxAbsoluteDifference(offMidgray, aeMidgray), 0)
        XCTAssertEqual(maxAbsoluteDifference(offMidgray, compensationMidgray), 0)
        XCTAssertEqual(maxAbsoluteDifference(offMidgrayComp, aeMidgrayComp), 0)
        XCTAssertGreaterThan(maxAbsoluteDifference(aeMidgrayComp, compensationMidgrayComp), 0)
        XCTAssertEqual(measuredEV["off"], 0)
        XCTAssertEqual(measuredEV["center_weighted"], measuredEV["center_weighted_plus_compensation"])
        XCTAssertGreaterThan(
            maxAbsoluteDifference(
                referenceLogFilm["off"] ?? [], referenceLogFilm["center_weighted"] ?? []
            ),
            1e-3,
            "AE must change the negative exposure"
        )
        XCTAssertGreaterThan(
            maxAbsoluteDifference(
                referenceLogFilm["center_weighted"] ?? [],
                referenceLogFilm["center_weighted_plus_compensation"] ?? []
            ),
            1e-3,
            "camera compensation must apply in addition to AE"
        )
    }

    /// FilmPipeline.init no longer rejects AE, while an unrelated unported
    /// RGB-to-raw algorithm remains rejected.
    func testInitAcceptsAutoExposureButStillRejectsMallett2019() throws {
        let film = try ProfileLoader.load(stock: "kodak_portra_400")
        let printProfile = try ProfileLoader.load(stock: "kodak_portra_endura")
        let camera = CameraParams(autoExposure: true)
        XCTAssertEqual(camera.autoExposureMethod, "center_weighted")
        var params = PipelineParams(film: film, print: printProfile, camera: camera)
        let pipeline = try FilmPipeline(params: params)
        XCTAssertTrue(pipeline.params.camera.autoExposure)
        XCTAssertEqual(pipeline.params.camera.autoExposureMethod, "center_weighted")

        params.settings.rgbToRawMethod = "mallett2019"
        XCTAssertThrowsError(try FilmPipeline(params: params))
    }

    /// With AE off, changing its method cannot affect any tap of the existing
    /// path. Two complete process calls must be bit-identical.
    func testAutoExposureOffIsANoOp() throws {
        let common = try JSONValue.load(named: "slice2_common")
        let fixture = try JSONValue.load(named: "slice2_defaults")
        let film = try ProfileLoader.load(stock: "kodak_portra_400")
        let printProfile = try ProfileLoader.load(stock: "kodak_portra_endura")
        var firstParams = try makePipelineParams(fixture: fixture, film: film, print: printProfile)
        XCTAssertEqual(
            firstParams.camera.autoExposureMethod,
            "center_weighted",
            "an old fixture without auto_exposure_method uses the upstream default"
        )
        var secondParams = firstParams
        firstParams.camera.autoExposure = false
        firstParams.camera.autoExposureMethod = "center_weighted"
        secondParams.camera.autoExposure = false
        secondParams.camera.autoExposureMethod = "highlight_weighted"

        let inputs = try XCTUnwrap(common["input_images"])
        let inputName = try XCTUnwrap(fixture["input"]?.string)
        let record = try XCTUnwrap(inputs[inputName])
        let size = try XCTUnwrap(record["size"]?.doubles)
        let input = RGBImage(
            width: Int(size[0]),
            height: Int(size[1]),
            data: try XCTUnwrap(record["data"]?.flatDoubles)
        )
        let first = try FilmPipeline(params: firstParams).process(rgbIn: input)
        let second = try FilmPipeline(params: secondParams).process(rgbIn: input)
        XCTAssertEqual(first, second)
    }
}
