//
//  Slice2ParityTests.swift
//  light suffer胶片 — iOS app
//
//  The parity tests of the slice 2 port: the whole pipeline is run from
//  the camera image (`rgb_in`) and every tap is compared with the
//  reference captured from the upstream Python engine.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class Slice2ParityTests: XCTestCase {

    /// The parameter cases of the reference fixtures.
    private static let cases = [
        "defaults",
        "srgb_input",
        "camera_ev_minus1",
        "output_gamut_off",
    ]

    /// The relative tolerance of the comparison with the reference fixtures.
    ///
    /// The fixtures store the values with seven significant digits, so the
    /// rounding alone is worth about 1e-6 relative.
    private let relativeTolerance = 1e-6

    /// The absolute floor of the comparison with the reference fixtures.
    ///
    /// The near-null components of the colour matrices (≈ 1e-3) are stored
    /// with a unit in the last place of 1e-8, and the bundled spectral
    /// resources are `float32`; the floor keeps the comparison meaningful
    /// for those components (their *relative* error is dominated by the
    /// rounding of the reference, not by the port).
    private let absoluteFloor = 1e-8

    // MARK: - Helpers

    /// The tolerance of a comparison with the reference fixtures.
    ///
    /// The relative tolerance dominates; the absolute floor covers the
    /// near-null components of the matrices.
    private func tolerance(for expected: Double, produced: Double) -> Double {
        Swift.max(
            relativeTolerance * Swift.max(abs(expected), abs(produced)),
            absoluteFloor
        )
    }

    /// Compares a value with the reference fixture.
    private func assertMatches(
        _ produced: Double,
        _ expected: Double,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let difference = abs(produced - expected)
        let allowed = tolerance(for: expected, produced: produced)
        XCTAssertLessThanOrEqual(
            difference,
            allowed,
            "\(label): \(produced) is not \(expected) "
                + "(difference \(difference), tolerance \(allowed))",
            file: file,
            line: line
        )
    }

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

    /// The parameters of a slice 2 case.
    private func makeParams(
        fixture: JSONValue, film: Profile, print: Profile
    ) throws -> PipelineParams {
        try makePipelineParams(fixture: fixture, film: film, print: print)
    }

    /// The input image of a case.
    private func makeInput(common: JSONValue, name: String) throws -> RGBImage {
        let inputs = try XCTUnwrap(common["input_images"])
        let image = try XCTUnwrap(inputs[name])
        let size = try XCTUnwrap(image["size"]?.doubles)
        let data = try XCTUnwrap(image["data"]?.flatDoubles)
        return RGBImage(width: Int(size[0]), height: Int(size[1]), data: data)
    }

    // MARK: - Tests

    /// The whole pipeline reproduces every tap of the reference.
    func testPipelineMatchesTheReferenceTaps() throws {
        let common = try JSONValue.load(named: "slice2_common")
        let film = try ProfileLoader.load(stock: "kodak_portra_400")
        let printProfile = try ProfileLoader.load(stock: "kodak_portra_endura")

        for name in Self.cases {
            let fixture = try JSONValue.load(named: "slice2_\(name)")
            let taps = try XCTUnwrap(fixture["taps"])
            let params = try makeParams(fixture: fixture, film: film, print: printProfile)
            let pipeline = try FilmPipeline(params: params)
            let input = try makeInput(common: common, name: try XCTUnwrap(fixture["input"]?.string))
            let result = try pipeline.process(rgbIn: input)

            let referenceLogEFilm = try XCTUnwrap(taps["log_e_film"]?.flatDoubles)
            let referenceCMYFilm = try XCTUnwrap(taps["cmy_film"]?.flatDoubles)
            let referenceLogEPrint = try XCTUnwrap(taps["log_e_print"]?.flatDoubles)
            let referenceCMYPrint = try XCTUnwrap(taps["cmy_print"]?.flatDoubles)
            let referenceRGBOut = try XCTUnwrap(taps["rgb_out"]?.flatDoubles)

            let logEFilmError = maxAbsoluteDifference(result.logEFilm.data, referenceLogEFilm)
            let cmyFilmError = maxAbsoluteDifference(result.cmyFilm.data, referenceCMYFilm)
            let logEPrintError = maxAbsoluteDifference(result.logEPrint.data, referenceLogEPrint)
            let cmyPrintError = maxAbsoluteDifference(result.cmyPrint.data, referenceCMYPrint)
            let rgbError = maxAbsoluteDifference(result.rgbOut.data, referenceRGBOut)
            let deltaE = deltaE(referenceRGBOut, result.rgbOut.data)

            print("""

                [slice2 parity] \(name)
                  log_e_film : max abs error \(logEFilmError)
                  cmy_film   : max abs error \(cmyFilmError)
                  log_e_print: max abs error \(logEPrintError)
                  cmy_print  : max abs error \(cmyPrintError)
                  rgb_out    : max abs error \(rgbError), \
                mean dE2000 \(deltaE.mean), max dE2000 \(deltaE.max)

                """)

            XCTAssertLessThan(logEFilmError, 5e-6, "\(name): log_e_film")
            XCTAssertLessThan(cmyFilmError, 5e-6, "\(name): cmy_film")
            XCTAssertLessThan(logEPrintError, 5e-6, "\(name): log_e_print")
            XCTAssertLessThan(cmyPrintError, 5e-6, "\(name): cmy_print")
            XCTAssertLessThan(deltaE.mean, 0.5, "\(name): rgb_out mean dE2000")
        }
    }

    /// The tc lookup table of the port reproduces the reference.
    func testTCLUTMatchesTheReference() throws {
        let common = try JSONValue.load(named: "slice1_common")
        let reference = try XCTUnwrap(common["hanatos2025_tc_lut"])
        let shape = try XCTUnwrap(reference["shape"]?.doubles)
        let encoded = try XCTUnwrap(reference["data"]?.string)
        let data = try XCTUnwrap(Data(base64Encoded: encoded))

        let size = Int(shape[0])
        let channels = 3
        let count = data.count / 4
        var referenceValues = [Double](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let source = raw.bindMemory(to: UInt8.self)
            for index in 0..<count {
                let offset = index * 4
                let bits = UInt32(source[offset])
                    | (UInt32(source[offset + 1]) << 8)
                    | (UInt32(source[offset + 2]) << 16)
                    | (UInt32(source[offset + 3]) << 24)
                referenceValues[index] = Double(Float(bitPattern: bits))
            }
        }

        let film = try ProfileLoader.load(stock: "kodak_portra_400")
        // The spatial effects are off (the upstream reference fixtures run
        // without them): the unsharp mask of the scanner is disabled, so the
        // pipeline accepts the parameters.
        let params = PipelineParams(
            film: film,
            print: try ProfileLoader.load(stock: "kodak_portra_endura"),
            camera: CameraParams(autoExposure: false),
            scanner: ScannerParams(unsharpMaskSigma: 0, unsharpMaskAmount: 0)
        )
        let pipeline = try FilmPipeline(params: params)
        XCTAssertEqual(pipeline.tcLUT.size, size)

        var maximumRelativeError = 0.0
        var maximumAbsoluteError = 0.0
        for index in 0..<min(count, pipeline.tcLUT.values.count) {
            let expected = referenceValues[index]
            let produced = pipeline.tcLUT.values[index]
            let absolute = abs(expected - produced)
            maximumAbsoluteError = Swift.max(maximumAbsoluteError, absolute)
            let relative = absolute / Swift.max(abs(expected), 1e-12)
            maximumRelativeError = Swift.max(maximumRelativeError, relative)
        }
        print("""

            [slice2 tc lut] max relative error \(maximumRelativeError), \
            max absolute error \(maximumAbsoluteError)

            """)
        XCTAssertLessThan(maximumRelativeError, 1e-4, "the tc LUT matches the reference")
    }

    /// The CAM16-UCS forward model reproduces the reference.
    func testCAM16UCSMatchesTheReference() throws {
        let common = try JSONValue.load(named: "slice2_common")
        let cam16 = try XCTUnwrap(common["cam16ucs"])
        let samples = try XCTUnwrap(cam16["samples"]?.arrayElements)
        let xyzWhite = try XCTUnwrap(cam16["xyz_w"]?.doubles)
        let viewing = try XCTUnwrap(cam16["viewing_conditions"])
        let LA = try XCTUnwrap(viewing["L_A"]?.double)
        let Yb = try XCTUnwrap(viewing["Y_b"]?.double)

        var maximumError = 0.0
        for sample in samples {
            let xyz = try XCTUnwrap(sample["xyz"]?.doubles)
            let reference = try XCTUnwrap(sample["jpab"]?.doubles)
            let produced = CAM16.xyzToCAM16UCS(
                xyz: xyz, xyzWhite: xyzWhite, LA: LA, Yb: Yb
            )
            for index in 0..<3 {
                maximumError = Swift.max(maximumError, abs(reference[index] - produced[index]))
            }
        }
        print("""

            [slice2 cam16ucs] max abs error \(maximumError)

            """)
        XCTAssertLessThan(maximumError, 1e-4, "the CAM16-UCS forward model matches")
    }

    /// The CAM16-UCS round trip returns the original tristimulus values.
    func testCAM16UCSRoundTrip() throws {
        let common = try JSONValue.load(named: "slice2_common")
        let cam16 = try XCTUnwrap(common["cam16ucs"])
        let samples = try XCTUnwrap(cam16["samples"]?.arrayElements)
        let xyzWhite = try XCTUnwrap(cam16["xyz_w"]?.doubles)
        let viewing = try XCTUnwrap(cam16["viewing_conditions"])
        let LA = try XCTUnwrap(viewing["L_A"]?.double)
        let Yb = try XCTUnwrap(viewing["Y_b"]?.double)

        var maximumError = 0.0
        for sample in samples {
            let xyz = try XCTUnwrap(sample["xyz"]?.doubles)
            let jab = CAM16.xyzToCAM16UCS(xyz: xyz, xyzWhite: xyzWhite, LA: LA, Yb: Yb)
            let back = CAM16.cam16UCStoXYZ(jab: jab, xyzWhite: xyzWhite, LA: LA, Yb: Yb)
            for index in 0..<3 {
                maximumError = Swift.max(maximumError, abs(xyz[index] - back[index]))
            }
        }
        print("""

            [slice2 cam16ucs round trip] max abs error \(maximumError)

            """)
        XCTAssertLessThan(maximumError, 1e-9, "the CAM16-UCS round trip is exact")
    }

    /// The output gamut compressor reproduces the reference.
    func testGamutCompressorMatchesTheReference() throws {
        let common = try JSONValue.load(named: "slice2_common")
        let cam16 = try XCTUnwrap(common["cam16ucs"])
        let samples = try XCTUnwrap(cam16["samples"]?.arrayElements)

        let spec = OutputGamutCompressSpec(algorithm: "cam16ucs")
        var maximumError = 0.0
        for sample in samples {
            let rgb = try XCTUnwrap(sample["rgb"]?.doubles)
            let reference = try XCTUnwrap(sample["compressed"]?.doubles)
            let produced = GamutCompression.compressRGB(
                rgb, spec: spec, outputColourSpace: .sRGB
            )
            for index in 0..<3 {
                maximumError = Swift.max(maximumError, abs(reference[index] - produced[index]))
            }
        }
        print("""

            [slice2 gamut compressor] max abs error \(maximumError)

            """)
        XCTAssertLessThan(maximumError, 1e-6, "the output gamut compressor matches")
    }

    /// The colour matrices of the port reproduce the reference.
    func testColourMatricesMatchTheReference() throws {
        let common = try JSONValue.load(named: "slice2_common")
        let colour = try XCTUnwrap(common["color"])

        let referenceIlluminantXY = try XCTUnwrap(colour["reference_illuminant_xy"]?.doubles)
        let reference = Chromaticity(
            x: referenceIlluminantXY[0], y: referenceIlluminantXY[1]
        )
        let illumination = try XCTUnwrap(common["illuminants"])
        let cmfs = try XCTUnwrap(common["spectral"]?["cmfs_cie1931_2deg"]?.doubleRows)

        // The chromaticity of the reference illuminant.
        let spectrum = try XCTUnwrap(illumination["D55"]?.doubles)
        var xyz = [Double](repeating: 0, count: 3)
        for wavelength in 0..<min(spectrum.count, cmfs.count) {
            for component in 0..<3 {
                xyz[component] += spectrum[wavelength] * cmfs[wavelength][component]
            }
        }
        let total = xyz[0] + xyz[1] + xyz[2]
        let chromaticity = Chromaticity(x: xyz[0] / total, y: xyz[1] / total)
        assertMatches(chromaticity.x, reference.x, "the chromaticity x of D55")
        assertMatches(chromaticity.y, reference.y, "the chromaticity y of D55")

        // The ProPhoto RGB -> XYZ matrix of the filming stage.
        let filmingReference = try XCTUnwrap(colour["filming_prophoto_rgb_to_xyz"]?.doubleRows)
        let filming = ColourScience.rgbToXYZ(
            rgb: [1, 0, 0],
            colourspace: .proPhotoRGB,
            illuminant: reference,
            transform: .cat16,
            applyCCTFDecoding: false
        )
        assertMatches(filming[0], filmingReference[0][0], "the filming matrix X")
        assertMatches(filming[1], filmingReference[1][0], "the filming matrix Y")
        assertMatches(filming[2], filmingReference[2][0], "the filming matrix Z")

        let relativeErrors = [
            relativeDifference(chromaticity.x, reference.x),
            relativeDifference(chromaticity.y, reference.y),
            relativeDifference(filming[0], filmingReference[0][0]),
            relativeDifference(filming[1], filmingReference[1][0]),
            relativeDifference(filming[2], filmingReference[2][0]),
        ]
        print("""

            [slice2 colour matrices] max relative error \(relativeErrors.max() ?? 0)

            """)
    }

    /// The relative difference of two values.
    private func relativeDifference(_ lhs: Double, _ rhs: Double) -> Double {
        let scale = Swift.max(abs(lhs), abs(rhs))
        guard scale > 0 else { return 0 }
        return abs(lhs - rhs) / scale
    }
}
