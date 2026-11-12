//
//  MetalExactGrainTests.swift
//  light suffer胶片 — iOS app
//
//  The parity tests of the **exact** grain of the Metal port.
//
//  The Metal port has two modes for the variates of the particles of the
//  grain:
//
//  * the **fast** kernels of the upstream (`spektrafilm.utils.fast_stats`),
//    which is the **default** of the port (the algorithm the CPU
//    reference reproduces, and the one the existing parity test
//    validates),
//  * the **exact** samplers (the inversion of the cumulative distribution,
//    around the mode of the distribution), which draw from the very same
//    distributions as the SciPy generators of the **default** path of the
//    upstream.
//
//  The two comparisons of this file are:
//
//  1. the exact grain of the GPU against the **counter based exact**
//     reference of the CPU (`FilmGrainPlan` / `FilmCounterRandom` in exact
//     mode): the two implementations must be indistinguishable — the same
//     statistical gate as the fast path, with the same critical value, the
//     same number of seeds and the same convention,
//  2. the exact grain of the GPU against the **upstream default** aggregate
//     (the exact SciPy generators of the upstream): the plain statistical
//     gate, with **no allowance at all** — this is the comparison the
//     fast path cannot pass (the inversion of the upstream fast kernel
//     underflows for the dense layers of the emulsion, see
//     `docs/PORTING.md` §3.4).
//
//  The tests run on the machines that have a Metal device (the CI of the
//  project).  When there is no device they are **skipped**; when the
//  shader library does not compile they **fail**.
//
//  The lines the tests print start with `METAL-PROGRESS` and
//  `METAL-PARITY exact`, so that the CI logs can be grepped.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

#if canImport(Metal)

import XCTest
import Metal
import FilmPhysics
import FilmPhysicsMetal

final class MetalExactGrainTests: XCTestCase {

    // MARK: - The conventions of the gate

    /// The seeds of the port used by the validation.
    ///
    /// They are the seeds of the existing grain validation of the Metal
    /// port, so that the two fields are compared on the same realisations
    /// of the distribution.
    private let portSeeds: [UInt64] = [
        0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6,
    ]

    /// The critical value of the gate.
    ///
    /// It is the Bonferroni corrected Student t quantile of the family of
    /// the slice 6 (`k = 7.8362`, see `docs/PORTING.md` §3.4): the gate is
    /// **not** loosened, the convention of the existing GPU-vs-CPU grain
    /// test is reused as is.
    private let k = 7.8362

    /// The number of the upstream realisations (the seeds of the fixture).
    private let upstreamSeeds = 12

    /// The cases of the slice 6 the validation runs on.
    ///
    /// The family of the slice 6 holds sixteen cases; the Metal tests run
    /// on a CI machine, and the exact samplers are much more expensive
    /// than the fast kernels (the inversion of the cumulative distribution
    /// of the Poisson of the dense layers of the emulsion costs about a
    /// thousand iterations).  The subset keeps:
    ///
    /// | The case | Why |
    /// |---|---|
    /// | `portra_400__flat_ev_minus2` | the case the exact mode of the CPU was measured on (the largest z-score of the family, §3.4) |
    /// | `ultramax_400__flat_ev_plus2` | the case the **fast** samplers fail on (the inversion of the upstream underflows: every particle of the dense layers develops) |
    /// | `portra_400__textured_ev_0` | a textured case (the grain of a textured field is not a flat field) |
    ///
    /// The other thirteen cases are not run on the GPU: they are validated
    /// on the CPU reference (`GrainCounterTests`, `GrainStatisticsTests`
    /// and `ExactSamplerTests`), which exercises the same algorithm.
    private let caseIDs = [
        "portra_400__flat_ev_minus2",
        "ultramax_400__flat_ev_plus2",
        "portra_400__textured_ev_0",
    ]

    // MARK: - The helpers

    /// Prints a line of the progress of the tests.
    ///
    /// The line is written on the **standard error**, unbuffered: the
    /// standard output of a test is block buffered when it is piped (the
    /// log of the CI is a pipe), so a `print` would only reach the log
    /// when the buffer is full — which is exactly what happens when a
    /// test hangs.
    private func progress(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// The Metal backend of the tests.
    ///
    /// - Throws: `XCTSkip` when the machine has no Metal device, and a
    ///   failure when the shader library does not compile.
    private func makeBackend() throws -> MetalBackend {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal not available: no MTLDevice")
        }
        guard let backend = MetalBackend(device: device) else {
            throw XCTSkip("Metal not available: no command queue")
        }
        if let error = backend.initializationError {
            XCTFail("the shader library could not be compiled: \(error)")
            throw error
        }
        return backend
    }

    /// The mean and the standard deviation of every channel of a field.
    private func channelStatistics(_ field: [Double]) -> [(mean: Double, std: Double)] {
        let channels = 3
        let pixels = field.count / channels
        var result: [(mean: Double, std: Double)] = []
        for channel in 0..<channels {
            var sum = 0.0
            for pixel in 0..<pixels { sum += field[pixel * channels + channel] }
            let mean = pixels > 0 ? sum / Double(pixels) : 0
            var variance = 0.0
            for pixel in 0..<pixels {
                let value = field[pixel * channels + channel] - mean
                variance += value * value
            }
            result.append((mean, pixels > 0 ? (variance / Double(pixels)).squareRoot() : 0))
        }
        return result
    }

    /// The statistics of a field, per channel: the mean and the standard
    /// deviation.
    private func statistics(_ field: [Double]) -> [String: Double] {
        var values: [String: Double] = [:]
        for (channel, statistic) in channelStatistics(field).enumerated() {
            values["mean_\(channel)"] = statistic.mean
            values["std_\(channel)"] = statistic.std
        }
        return values
    }

    /// The scale of the difference between the mean of the port and the
    /// mean of the upstream.
    ///
    /// It is the convention of the existing GPU-vs-CPU grain test: the
    /// spread of the upstream is the scale, and the number of the
    /// realisations of the two sides is accounted for.
    private func scale(_ upstreamStd: Double) -> Double {
        upstreamStd * (1.0 / Double(portSeeds.count)
            + 1.0 / Double(upstreamSeeds)).squareRoot()
    }

    /// The fixture of the slice 6.
    private func loadFixture() throws -> JSONValue {
        try JSONValue.load(named: "slice6_stochastic")
    }

    /// The test image of a case of the slice 6.
    private func image(_ fixture: JSONValue, _ entry: JSONValue) throws -> RGBImage {
        let images = try XCTUnwrap(fixture["images"])
        let identifier = try XCTUnwrap(entry["image"]?.string)
        let kind = identifier.hasPrefix("textured") ? "textured" : "flat"
        let size = try XCTUnwrap(images["size"]?.doubles)
        let data = try XCTUnwrap(images[kind]?.flatDoubles)
        return RGBImage(width: Int(size[0]), height: Int(size[1]), data: data)
    }

    // MARK: - The exact grain of the GPU

    /// The exact grain of the GPU has the statistics of the exact grain of
    /// the CPU.
    ///
    /// The reference is the **counter based exact** grain of the CPU
    /// (``FilmGrainPlan`` in exact mode, i.e. the pure Swift reference of
    /// the GPU path): the two implementations draw from the same
    /// distributions and from the same uniforms, so they must be
    /// indistinguishable.
    ///
    /// The gate is the one of the existing GPU-vs-CPU grain test: the
    /// critical value `k = 7.8362`, the six realisations of the port and
    /// the twelve realisations of the upstream, and the spread of the
    /// upstream as the scale of the difference.
    func testTheExactGrainOfTheGPUHasTheStatisticsOfTheExactGrainOfTheCPU() throws {
        let start = Date()
        progress(
            "METAL-PROGRESS testTheExactGrainOfTheGPUHasTheStatisticsOfTheExactGrainOfTheCPU start"
        )
        defer {
            progress(
                "METAL-PROGRESS testTheExactGrainOfTheGPUHasTheStatisticsOfTheExactGrainOfTheCPU "
                    + "end \(Date().timeIntervalSince(start)) s"
            )
        }
        let backend = try makeBackend()
        let fixture = try loadFixture()
        let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)

        var worst = 0.0
        for entry in cases {
            let id = try XCTUnwrap(entry["id"]?.string)
            guard caseIDs.contains(id) else { continue }
            let film = try ProfileLoader.load(stock: try XCTUnwrap(entry["film"]?.string))
            let printProfile = try ProfileLoader.load(
                stock: try XCTUnwrap(entry["print"]?.string)
            )
            let input = try image(fixture, entry)
            let aggregate = try XCTUnwrap(entry["grain"]?["aggregate"])

            // The parameters of the case (the grain on).
            var params = try makePipelineParams(
                fixture: entry, film: film, print: printProfile
            )
            params.stochastic.seed = portSeeds[0]
            params.filmRender.grain.active = true
            params.printRender.glare.active = false

            // The reference of the CPU: the developed densities (the grain
            // off) and the plan of the grain.
            var plain = params
            plain.filmRender.grain.active = false
            let reference = try FilmPipeline(params: plain).process(rgbIn: input)
            let densities = reference.cmyFilm.data
            let pixelSizeUM = Halation.pixelSizeUM(
                filmFormatMM: params.camera.filmFormatMM,
                width: input.width,
                height: input.height
            )
            let grainPlan = FilmGrainPlan.build(
                grain: params.filmRender.grain, film: film, pixelSizeUM: pixelSizeUM
            )

            // The plan of the GPU (the grain on) and the plan of the
            // reference (the grain off): the plan does not depend on the
            // seed of the grain (the seeds of the streams are derived at
            // the render), so the plan is built once and the seed is
            // changed between the renders.
            var gpuPlan = try FilmRenderPlan.build(params: params)
            let plainPlan = try FilmRenderPlan.build(params: plain)
            let gpuReference = try backend.render(input, plan: plainPlan)

            var gpuStatistics: [[String: Double]] = []
            var cpuStatistics: [[String: Double]] = []
            for seed in portSeeds {
                // The GPU: the exact samplers.
                gpuPlan.params.stochastic.seed = seed
                let gpu = try backend.render(input, plan: gpuPlan, sampler: .exact)
                let gpuField = zip(gpu.cmyFilm.data, gpuReference.cmyFilm.data)
                    .map { $0 - $1 }
                gpuStatistics.append(statistics(gpuField))

                // The CPU: the counter based exact samplers.
                let cpuGrain = grainPlan.apply(
                    densityCMY: densities,
                    width: input.width,
                    height: input.height,
                    seed: seed,
                    sampler: .exact
                )
                let cpuField = zip(cpuGrain, densities).map { $0 - $1 }
                cpuStatistics.append(statistics(cpuField))
            }
            XCTAssertFalse(
                gpuStatistics.isEmpty,
                "the exact grain of the GPU is empty"
            )

            // The comparison, statistic by statistic.
            for statistic in ["mean_0", "std_0", "mean_1", "std_1", "mean_2", "std_2"] {
                let gpuValue = gpuStatistics
                    .compactMap { $0[statistic] }.reduce(0, +) / Double(portSeeds.count)
                let cpuValue = cpuStatistics
                    .compactMap { $0[statistic] }.reduce(0, +) / Double(portSeeds.count)
                let upstream = try XCTUnwrap(aggregate[statistic])
                let upstreamStd = try XCTUnwrap(upstream["std"]?.double)
                let deviation = abs(gpuValue - cpuValue)
                let tolerance = k * scale(upstreamStd)
                let z = deviation / Swift.max(scale(upstreamStd), 1e-300)
                worst = Swift.max(worst, z)
                progress("METAL-PARITY exact slice6 \(id): the grain \(statistic): "
                    + "the GPU \(gpuValue), the CPU \(cpuValue), the deviation "
                    + "\(deviation), the tolerance \(tolerance), the z-score \(z)")
                XCTAssertLessThanOrEqual(
                    deviation, tolerance,
                    "\(id): the exact grain statistic \(statistic) of the GPU is "
                        + "not the exact grain of the CPU (the deviation "
                        + "\(deviation), the tolerance \(tolerance), z = \(z))"
                )
            }
        }
        progress("METAL-PARITY exact slice6: the worst z-score of the exact grain: \(worst)")
    }

    /// The exact grain of the GPU has the statistics of the upstream
    /// **default** path.
    ///
    /// The upstream default path draws the variates of the particles from
    /// the SciPy generators (`scipy.stats.poisson.rvs` and
    /// `scipy.stats.binom.rvs`), i.e. from the very same distributions as
    /// the exact samplers of the port.  The comparison is the plain
    /// statistical gate, with **no allowance at all**: the difference
    /// between the two upstream paths (the underflow of the inversion of
    /// the fast kernel of the upstream) is not a difference of the port,
    /// and the exact mode must not show it.
    ///
    /// This is the comparison the **fast** path cannot pass: the fast
    /// kernels of the upstream develop every particle of the dense layers
    /// of the emulsion, and the grain is therefore systematically denser
    /// than the one of the default path (`docs/PORTING.md` §3.4).
    func testTheExactGrainOfTheGPUHasTheStatisticsOfTheUpstreamDefaultPath() throws {
        let start = Date()
        progress(
            "METAL-PROGRESS testTheExactGrainOfTheGPUHasTheStatisticsOfTheUpstreamDefaultPath start"
        )
        defer {
            progress(
                "METAL-PROGRESS testTheExactGrainOfTheGPUHasTheStatisticsOfTheUpstreamDefaultPath "
                    + "end \(Date().timeIntervalSince(start)) s"
            )
        }
        let backend = try makeBackend()
        let fixture = try loadFixture()
        let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)

        var worst = 0.0
        for entry in cases {
            let id = try XCTUnwrap(entry["id"]?.string)
            guard caseIDs.contains(id) else { continue }
            let film = try ProfileLoader.load(stock: try XCTUnwrap(entry["film"]?.string))
            let printProfile = try ProfileLoader.load(
                stock: try XCTUnwrap(entry["print"]?.string)
            )
            let input = try image(fixture, entry)
            let aggregate = try XCTUnwrap(entry["grain"]?["aggregate"])

            // The parameters of the case (the grain on).
            var params = try makePipelineParams(
                fixture: entry, film: film, print: printProfile
            )
            params.stochastic.seed = portSeeds[0]
            params.filmRender.grain.active = true
            params.printRender.glare.active = false

            // The plan of the GPU (the grain on) and the plan of the
            // reference (the grain off).
            var plain = params
            plain.filmRender.grain.active = false
            var gpuPlan = try FilmRenderPlan.build(params: params)
            let plainPlan = try FilmRenderPlan.build(params: plain)
            let gpuReference = try backend.render(input, plan: plainPlan)

            var gpuStatistics: [[String: Double]] = []
            for seed in portSeeds {
                gpuPlan.params.stochastic.seed = seed
                let gpu = try backend.render(input, plan: gpuPlan, sampler: .exact)
                let gpuField = zip(gpu.cmyFilm.data, gpuReference.cmyFilm.data)
                    .map { $0 - $1 }
                gpuStatistics.append(statistics(gpuField))
            }

            // The comparison with the upstream default path: the plain
            // statistical gate, with **no allowance at all**.
            for statistic in ["mean_0", "std_0", "mean_1", "std_1", "mean_2", "std_2"] {
                let gpuValue = gpuStatistics
                    .compactMap { $0[statistic] }.reduce(0, +) / Double(portSeeds.count)
                let upstream = try XCTUnwrap(aggregate[statistic])
                let upstreamMean = try XCTUnwrap(upstream["mean"]?.double)
                let upstreamStd = try XCTUnwrap(upstream["std"]?.double)
                let deviation = abs(gpuValue - upstreamMean)
                let tolerance = k * scale(upstreamStd)
                let z = deviation / Swift.max(scale(upstreamStd), 1e-300)
                worst = Swift.max(worst, z)
                progress("METAL-PARITY exact slice6 \(id): the grain \(statistic): "
                    + "the GPU \(gpuValue), the upstream \(upstreamMean) +- "
                    + "\(upstreamStd), the deviation \(deviation), the tolerance "
                    + "\(tolerance), the z-score \(z)")
                XCTAssertLessThanOrEqual(
                    deviation, tolerance,
                    "\(id): the exact grain statistic \(statistic) of the GPU is "
                        + "not the grain of the upstream default path (the "
                        + "deviation \(deviation), the tolerance \(tolerance), "
                        + "z = \(z))"
                )
            }
        }
        progress(
            "METAL-PARITY exact slice6: the worst z-score of the exact grain "
                + "against the upstream default path: \(worst)"
        )
    }
}

#endif
