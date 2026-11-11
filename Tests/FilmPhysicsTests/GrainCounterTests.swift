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
//  The comparisons of this test are:
//
//  1. the counter based grain against the grain of the CPU reference: the
//     two implementations must be indistinguishable (the spread of the
//     upstream is the scale of the difference, because the two draw from
//     the same distribution),
//  2. the counter based grain against the **fast** upstream path (the
//     algorithm the port reproduces): the *algorithm* gate of the port, with
//     **no allowance** at all,
//  3. the counter based grain against the **default** upstream path (the
//     exact SciPy generators): the comparison is reported **raw** (no
//     allowance: the deviations of the two samplers are a real difference of
//     the two upstream paths, see §3.4 of `docs/PORTING.md`) and
//     **adjusted** (the measured difference between the two upstream paths
//     is added to the tolerance in quadrature),
//  4. the counter based grain drawn with the **exact** samplers against the
//     **default** upstream path: the comparison is the plain statistical
//     gate, with **no allowance** — the exact samplers draw from the very
//     same distributions as the SciPy generators of the upstream.
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

    /// The statistics of the counter based grain that the difference of the
    /// two upstream samplers explains.
    ///
    /// The port reproduces the *fast* kernels of the upstream
    /// (`spektrafilm.utils.fast_stats`), whose inversion of the cumulative
    /// distribution **underflows** for the dense layers of the emulsion (see
    /// §3.4 of `docs/PORTING.md`): the fast path develops every particle
    /// of the dense layers, and the grain is therefore systematically denser
    /// than the one of the default path (the exact SciPy generators).
    ///
    /// The list is explicit on purpose: any change of the port (another seed
    /// set, another algorithm) that moves a statistic across the gate fails
    /// the test, so that the difference of the samplers is reviewed.
    private let samplerDifferenceExceptions: Set<String> = [
        "ultramax_400__flat_ev_plus2/mean_0",
        "ultramax_400__flat_ev_plus2/q25",
        "ultramax_400__flat_ev_plus2/q50",
    ]

    /// The counter based grain of the GPU draws from the same distribution
    /// as the grain of the CPU.
    ///
    /// The comparisons are described at the top of the file: the algorithm
    /// gate against the fast upstream path (no allowance), the raw and the
    /// adjusted comparisons against the default upstream path, and the
    /// comparison of the exact samplers against the default upstream path
    /// (no allowance).
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
            family += entry["grain"]?["fast_aggregate"]?.entryCount ?? 0
        }
        let gate = StatisticalGate(
            comparisons: family,
            upstreamSeeds: upstreamSeeds,
            portSeeds: portSeeds.count
        )

        var cpuComparisons: [StatisticComparison] = []
        var fastComparisons: [StatisticComparison] = []
        var rawDefaultComparisons: [StatisticComparison] = []
        var defaultComparisons: [StatisticComparison] = []
        var exactComparisons: [StatisticComparison] = []

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

            // The realisations of the grain: the CPU reference (the fast
            // samplers), the counter based reference (the fast samplers) and
            // the counter based reference (the exact samplers).
            var cpuRuns: [[String: Double]] = []
            var counterRuns: [[String: Double]] = []
            var exactRuns: [[String: Double]] = []
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
                let exact = grainPlan.apply(
                    densityCMY: density,
                    width: image.width,
                    height: image.height,
                    seed: seed,
                    sampler: .exact
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
                exactRuns.append(fieldStatistics(
                    subtract(exact, density),
                    width: image.width,
                    height: image.height,
                    lags: lags,
                    quantileLevels: quantileLevels
                ).asDictionary(lags: lags, quantileLevels: quantileLevels))
            }
            let cpuStatistics = averageStatistics(cpuRuns)
            let counterStatistics = averageStatistics(counterRuns)
            let exactStatistics = averageStatistics(exactRuns)

            // The aggregates of the upstream: the scale of the spread.
            let aggregate = try XCTUnwrap(entry["grain"]?["aggregate"])
            let fastAggregate = try XCTUnwrap(entry["grain"]?["fast_aggregate"])

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

                // The comparison with the **fast** upstream path: the
                // algorithm the port reproduces, so the tolerance is the
                // plain statistical gate, with no allowance at all.
                let fast = try XCTUnwrap(fastAggregate[key])
                let fastComparison = compareStatistic(
                    caseID: id,
                    statistic: key,
                    port: value,
                    upstream: fast,
                    samplerDifference: 0,
                    gate: gate
                )
                fastComparisons.append(fastComparison)
                XCTAssertLessThanOrEqual(
                    fastComparison.deviation,
                    fastComparison.tolerance,
                    "\(id): the grain statistic \(key) (the fast samplers): the "
                        + "deviation \(fastComparison.deviation) is above the "
                        + "tolerance \(fastComparison.tolerance) "
                        + "(z = \(fastComparison.z))"
                )

                // The comparison with the **default** upstream path, raw:
                // no allowance at all.  The two upstream paths draw from
                // different distributions (the fast kernels underflow for
                // the dense layers of the emulsion), so the deviation is a
                // real difference of the two paths and not a difference of
                // the realisation.
                let rawComparison = compareStatistic(
                    caseID: id,
                    statistic: key,
                    port: value,
                    upstream: upstream,
                    samplerDifference: 0,
                    gate: gate
                )
                rawDefaultComparisons.append(rawComparison)

                // The same comparison, adjusted: the measured difference
                // between the two upstream paths (the fixture measures it
                // explicitly) is added to the tolerance in quadrature,
                // exactly like the existing grain validation does.
                let fastMean = try XCTUnwrap(fast["mean"]?.double)
                let samplerDifference = abs(upstreamMean - fastMean)
                let upstreamDeviation = abs(value - upstreamMean)
                let upstreamTolerance = (
                    (gate.k * scale) * (gate.k * scale) + samplerDifference * samplerDifference
                ).squareRoot()
                let upstreamZ = upstreamDeviation / scale
                defaultComparisons.append(StatisticComparison(
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

                // The comparison of the **exact** samplers with the default
                // upstream path: the plain statistical gate, with no
                // allowance at all.
                let exactValue = try XCTUnwrap(exactStatistics[key])
                let exactComparison = compareStatistic(
                    caseID: id,
                    statistic: key,
                    port: exactValue,
                    upstream: upstream,
                    samplerDifference: 0,
                    gate: gate
                )
                exactComparisons.append(exactComparison)
                XCTAssertLessThanOrEqual(
                    exactComparison.deviation,
                    exactComparison.tolerance,
                    "\(id): the grain statistic \(key) (the exact samplers "
                        + "against the default upstream path): the deviation "
                        + "\(exactComparison.deviation) is above the tolerance "
                        + "\(exactComparison.tolerance) (z = \(exactComparison.z))"
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
            reference: "the upstream fast samplers (the kernels the port reproduces)",
            gate: gate,
            comparisons: fastComparisons,
            samplerDifference: false
        )
        printStatisticalSummary(
            title: "slice6 grain (the counter based generator against the upstream, raw)",
            reference: "the upstream default samplers (the exact SciPy generators)",
            gate: gate,
            comparisons: rawDefaultComparisons,
            samplerDifference: false
        )
        printStatisticalSummary(
            title: "slice6 grain (the counter based generator against the upstream)",
            reference: "the upstream default samplers (the exact SciPy generators)",
            gate: gate,
            comparisons: defaultComparisons,
            samplerDifference: true
        )
        printStatisticalSummary(
            title: "slice6 grain (the exact samplers against the upstream)",
            reference: "the upstream default samplers (the exact SciPy generators)",
            gate: gate,
            comparisons: exactComparisons,
            samplerDifference: false
        )

        // The statistics above the statistical gate of the **raw** comparison
        // with the default upstream path are the ones the difference of the
        // two upstream samplers explains: the list is explicit, so that any
        // change is reviewed.
        let above = Set(
            rawDefaultComparisons
                .filter { $0.deviation > $0.statisticalTolerance }
                .map { "\($0.caseID)/\($0.statistic)" }
        )
        XCTAssertEqual(
            above, samplerDifferenceExceptions,
            "the statistics above the statistical gate of the raw comparison "
                + "with the upstream default samplers changed: the difference "
                + "of the two upstream samplers must be reviewed"
        )

        // The raw comparison is reported in full: the deviation, the scale
        // (the measured spread of the upstream), the z-score and the list of
        // the statistics above the gate.
        let aboveRaw = rawDefaultComparisons
            .filter { $0.deviation > $0.statisticalTolerance }
            .sorted { $0.z > $1.z }
        let worstRaw = rawDefaultComparisons.max { $0.z < $1.z }
        print("")
        print("[slice6 grain] the counter based grain against the upstream "
            + "default samplers (RAW, no allowance at all)")
        print("  the gate      : |z| <= \(String(format: "%.4f", gate.k))")
        if let worstRaw {
            print("  max |z| = \(String(format: "%.4f", worstRaw.z)) "
                + "(\(worstRaw.caseID) \(worstRaw.statistic)): the deviation "
                + "\(String(format: "%.6g", worstRaw.deviation)), the upstream "
                + "sigma \(String(format: "%.6g", worstRaw.upstreamStd))")
        }
        print("  the statistics above the gate: \(aboveRaw.count)")
        for row in aboveRaw {
            print("    \(row.caseID) \(row.statistic): the deviation "
                + "\(String(format: "%.6g", row.deviation)), the upstream sigma "
                + "\(String(format: "%.6g", row.upstreamStd)), the z-score "
                + "\(String(format: "%.4f", row.z))")
        }
        print("")
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
