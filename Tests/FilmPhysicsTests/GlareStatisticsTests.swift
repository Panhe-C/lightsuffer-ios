//
//  GlareStatisticsTests.swift
//  light suffer胶片 — iOS app
//
//  The statistical validation of the glare of the print (the slice 6).
//
//  The glare is a stochastic effect: the upstream draws it from the
//  *unseeded* global NumPy random state, so it is not reproducible at all
//  upstream.  The port draws it from its own seeded generator; the
//  validation compares the summary statistics of the glare with the ones of
//  the upstream, over several upstream seeds.
//
//  The comparison is gated by the honest statistical gate of
//  ``StatisticalGate``: the tolerance is the measured spread of the upstream
//  times the critical value of a Bonferroni corrected Student t test, with
//  no relative and no absolute tolerance of its own.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class GlareStatisticsTests: XCTestCase {

    /// The seeds of the port used by the validation.
    ///
    /// The port is deterministic for a given seed; the validation averages
    /// the statistics of a few seeds, so that the comparison with the
    /// upstream is not dominated by the sampling noise of a single
    /// realisation.
    private let portSeeds: [UInt64] = [
        0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6,
        0xA7, 0xB8, 0xC9, 0xDA, 0xEB, 0xFC,
    ]

    // MARK: - The statistics

    /// The glare of the port reproduces the statistics of the upstream.
    ///
    /// The glare of the upstream is a lognormal field (the exact
    /// distribution the port draws), so the comparison needs no exception:
    /// the port implements the algorithm of the upstream.
    func testGlareMatchesTheUpstreamStatistics() throws {
        let fixture = try slice6Fixture()
        let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)
        let lags = try XCTUnwrap(fixture["lags"]?.doubles).map { Int($0) }
        let quantileLevels = try XCTUnwrap(fixture["quantiles"]?.doubles)
        let upstreamSeeds = try XCTUnwrap(fixture["seeds"]?.arrayElements).count

        // The gate of the whole family of the slice 6 (the grain against the
        // two references and the glare against the one).
        let gate = StatisticalGate(
            comparisons: try slice6FamilySize(fixture),
            upstreamSeeds: upstreamSeeds,
            portSeeds: portSeeds.count
        )

        var comparisons: [StatisticComparison] = []

        for entry in cases {
            let id = try XCTUnwrap(entry["id"]?.string)
            let applicable = try XCTUnwrap(entry["glare"]?["applicable"]?.bool)
            guard applicable else {
                // The upstream does not apply any glare to a directly
                // scanned film.
                continue
            }
            let params = try slice6Params(entry)
            let image = try slice6Image(fixture, kind: try slice6ImageKind(entry))

            // --- the statistics of the port, over a few seeds -----------
            let runs = try portFieldStatistics(
                params: params,
                image: image,
                effect: .glare,
                seeds: portSeeds,
                lags: lags,
                quantileLevels: quantileLevels
            )
            let statistics = averageStatistics(runs)

            // --- the comparison with the upstream ----------------------
            let aggregate = try XCTUnwrap(entry["glare"]?["aggregate"])
            for (key, value) in statistics {
                let expected = try XCTUnwrap(aggregate[key])
                let comparison = compareStatistic(
                    caseID: id,
                    statistic: key,
                    port: value,
                    upstream: expected,
                    samplerDifference: 0,
                    gate: gate
                )
                comparisons.append(comparison)
                XCTAssertLessThanOrEqual(
                    comparison.deviation,
                    comparison.tolerance,
                    "\(id): the glare statistic \(key): the deviation "
                    + "\(comparison.deviation) is above the tolerance "
                    + "\(comparison.tolerance) (z = \(comparison.z))"
                )
            }
        }

        printStatisticalSummary(
            title: "slice6 glare",
            reference: "the upstream (the lognormal field of the veiling glare)",
            gate: gate,
            comparisons: comparisons,
            samplerDifference: false
        )
    }

    // MARK: - The determinism

    /// A fixed seed gives the same image twice.
    func testAFixedSeedIsReproducible() throws {
        let fixture = try slice6Fixture()
        let entry = try XCTUnwrap(
            fixture["cases"]?.arrayElements?.first { entry in
                entry["glare"]?["applicable"]?.bool == true
            }
        )
        var params = try slice6Params(entry)
        params.filmRender.grain.active = false
        params.printRender.glare.active = true
        params.stochastic.seed = 0x1234_5678
        let image = try slice6Image(fixture, kind: try slice6ImageKind(entry))

        let first = try FilmPipeline(params: params).process(rgbIn: image)
        let second = try FilmPipeline(params: params).process(rgbIn: image)
        XCTAssertEqual(first.rgbOut.data, second.rgbOut.data, "the glare is reproducible")
    }

    /// The glare is not applied to a directly scanned film.
    ///
    /// Upstream reference: `spektrafilm.runtime.stages.scanning.ScanningStage._density_to_rgb`
    /// (the `io.scan_film` branch sets the glare to `None`).
    func testTheGlareIsNotAppliedToADirectScan() throws {
        let fixture = try slice6Fixture()
        let entry = try XCTUnwrap(
            fixture["cases"]?.arrayElements?.first { entry in
                entry["scan_film"]?.bool == true
            }
        )
        var params = try slice6Params(entry)
        params.filmRender.grain.active = false
        params.printRender.glare.active = true
        let image = try slice6Image(fixture, kind: try slice6ImageKind(entry))

        let withGlare = try FilmPipeline(params: params).process(rgbIn: image)
        params.printRender.glare.active = false
        let withoutGlare = try FilmPipeline(params: params).process(rgbIn: image)
        XCTAssertEqual(withGlare.rgbOut.data, withoutGlare.rgbOut.data)
    }
}
