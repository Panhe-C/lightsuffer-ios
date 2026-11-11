//
//  GrainCounterTests.swift
//  light suffer胶片 — iOS app
//
//  The statistical validation of the **counter based** grain: the pure Swift
//  reference of the GPU path (``FilmGrainPlan``) against the grain of the
//  CPU reference (``Grain``) and against the upstream.
//
//  The GPU cannot draw from a sequential stream (the order of the pixels is
//  not defined there), so the GPU port draws the same variates from a
//  **counter based** generator (``FilmCounterRandom``).  The two grains are
//  not bit identical — they cannot be — but they must draw from the **same
//  distributions**: the validation compares the summary statistics of the
//  fields with the honest statistical gate of the slice 6 (the Bonferroni
//  corrected Student t quantile of §3.4 of `docs/PORTING.md`).
//
//  The gate is **not** loosened: the family of the comparisons grows by the
//  comparisons of this test, which makes the critical value `k` larger
//  (i.e. the gate tighter).  The number of realisations of the port is six
//  (the upstream averages twelve): the tolerance of the gate accounts for
//  it (`k · σ · sqrt(1/m + 1/m)`), so the comparison stays honest — six
//  realisations are enough here because the two implementations are
//  compared on the *same* pixels.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class GrainCounterTests: XCTestCase {

    /// The seeds of the port used by the validation.
    ///
    /// They are the first seeds of the seed list of the existing grain
    /// validation, so that the two fields are compared on the same
    /// realisations of the distribution.
    private let portSeeds: [UInt64] = [
        0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6,
    ]

    /// The counter based grain of the GPU draws from the same distribution
    /// as the grain of the CPU reference.
    ///
    /// Two comparisons are made, with the same gate:
    ///
    /// * the counter based grain against the grain of the CPU reference: the
    ///   two implementations must be indistinguishable (the spread of the
    ///   upstream is the scale of the difference, because the two draw from
    ///   the same distribution),
    /// * the counter based grain against the upstream: the same comparison
    ///   as the one of the existing grain validation.
    func testTheCounterBasedGrainMatchesTheCPUGrain() throws {
        let fixture = try slice6Fixture()
        let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)
        let lags = try XCTUnwrap(fixture["lags"]?.doubles).map { Int($0) }
        let quantileLevels = try XCTUnwrap(fixture["quantiles"]?.doubles)
        let upstreamSeeds = try XCTUnwrap(fixture["seeds"]?.arrayElements).count

        // The family of the comparisons: the family of the slice 6 and the
        // comparisons of this test (the gate is *not* loosened: the family
        // grows, so the critical value grows).
        var family = try slice6FamilySize(fixture)
        for entry in cases {
            family += entry["grain"]?["aggregate"]?.entryCount ?? 0
        }
        let gate = StatisticalGate(
            comparisons: family,
            upstreamSeeds: upstreamSeeds,
            portSeeds: portSeeds.count
        )

        var cpuComparisons: [StatisticComparison] = []
        var upstreamComparisons: [StatisticComparison] = []

        for entry in cases {
            let id = try XCTUnwrap(entry["id"]?.string)
            let params = try slice6Params(entry)
            let image = try slice6Image(fixture, kind: try slice6ImageKind(entry))
            let film = try cachedProfile(stock: try XCTUnwrap(entry["film"]?.string))

            // The developed densities of the negative (the grain replaces
            // them, so the field of the effect is the grain minus the
            // densities).
            var plain = params
            plain.filmRender.grain.active = false
            let reference = try FilmPipeline(params: plain).process(rgbIn: image)
            let density = reference.cmyFilm.data

            let pixelSizeUM = Halation.pixelSizeUM(
                filmFormatMM: params.camera.filmFormatMM,
                width: image.width,
                height: image.height
            )
            let normalised = DensityCurves.normalized(film.data.densityCurves)
            let grainPlan = FilmGrainPlan.build(
                grain: params.filmRender.grain, film: film, pixelSizeUM: pixelSizeUM
            )

            // The two realisations of the grain.
            var cpuRuns: [[String: Double]] = []
            var counterRuns: [[String: Double]] = []
            for seed in portSeeds {
                let cpu = Grain.apply(
                    densityCMY: density,
                    width: image.width,
                    height: image.height,
                    pixelSizeUM: pixelSizeUM,
                    grain: params.filmRender.grain,
                    densityCurves: normalised,
                    densityCurvesLayers: film.data.densityCurvesLayers,
                    positiveFilm: film.info.type == .positive,
                    seed: seed
                )
                let counter = grainPlan.apply(
                    densityCMY: density,
                    width: image.width,
                    height: image.height,
                    seed: seed
                )
                cpuRuns.append(fieldStatistics(
                    subtract(cpu, density),
                    width: image.width,
                    height: image.height,
                    lags: lags,
                    quantileLevels: quantileLevels
                ).asDictionary(lags: lags, quantileLevels: quantileLevels))
                counterRuns.append(fieldStatistics(
                    subtract(counter, density),
                    width: image.width,
                    height: image.height,
                    lags: lags,
                    quantileLevels: quantileLevels
                ).asDictionary(lags: lags, quantileLevels: quantileLevels))
            }
            let cpuStatistics = averageStatistics(cpuRuns)
            let counterStatistics = averageStatistics(counterRuns)

            // The aggregate of the upstream: the scale of the spread.
            let aggregate = try XCTUnwrap(entry["grain"]?["aggregate"])

            for (key, value) in counterStatistics {
                let upstream = try XCTUnwrap(aggregate[key])
                let upstreamMean = try XCTUnwrap(upstream["mean"]?.double)
                let upstreamStd = try XCTUnwrap(upstream["std"]?.double)
                let cpuValue = try XCTUnwrap(cpuStatistics[key])

                // The comparison with the grain of the CPU reference.
                let scale = Swift.max(gate.scale(upstreamStd: upstreamStd), 1e-300)
                let cpuDeviation = abs(value - cpuValue)
                let cpuTolerance = gate.k * scale
                let cpuZ = cpuDeviation / scale
                cpuComparisons.append(StatisticComparison(
                    caseID: id,
                    statistic: key,
                    port: value,
                    upstreamMean: cpuValue,
                    upstreamStd: upstreamStd,
                    samplerDifference: 0,
                    z: cpuZ,
                    singleDrawZ: cpuZ,
                    tolerance: cpuTolerance,
                    statisticalTolerance: cpuTolerance,
                    belowResolution: false
                ))
                XCTAssertLessThanOrEqual(
                    cpuDeviation,
                    cpuTolerance,
                    "\(id): the grain statistic \(key): the deviation "
                        + "\(cpuDeviation) between the counter based grain and the "
                        + "grain of the CPU is above the tolerance \(cpuTolerance) "
                        + "(z = \(cpuZ))"
                )

                // The comparison with the upstream.  The upstream default
                // path draws from the exact SciPy generators, while the
                // port (and the counter based grain) reproduces the *fast*
                // kernels: the fixture measures that difference explicitly
                // (the `aggregate` and the `fast_aggregate` of the case), and
                // it is added to the tolerance in quadrature, exactly like
                // the existing grain validation does.
                let fastAggregate = try XCTUnwrap(entry["grain"]?["fast_aggregate"])
                let fast = try XCTUnwrap(fastAggregate[key])
                let fastMean = try XCTUnwrap(fast["mean"]?.double)
                let samplerDifference = abs(upstreamMean - fastMean)
                let upstreamDeviation = abs(value - upstreamMean)
                let upstreamTolerance = (
                    (gate.k * scale) * (gate.k * scale) + samplerDifference * samplerDifference
                ).squareRoot()
                let upstreamZ = upstreamDeviation / scale
                upstreamComparisons.append(StatisticComparison(
                    caseID: id,
                    statistic: key,
                    port: value,
                    upstreamMean: upstreamMean,
                    upstreamStd: upstreamStd,
                    samplerDifference: samplerDifference,
                    z: upstreamZ,
                    singleDrawZ: upstreamZ,
                    tolerance: upstreamTolerance,
                    statisticalTolerance: gate.k * scale,
                    belowResolution: false
                ))
                XCTAssertLessThanOrEqual(
                    upstreamDeviation,
                    upstreamTolerance,
                    "\(id): the grain statistic \(key): the deviation "
                        + "\(upstreamDeviation) between the counter based grain and "
                        + "the upstream is above the tolerance \(upstreamTolerance) "
                        + "(z = \(upstreamZ), the upstream mean \(upstreamMean) +- "
                        + "\(upstreamStd))"
                )
            }
        }

        printStatisticalSummary(
            title: "slice6 grain (the counter based generator against the CPU grain)",
            reference: "the grain of the CPU reference (the same distribution)",
            gate: gate,
            comparisons: cpuComparisons,
            samplerDifference: false
        )
        printStatisticalSummary(
            title: "slice6 grain (the counter based generator against the upstream)",
            reference: "the upstream (the fast samplers and the default ones)",
            gate: gate,
            comparisons: upstreamComparisons,
            samplerDifference: false
        )
    }

    /// The counter based generator is a pure function of its counter.
    ///
    /// The order of the pixels must not change the field: the property is
    /// what makes the GPU path possible.
    func testTheCounterBasedGrainIsOrderIndependent() throws {
        let fixture = try slice6Fixture()
        let entry = try XCTUnwrap(fixture["cases"]?.arrayElements?.first)
        let params = try slice6Params(entry)
        let image = try slice6Image(fixture, kind: try slice6ImageKind(entry))
        let film = try cachedProfile(stock: try XCTUnwrap(entry["film"]?.string))

        var plain = params
        plain.filmRender.grain.active = false
        let density = try FilmPipeline(params: plain).process(rgbIn: image).cmyFilm.data
        let pixelSizeUM = Halation.pixelSizeUM(
            filmFormatMM: params.camera.filmFormatMM,
            width: image.width,
            height: image.height
        )
        let plan = FilmGrainPlan.build(
            grain: params.filmRender.grain, film: film, pixelSizeUM: pixelSizeUM
        )
        let first = plan.apply(
            densityCMY: density, width: image.width, height: image.height, seed: 0x1234
        )
        let second = plan.apply(
            densityCMY: density, width: image.width, height: image.height, seed: 0x1234
        )
        XCTAssertEqual(first, second, "the counter based grain is reproducible")

        let other = plan.apply(
            densityCMY: density, width: image.width, height: image.height, seed: 0x5678
        )
        XCTAssertNotEqual(first, other, "another seed gives another grain")
    }
}
