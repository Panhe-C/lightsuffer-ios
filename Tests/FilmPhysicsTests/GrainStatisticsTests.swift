//
//  GrainStatisticsTests.swift
//  light suffer胶片 — iOS app
//
//  The statistical validation of the grain of the negative (the slice 6).
//
//  The grain is a stochastic effect: the port cannot reproduce the upstream
//  bit for bit (the upstream draws from the legacy NumPy random state), so
//  the validation compares the *summary statistics* of the grain field of
//  the port with the ones of the upstream, over several upstream seeds.
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

final class GrainStatisticsTests: XCTestCase {

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

    /// The statistics of the grain that the model difference of the samplers
    /// explains.
    ///
    /// The port reproduces the *fast* kernels of the upstream
    /// (`spektrafilm.utils.fast_stats`), which approximate the exact SciPy
    /// generators of the upstream default path by normal approximations.  The
    /// fixture measures that difference explicitly (the `aggregate` and the
    /// `fast_aggregate` of every case), and it explains the deviation of
    /// these four statistics: they are above the statistical gate of the
    /// comparison with the upstream default path, but the deviation stays
    /// below the tolerance that carries the measured sampler difference.
    ///
    /// The list is explicit on purpose: any change of the port (another seed
    /// set, another algorithm) that moves a statistic across the gate fails
    /// the test, so that the model difference is reviewed and the list
    /// updated.
    private let modelDifferenceExceptions: Set<String> = [
        "ultramax_400__flat_ev_plus2/mean_0",
        "ultramax_400__flat_ev_plus2/q25",
        "ultramax_400__flat_ev_plus2/q50",
        "ultramax_400__flat_ev_plus2/q75",
    ]

    // MARK: - The statistics

    /// The grain of the port reproduces the statistics of the upstream.
    ///
    /// The comparison is made against the two references of the fixture:
    ///
    /// * the **fast** upstream path (`settings.use_fast_stats = True`),
    ///   which draws the Poisson and the binomial variates from the kernels
    ///   of `spektrafilm.utils.fast_stats` — the ones the port reproduces,
    ///   so this is the *algorithm* gate of the port: no exception is
    ///   allowed there,
    /// * the **default** upstream path, which draws them from the exact
    ///   SciPy generators.  The port is an approximation of that path (the
    ///   fast kernels replace the exact samplers by normal approximations),
    ///   so the difference between the two references — which the fixture
    ///   measures explicitly — is added to the tolerance, in quadrature.
    func testGrainMatchesTheUpstreamStatistics() throws {
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

        var fastComparisons: [StatisticComparison] = []
        var defaultComparisons: [StatisticComparison] = []

        for entry in cases {
            let id = try XCTUnwrap(entry["id"]?.string)
            let params = try slice6Params(entry)
            let image = try slice6Image(fixture, kind: try slice6ImageKind(entry))

            // --- the statistics of the port, over a few seeds -----------
            let runs = try portFieldStatistics(
                params: params,
                image: image,
                effect: .grain,
                seeds: portSeeds,
                lags: lags,
                quantileLevels: quantileLevels
            )
            let statistics = averageStatistics(runs)

            // --- the comparison with the upstream ----------------------
            let fastAggregate = try XCTUnwrap(entry["grain"]?["fast_aggregate"])
            let aggregate = try XCTUnwrap(entry["grain"]?["aggregate"])
            for (key, value) in statistics {
                let fast = try XCTUnwrap(fastAggregate[key])
                let comparison = compareStatistic(
                    caseID: id,
                    statistic: key,
                    port: value,
                    upstream: fast,
                    samplerDifference: 0,
                    gate: gate
                )
                fastComparisons.append(comparison)
                XCTAssertLessThanOrEqual(
                    comparison.deviation,
                    comparison.tolerance,
                    "\(id): the grain statistic \(key) (the fast samplers): "
                    + "the deviation \(comparison.deviation) is above the "
                    + "tolerance \(comparison.tolerance) (z = \(comparison.z))"
                )

                // The default path: the exact SciPy generators, i.e. the
                // upstream without the normal approximation of the fast
                // kernels.  The difference between the two references is
                // measured by the fixture itself.
                let expected = try XCTUnwrap(aggregate[key])
                let fastMean = try XCTUnwrap(fast["mean"]?.double)
                let upstreamMean = try XCTUnwrap(expected["mean"]?.double)
                let defaultComparison = compareStatistic(
                    caseID: id,
                    statistic: key,
                    port: value,
                    upstream: expected,
                    samplerDifference: abs(upstreamMean - fastMean),
                    gate: gate
                )
                defaultComparisons.append(defaultComparison)
                XCTAssertLessThanOrEqual(
                    defaultComparison.deviation,
                    defaultComparison.tolerance,
                    "\(id): the grain statistic \(key) (the default samplers): "
                    + "the deviation \(defaultComparison.deviation) is above "
                    + "the tolerance \(defaultComparison.tolerance) "
                    + "(z = \(defaultComparison.z))"
                )
            }
        }

        printStatisticalSummary(
            title: "slice6 grain",
            reference: "the upstream fast samplers (the kernels the port reproduces)",
            gate: gate,
            comparisons: fastComparisons,
            samplerDifference: false
        )
        printStatisticalSummary(
            title: "slice6 grain",
            reference: "the upstream default samplers (the exact SciPy generators)",
            gate: gate,
            comparisons: defaultComparisons,
            samplerDifference: true
        )

        // The model difference of the samplers is the only exception of the
        // slice 6, and it is an explicit list: the statistics above the
        // statistical gate must be exactly the ones the fixture explains.
        let above = Set(
            defaultComparisons
                .filter { $0.deviation > $0.statisticalTolerance }
                .map { "\($0.caseID)/\($0.statistic)" }
        )
        XCTAssertEqual(
            above, modelDifferenceExceptions,
            "the statistics above the statistical gate of the comparison with "
            + "the upstream default samplers changed: the model difference of "
            + "the samplers must be reviewed"
        )
    }

    // MARK: - The exact samplers

    /// The exact samplers of the port match the default upstream path.
    ///
    /// The **exact** samplers (the inversion of the cumulative
    /// distribution, started at the mode of the distribution) draw from the
    /// very same distributions as the SciPy generators of the default path
    /// of the upstream (`scipy.stats.poisson.rvs` and
    /// `scipy.stats.binom.rvs`).  The comparison is therefore made with the
    /// **default** aggregate of the fixture, with the plain statistical gate
    /// and **no allowance at all**.
    ///
    /// This is the counterpart of the comparison of the fast samplers: the
    /// fast samplers reproduce the upstream fast path, whose inversion
    /// underflows for the dense layers of the emulsion (see §3.4 of
    /// `docs/PORTING.md`), and the exact samplers reproduce the upstream
    /// default path.
    func testTheExactSamplersMatchTheUpstreamDefaultStatistics() throws {
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

        var comparisons: [StatisticComparison] = []

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
            let density = try FilmPipeline(params: plain).process(rgbIn: image).cmyFilm.data

            let pixelSizeUM = Halation.pixelSizeUM(
                filmFormatMM: params.camera.filmFormatMM,
                width: image.width,
                height: image.height
            )
            let normalised = DensityCurves.normalized(film.data.densityCurves)

            // The realisations of the grain, with the exact samplers.
            var runs: [[String: Double]] = []
            for seed in portSeeds {
                let grain = Grain.apply(
                    densityCMY: density,
                    width: image.width,
                    height: image.height,
                    pixelSizeUM: pixelSizeUM,
                    grain: params.filmRender.grain,
                    densityCurves: normalised,
                    densityCurvesLayers: film.data.densityCurvesLayers,
                    positiveFilm: film.info.type == .positive,
                    seed: seed,
                    sampler: .exact
                )
                runs.append(fieldStatistics(
                    subtract(grain, density),
                    width: image.width,
                    height: image.height,
                    lags: lags,
                    quantileLevels: quantileLevels
                ).asDictionary(lags: lags, quantileLevels: quantileLevels))
            }
            let statistics = averageStatistics(runs)

            // The **default** aggregate of the upstream (the exact SciPy
            // generators): the plain statistical gate, with no allowance.
            let aggregate = try XCTUnwrap(entry["grain"]?["aggregate"])
            for (key, value) in statistics {
                let comparison = compareStatistic(
                    caseID: id,
                    statistic: key,
                    port: value,
                    upstream: try XCTUnwrap(aggregate[key]),
                    samplerDifference: 0,
                    gate: gate
                )
                comparisons.append(comparison)
                XCTAssertLessThanOrEqual(
                    comparison.deviation,
                    comparison.tolerance,
                    "\(id): the grain statistic \(key) (the exact samplers "
                        + "against the default upstream path): the deviation "
                        + "\(comparison.deviation) is above the tolerance "
                        + "\(comparison.tolerance) (z = \(comparison.z))"
                )
            }
        }

        printStatisticalSummary(
            title: "slice6 grain (the exact samplers of the CPU against the upstream)",
            reference: "the upstream default samplers (the exact SciPy generators)",
            gate: gate,
            comparisons: comparisons,
            samplerDifference: false
        )
    }

    // MARK: - The determinism

    /// A fixed seed gives the same image twice.
    func testAFixedSeedIsReproducible() throws {
        let fixture = try slice6Fixture()
        let entry = try XCTUnwrap(fixture["cases"]?.arrayElements?.first)
        var params = try slice6Params(entry)
        params.filmRender.grain.active = true
        params.printRender.glare.active = true
        params.stochastic.seed = 0x1234_5678
        let image = try slice6Image(fixture, kind: try slice6ImageKind(entry))

        let first = try FilmPipeline(params: params).process(rgbIn: image)
        let second = try FilmPipeline(params: params).process(rgbIn: image)

        XCTAssertEqual(first.cmyFilm.data, second.cmyFilm.data, "the grain is reproducible")
        XCTAssertEqual(first.rgbOut.data, second.rgbOut.data, "the glare is reproducible")
        XCTAssertNotEqual(first.cmyFilm.data, first.logEFilm.data)
    }

    /// Another seed gives another grain (the port is not frozen).
    func testAnotherSeedGivesAnotherGrain() throws {
        let fixture = try slice6Fixture()
        let entry = try XCTUnwrap(fixture["cases"]?.arrayElements?.first)
        var params = try slice6Params(entry)
        params.filmRender.grain.active = true
        params.printRender.glare.active = false
        let image = try slice6Image(fixture, kind: try slice6ImageKind(entry))

        params.stochastic.seed = 1
        let first = try FilmPipeline(params: params).process(rgbIn: image)
        params.stochastic.seed = 2
        let second = try FilmPipeline(params: params).process(rgbIn: image)

        XCTAssertNotEqual(first.cmyFilm.data, second.cmyFilm.data)
    }

    // MARK: - The performance

    /// The grain of a 1024 x 1024 image is fast enough.
    ///
    /// The grain draws two random variates per pixel and per emulsion layer
    /// (nine layers for the three channels), so the cost is linear in the
    /// number of pixels.  The test prints the elapsed time, so that the
    /// release build can be measured with
    /// `swift test -c release --filter testTheGrainOfALargeImageIsFast`.
    func testTheGrainOfALargeImageIsFast() throws {
        let width = 1024
        let height = 1024
        // A synthetic density field: a vertical ramp of densities.
        var density = [Double](repeating: 0, count: width * height * 3)
        for row in 0..<height {
            let value = 0.2 + 0.6 * Double(row) / Double(height)
            for column in 0..<width {
                for channel in 0..<3 {
                    density[(row * width + column) * 3 + channel] = value
                }
            }
        }

        let film = try cachedProfile(stock: "kodak_portra_400")
        let normalized = DensityCurves.normalized(film.data.densityCurves)
        // The pixel size of a 35 mm frame scanned at 1024 pixels.
        let pixelSizeUM = 35.0 * 1000.0 / Double(max(width, height))

        let start = Date()
        let grain = Grain.apply(
            densityCMY: density,
            width: width,
            height: height,
            pixelSizeUM: pixelSizeUM,
            grain: GrainParams(),
            densityCurves: normalized,
            densityCurvesLayers: film.data.densityCurvesLayers,
            positiveFilm: false,
            seed: 0x1234_5678
        )
        let elapsed = Date().timeIntervalSince(start)

        // The grain is a stochastic realisation of the density: it is close
        // to the density, with the shot noise of the emulsion.
        var error = 0.0
        for index in 0..<density.count {
            error += abs(grain[index] - density[index])
        }
        let meanError = error / Double(density.count)
        print("")
        print("[slice6 grain] the grain of a \(width)x\(height) image: "
            + "\(elapsed) s, mean deviation \(meanError)")
        print("")
        XCTAssertLessThan(elapsed, 60, "the grain of a 1024 x 1024 image is not a minute long")
        XCTAssertGreaterThan(meanError, 0, "the grain is not a no-op")
    }

    // MARK: - The grain off path

    /// The grain off path is untouched by the port of the grain.
    ///
    /// The reference of the slice 5 was captured with the grain off: the
    /// port still reproduces it tap by tap, and the seed of the stochastic
    /// effects does not change a single bit of the deterministic path.
    func testTheGrainOffPathIsUnchanged() throws {
        let fixture = try JSONValue.load(named: "slice5_spatial")
        let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)
        let image = try XCTUnwrap(fixture["test_image"])
        let size = try XCTUnwrap(image["size"]?.doubles)
        let data = try XCTUnwrap(image["data"]?.flatDoubles)
        let input = RGBImage(width: Int(size[0]), height: Int(size[1]), data: data)

        let film = try ProfileLoader.load(stock: "kodak_portra_400")
        let printProfile = try ProfileLoader.load(stock: "kodak_portra_endura")

        for entry in cases {
            let id = try XCTUnwrap(entry["id"]?.string)
            var params = try makePipelineParams(
                fixture: entry, film: film, print: printProfile
            )
            params.filmRender.grain.active = false
            params.printRender.glare.active = false
            let taps = try FilmPipeline(params: params).process(rgbIn: input)

            // The same run with another seed: the deterministic path does
            // not depend on the seed of the stochastic effects.
            var other = params
            other.stochastic.seed = 0xDEAD_BEEF
            let otherTaps = try FilmPipeline(params: other).process(rgbIn: input)
            XCTAssertEqual(taps.cmyFilm.data, otherTaps.cmyFilm.data, "\(id): cmy_film")
            XCTAssertEqual(taps.rgbOut.data, otherTaps.rgbOut.data, "\(id): rgb_out")

            // The reference of the slice 5 (the grain was off there).
            if let reference = entry["taps"]?["cmy_film"]?.flatDoubles {
                XCTAssertLessThan(
                    maxAbsoluteDifference(taps.cmyFilm.data, reference),
                    5e-6,
                    "\(id): cmy_film"
                )
            }
        }
    }
}
