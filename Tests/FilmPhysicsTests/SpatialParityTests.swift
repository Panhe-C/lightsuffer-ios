//
//  SpatialParityTests.swift
//  light suffer胶片 — iOS app
//
//  The parity tests of the slice 5 port: the deterministic spatial effects
//  (the highlight boost, the in emulsion scatter, the back reflection
//  halation, the spatial diffusion of the DIR coupler inhibitors, the
//  diffusion filters of the camera and of the enlarger, the lens blurs and
//  the unsharp mask) are compared with the reference captured from the
//  upstream Python engine.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class SpatialParityTests: XCTestCase {

    /// The acceptance gate of the plan: the mean CIEDE2000 of a case.
    private let meanDeltaEGate = 0.5

    /// The tightened gate: the mean CIEDE2000 of a case.
    ///
    /// The port reproduces the upstream kernels exactly (the separable FIR
    /// Gaussian, the Young & van Vliet IIR Gaussian, the Gaussian mixture of
    /// the exponential PSF and the convolution of the diffusion filters), so
    /// the only difference left is the rounding of the seven significant
    /// digits of the fixtures.
    private let meanDeltaETight = 0.01

    /// The tightened gate: the maximum CIEDE2000 of a case.
    private let maxDeltaETight = 0.05

    // MARK: - Helpers

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
    private func deltaE(
        _ reference: [Double], _ produced: [Double]
    ) -> (mean: Double, max: Double) {
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

    /// The camera image of the reference fixture.
    private func makeInput(_ fixture: JSONValue) throws -> RGBImage {
        let image = try XCTUnwrap(fixture["test_image"])
        let size = try XCTUnwrap(image["size"]?.doubles)
        let data = try XCTUnwrap(image["data"]?.flatDoubles)
        return RGBImage(width: Int(size[0]), height: Int(size[1]), data: data)
    }

    // MARK: - The parity

    /// Every spatial effect reproduces the reference of the upstream engine.
    func testSpatialEffectsMatchTheReference() throws {
        let fixture = try JSONValue.load(named: "slice5_spatial")
        let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)
        let input = try makeInput(fixture)
        let film = try ProfileLoader.load(stock: "kodak_portra_400")
        let printProfile = try ProfileLoader.load(stock: "kodak_portra_endura")

        var rows: [(id: String, mean: Double, max: Double, error: Double)] = []

        for entry in cases {
            let id = try XCTUnwrap(entry["id"]?.string)
            let params = try makePipelineParams(
                fixture: entry, film: film, print: printProfile
            )
            let pipeline = try FilmPipeline(params: params)
            let taps = try pipeline.process(rgbIn: input)

            // --- the output image -------------------------------------
            let referenceRGB = try XCTUnwrap(entry["taps"]?["rgb_out"]?.flatDoubles)
            let error = deltaE(referenceRGB, taps.rgbOut.data)
            let rgbError = maxAbsoluteDifference(taps.rgbOut.data, referenceRGB)

            // --- the intermediate taps --------------------------------
            let referenceTaps = try XCTUnwrap(entry["taps"])
            if let reference = referenceTaps["log_e_film"]?.flatDoubles {
                XCTAssertLessThan(
                    maxAbsoluteDifference(taps.logEFilm.data, reference),
                    5e-6,
                    "\(id): log_e_film"
                )
            }
            if let reference = referenceTaps["cmy_film"]?.flatDoubles {
                XCTAssertLessThan(
                    maxAbsoluteDifference(taps.cmyFilm.data, reference),
                    5e-6,
                    "\(id): cmy_film"
                )
            }
            if let reference = referenceTaps["log_e_print"]?.flatDoubles {
                XCTAssertLessThan(
                    maxAbsoluteDifference(taps.logEPrint.data, reference),
                    5e-6,
                    "\(id): log_e_print"
                )
            }

            rows.append((id: id, mean: error.mean, max: error.max, error: rgbError))

            XCTAssertLessThan(error.mean, meanDeltaEGate, "\(id): the mean dE2000")
            XCTAssertLessThan(error.mean, meanDeltaETight, "\(id): the tightened mean dE2000")
            XCTAssertLessThan(error.max, maxDeltaETight, "\(id): the tightened max dE2000")
        }

        // --- the table ---------------------------------------------------
        print("")
        print("[slice5 spatial parity] the spatial effects")
        print("  \(("case").padding(toLength: 28, withPad: " ", startingAt: 0))"
            + "mean dE2000   max dE2000   max abs error")
        for row in rows {
            print("  \(row.id.padding(toLength: 28, withPad: " ", startingAt: 0))"
                + "\(row.mean)  \(row.max)  \(row.error)")
        }
        var worstMean = 0.0
        var worstMax = 0.0
        for row in rows {
            worstMean = Swift.max(worstMean, row.mean)
            worstMax = Swift.max(worstMax, row.max)
        }
        print("  worst mean \(worstMean), worst max \(worstMax)")
        print("")
    }

    // MARK: - The image space helpers

    /// The Gaussian filter of the port reproduces the reference of the
    /// upstream engine.
    ///
    /// The reference holds the separable FIR kernel (below three pixels) and
    /// the Young & van Vliet recursion (above), both with the `reflect`
    /// boundary of SciPy.
    func testGaussianFilterMatchesTheReference() throws {
        let fixture = try JSONValue.load(named: "slice5_spatial")
        let helpers = try XCTUnwrap(fixture["helpers"])

        let width = try XCTUnwrap(helpers["width"]?.int)
        let height = try XCTUnwrap(helpers["height"]?.int)
        let plane = try XCTUnwrap(helpers["plane"]?.doubles)

        for sample in try XCTUnwrap(helpers["gaussians"]?.arrayElements) {
            let sigma = try XCTUnwrap(sample["sigma"]?.double)
            let reference = try XCTUnwrap(sample["filtered"]?.flatDoubles)
            let produced = SpatialEffects.filterPlane(
                plane, width: width, height: height, sigma: sigma
            )
            let error = maxAbsoluteDifference(produced, reference)
            print("[slice5 helpers] the Gaussian filter, sigma \(sigma): max abs error \(error)")
            XCTAssertLessThan(error, 1e-6, "the Gaussian filter of sigma \(sigma)")
        }
    }

    /// The exponential filter of the port reproduces the reference.
    func testExponentialFilterMatchesTheReference() throws {
        let fixture = try JSONValue.load(named: "slice5_spatial")
        let helpers = try XCTUnwrap(fixture["helpers"])

        let width = try XCTUnwrap(helpers["width"]?.int)
        let height = try XCTUnwrap(helpers["height"]?.int)
        let plane = try XCTUnwrap(helpers["plane"]?.doubles)

        for sample in try XCTUnwrap(helpers["exponentials"]?.arrayElements) {
            let decay = try XCTUnwrap(sample["decay"]?.double)
            let reference = try XCTUnwrap(sample["filtered"]?.flatDoubles)
            let produced = SpatialEffects.exponentialFilterPlane(
                plane, width: width, height: height, decayConstant: decay
            )
            let error = maxAbsoluteDifference(produced, reference)
            print("[slice5 helpers] the exponential filter, decay \(decay): max abs error \(error)")
            XCTAssertLessThan(error, 1e-6, "the exponential filter of decay \(decay)")
        }
    }

    /// The reflection of the port reproduces the `reflect` boundary of SciPy.
    func testReflectBoundaryMatchesTheReference() throws {
        let fixture = try JSONValue.load(named: "slice5_spatial")
        let helpers = try XCTUnwrap(fixture["helpers"])
        let reference = try XCTUnwrap(helpers["reflect"]?.doubles)

        var produced: [Double] = []
        for index in -12...12 {
            produced.append(Double(SpatialEffects.reflectIndex(index, 7)))
        }
        let error = maxAbsoluteDifference(produced, reference)
        print("[slice5 helpers] the reflect boundary: max abs error \(error)")
        XCTAssertEqual(error, 0, "the reflection of the port matches the reference")
    }

    /// The point spread functions of the four diffusion filter families
    /// reproduce the reference.
    func testDiffusionFilterPSFsMatchTheReference() throws {
        let fixture = try JSONValue.load(named: "slice5_spatial")
        let entries = try XCTUnwrap(fixture["diffusion_filters"]?.arrayElements)

        for entry in entries {
            let family = try XCTUnwrap(entry["family"]?.string)
            let warmth = try XCTUnwrap(entry["halo_warmth"]?.double)
            let spatialScale = try XCTUnwrap(entry["spatial_scale"]?.double)
            let pixelSizeUM = try XCTUnwrap(entry["pixel_size_um"]?.double)
            let shape = try XCTUnwrap(entry["shape"]?.doubles)
            let reference = try XCTUnwrap(entry["psf"]?.flatDoubles)

            let params = DiffusionFilterParams(
                active: true,
                filterFamily: family,
                strength: 1.0,
                spatialScale: spatialScale,
                haloWarmth: warmth
            )
            guard let kernel = DiffusionFilter.psf(
                shape: Int(shape[0]),
                family: family,
                spatialScale: spatialScale,
                pixelSizeUM: pixelSizeUM,
                haloWarmth: warmth,
                params: params
            ) else {
                XCTFail("\(family): the point spread function was not built")
                continue
            }
            // The fixture stores the kernel in the NumPy order (the channel
            // varies the fastest); the port keeps the channels apart.
            var produced: [Double] = []
            for row in 0..<Int(shape[0]) {
                for column in 0..<Int(shape[1]) {
                    for channel in 0..<3 {
                        produced.append(kernel[channel][row * Int(shape[1]) + column])
                    }
                }
            }
            let error = maxAbsoluteDifference(produced, reference)
            print(
                "[slice5 helpers] the diffusion filter \(family), warmth \(warmth): "
                    + "max abs error \(error)"
            )
            XCTAssertLessThan(error, 1e-6, "the point spread function of \(family)")

            // The scattered fraction of the filter.
            let referenceScatter = try XCTUnwrap(entry["scatter_fraction"]?.double)
            let producedScatter = DiffusionFilter.scatterFraction(
                strength: 1.0, family: family
            )
            XCTAssertEqual(
                producedScatter, referenceScatter, accuracy: 1e-6,
                "\(family): the scattered fraction"
            )

            // The largest decay constant of the bloom group.
            let referenceBloom = try XCTUnwrap(entry["bloom_max_lambda_um"]?.double)
            let producedBloom = DiffusionFilter.bloomMaxLambdaUM(family, params: params)
            XCTAssertEqual(
                producedBloom, referenceBloom, accuracy: 1e-6,
                "\(family): the largest decay constant of the bloom"
            )
        }
    }
}
