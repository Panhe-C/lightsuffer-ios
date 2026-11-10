//
//  CatalogParityTests.swift
//  light suffer胶片 — iOS app
//
//  The parity tests of the slice 4 port: the whole catalogue of the engine
//  (every film × every print medium and the direct scan of every film) is
//  compared with the reference captured from the upstream Python engine.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class CatalogParityTests: XCTestCase {

    /// The gate of the parity: the mean CIEDE2000 of a case must stay below.
    private let meanDeltaEGate = 0.5

    /// The relative tolerance of the comparison with the reference.
    ///
    /// The reference fixtures store the values with seven significant
    /// digits, so the rounding alone is worth about 1e-6 relative.
    private let relativeTolerance = 1e-6

    /// The absolute floor of the comparison with the reference.
    private let absoluteFloor = 1e-9

    /// The tolerance of a comparison with the reference.
    private func tolerance(for expected: Double, produced: Double) -> Double {
        Swift.max(
            relativeTolerance * Swift.max(abs(expected), abs(produced)),
            absoluteFloor
        )
    }

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
        _ reference: [Double],
        _ produced: [Double]
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

    /// The parameters of a catalogue case.
    ///
    /// They are the upstream defaults of `init_params()` with every spatial
    /// and stochastic effect switched off (the grain, the halation, the
    /// glare, the camera and the enlarger diffusion filters, the lens blurs,
    /// the unsharp mask and the auto exposure), the DIR couplers active but
    /// per pixel, the print density curve morph off, the input gamut
    /// compression at its upstream default (`xy`) and the output gamut
    /// compression at its upstream default (`cam16ucs`).
    private func makeParams(
        film: String,
        print printStock: String,
        scanFilm: Bool
    ) throws -> PipelineParams {
        let filmProfile = try XCTUnwrap(try StockCatalog.profile(stock: film))
        let printProfile = try XCTUnwrap(try StockCatalog.profile(stock: printStock))

        var dirCouplers = DirCouplersParams()
        dirCouplers.diffusionSizeUM = 0.0

        // The reference fixtures of the catalogue run without the spatial
        // effects: the halation and the scatter of the negative are off.
        var filmRender = FilmRenderParams(dirCouplers: dirCouplers)
        filmRender.halation.active = false

        return PipelineParams(
            film: filmProfile,
            print: printProfile,
            camera: CameraParams(autoExposure: false),
            filmRender: filmRender,
            scanner: ScannerParams(unsharpMaskSigma: 0, unsharpMaskAmount: 0),
            io: IOParams(scanFilm: scanFilm)
        )
    }

    // MARK: - The digest

    /// The stock specific digest of every case reproduces the reference.
    ///
    /// The reference stores the digest of the upstream engine: the neutral
    /// print filters of the film / paper pair, the DIR coupler chemistry and
    /// the halation baseline of the film.
    func testDigestsMatchTheReference() throws {
        let fixture = try JSONValue.load(named: "slice4_catalog")
        let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)
        XCTAssertEqual(cases.count, 148, "the reference holds the whole catalogue")

        var checked = 0
        for entry in cases {
            let id = try XCTUnwrap(entry["id"]?.string)
            let film = try XCTUnwrap(entry["film"]?.string)
            let printStock = try XCTUnwrap(entry["print"]?.string)
            let mode = try XCTUnwrap(entry["mode"]?.string)
            let reference = try XCTUnwrap(entry["digest"])

            let params = try makeParams(
                film: film,
                print: printStock,
                scanFilm: mode == "scan_film"
            )
            let digest = Digest.digest(params)

            // --- the neutral print filters ------------------------------
            let referenceCC = try XCTUnwrap(reference["neutral_filters_cc"]?.doubles)
            let producedCC = [
                digest.enlarger.cFilterNeutral,
                digest.enlarger.mFilterNeutral,
                digest.enlarger.yFilterNeutral,
            ]
            for index in 0..<3 {
                XCTAssertLessThanOrEqual(
                    abs(producedCC[index] - referenceCC[index]),
                    tolerance(for: referenceCC[index], produced: producedCC[index]),
                    "\(id): the neutral print filter \(index)"
                )
            }

            // --- the DIR coupler chemistry --------------------------------
            let referenceCouplers = try XCTUnwrap(reference["dir_couplers"])
            let referenceGammas = [
                try XCTUnwrap(referenceCouplers["gamma_samelayer_rgb"]?.doubles),
                try XCTUnwrap(referenceCouplers["gamma_interlayer_r_to_gb"]?.doubles),
                try XCTUnwrap(referenceCouplers["gamma_interlayer_g_to_rb"]?.doubles),
                try XCTUnwrap(referenceCouplers["gamma_interlayer_b_to_rg"]?.doubles),
            ]
            let producedGammas = [
                digest.filmRender.dirCouplers.gammaSamelayerRGB,
                digest.filmRender.dirCouplers.gammaInterlayerRToGB,
                digest.filmRender.dirCouplers.gammaInterlayerGToRB,
                digest.filmRender.dirCouplers.gammaInterlayerBToRG,
            ]
            for group in 0..<4 {
                for index in 0..<referenceGammas[group].count {
                    XCTAssertLessThanOrEqual(
                        abs(producedGammas[group][index] - referenceGammas[group][index]),
                        tolerance(
                            for: referenceGammas[group][index],
                            produced: producedGammas[group][index]
                        ),
                        "\(id): the DIR coupler gamma \(group).\(index)"
                    )
                }
            }

            // --- the halation baseline -----------------------------------
            let referenceHalation = try XCTUnwrap(reference["halation"])
            let referenceSigma = try XCTUnwrap(
                referenceHalation["halation_first_sigma_um"]?.doubles
            )
            let referenceStrength = try XCTUnwrap(
                referenceHalation["halation_strength"]?.doubles
            )
            for index in 0..<3 {
                XCTAssertLessThanOrEqual(
                    abs(digest.filmRender.halation.halationFirstSigmaUM[index] - referenceSigma[index]),
                    tolerance(
                        for: referenceSigma[index],
                        produced: digest.filmRender.halation.halationFirstSigmaUM[index]
                    ),
                    "\(id): the halation sigma \(index)"
                )
                XCTAssertLessThanOrEqual(
                    abs(digest.filmRender.halation.halationStrength[index] - referenceStrength[index]),
                    tolerance(
                        for: referenceStrength[index],
                        produced: digest.filmRender.halation.halationStrength[index]
                    ),
                    "\(id): the halation strength \(index)"
                )
            }

            // --- the illuminant of the scanner ----------------------------
            let referenceIlluminant = try XCTUnwrap(reference["scan_illuminant"]?.string)
            let expectedIlluminant = mode == "scan_film"
                ? params.film.info.viewingIlluminant
                : params.print.info.viewingIlluminant
            XCTAssertEqual(
                expectedIlluminant,
                referenceIlluminant,
                "\(id): the illuminant of the scanner"
            )

            checked += 1
        }
        print("[catalogue parity] \(checked) digests match the reference")
    }

    // MARK: - The whole catalogue

    /// Every look of the catalogue reproduces the reference.
    ///
    /// The reference holds the 148 looks of the upstream engine: the 16
    /// colour negatives printed on the 8 print media (128 looks) and the 20
    /// films scanned directly (20 looks).
    func testCatalogueMatchesTheReference() throws {
        let fixture = try JSONValue.load(named: "slice4_catalog")
        let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)
        let input = try makeInput(fixture)
        XCTAssertEqual(cases.count, 148, "the reference holds the whole catalogue")

        struct Row {
            let id: String
            let mean: Double
            let max: Double
        }

        var rows: [Row] = []
        var worstCMYFilm = 0.0

        for entry in cases {
            let id = try XCTUnwrap(entry["id"]?.string)
            let film = try XCTUnwrap(entry["film"]?.string)
            let printStock = try XCTUnwrap(entry["print"]?.string)
            let mode = try XCTUnwrap(entry["mode"]?.string)

            let params = try makeParams(
                film: film,
                print: printStock,
                scanFilm: mode == "scan_film"
            )
            let pipeline = try FilmPipeline(params: params)
            let taps = try pipeline.process(rgbIn: input)

            let referenceRGB = try XCTUnwrap(entry["rgb_out"]?.flatDoubles)
            let producedRGB = taps.rgbOut.data
            XCTAssertEqual(producedRGB.count, referenceRGB.count, "\(id): the image size")

            let error = deltaE(referenceRGB, producedRGB)
            rows.append(Row(id: id, mean: error.mean, max: error.max))

            // The developed densities of the directly scanned films are part
            // of the reference as well.
            if let referenceCMYFilm = entry["cmy_film"]?.flatDoubles {
                let cmyError = maxAbsoluteDifference(taps.cmyFilm.data, referenceCMYFilm)
                worstCMYFilm = Swift.max(worstCMYFilm, cmyError)
                XCTAssertLessThan(cmyError, 5e-6, "\(id): cmy_film")
            }

            XCTAssertLessThan(
                error.mean,
                meanDeltaEGate,
                "\(id): the mean dE2000 of the scanned image is \(error.mean)"
            )
        }

        // --- the table ---------------------------------------------------
        print("")
        print("[catalogue parity] the whole catalogue (148 looks)")
        print("  \(("case").padding(toLength: 62, withPad: " ", startingAt: 0))"
            + "mean dE2000   max dE2000")
        for row in rows {
            print("  \(row.id.padding(toLength: 62, withPad: " ", startingAt: 0))"
                + "\(row.mean)  \(row.max)")
        }

        // --- the summary -------------------------------------------------
        let sorted = rows.sorted { $0.mean > $1.mean }
        let worst = sorted.prefix(10)
        var sum = 0.0
        var maximum = 0.0
        for row in rows {
            sum += row.mean
            maximum = Swift.max(maximum, row.max)
        }
        let average = sum / Double(rows.count)

        print("")
        print("[catalogue parity] summary")
        print("  cases       : \(rows.count)")
        print("  mean dE2000 : \(average) (the average of the per case means)")
        print("  worst mean  : \(sorted[0].mean) (\(sorted[0].id))")
        print("  worst max   : \(maximum)")
        print("  cmy_film    : max abs error \(worstCMYFilm) (the direct scans)")
        print("  the ten worst cases:")
        for row in worst {
            print("    \(row.id)  mean \(row.mean)  max \(row.max)")
        }
        print("")

        XCTAssertLessThan(average, meanDeltaEGate, "the average mean dE2000")
    }
}
