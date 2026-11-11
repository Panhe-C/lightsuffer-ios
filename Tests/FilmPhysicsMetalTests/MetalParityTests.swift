//
//  MetalParityTests.swift
//  light suffer胶片 — iOS app
//
//  The parity tests of the Metal port: the GPU against the CPU reference.
//
//  The tests run on the machines that have a Metal device (the CI of the
//  project).  When there is no device they are **skipped**; when the shader
//  library does not compile they **fail** (a broken kernel is a bug, not a
//  missing feature).
//
//  The lines the tests print start with `METAL-PARITY` and `METAL-TIMING`,
//  so that the CI logs can be grepped.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

#if canImport(Metal)

import XCTest
import Metal
import FilmPhysics
import FilmPhysicsMetal

final class MetalParityTests: XCTestCase {

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

    /// The maximum absolute difference between two arrays.
    private func maxDifference(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count else { return .infinity }
        var maximum = 0.0
        for index in 0..<lhs.count {
            maximum = Swift.max(maximum, abs(lhs[index] - rhs[index]))
        }
        return maximum
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

    // MARK: - The per pixel chain

    /// The GPU reproduces the CPU pipeline of the slice 2.
    ///
    /// The four cases of the slice 2 run the whole pipeline from the camera
    /// image; every spatial and stochastic effect is off, so the CPU
    /// pipeline *is* the per pixel chain the GPU computes.
    func testTheGPUReproducesTheCPUChainOfSlice2() throws {
        let start = Date()
        progress("METAL-PROGRESS testTheGPUReproducesTheCPUChainOfSlice2 start")
        defer {
            progress(
                "METAL-PROGRESS testTheGPUReproducesTheCPUChainOfSlice2 end "
                    + "\(Date().timeIntervalSince(start)) s"
            )
        }
        let backend = try makeBackend()
        let common = try JSONValue.load(named: "slice2_common")
        let film = try ProfileLoader.load(stock: "kodak_portra_400")
        let printProfile = try ProfileLoader.load(stock: "kodak_portra_endura")

        for name in ["defaults", "srgb_input", "camera_ev_minus1", "output_gamut_off"] {
            let fixture = try JSONValue.load(named: "slice2_\(name)")
            let params = try makePipelineParams(fixture: fixture, film: film, print: printProfile)
            let inputs = try XCTUnwrap(common["input_images"])
            let identifier = try XCTUnwrap(fixture["input"]?.string)
            let image = try XCTUnwrap(inputs[identifier])
            let size = try XCTUnwrap(image["size"]?.doubles)
            let data = try XCTUnwrap(image["data"]?.flatDoubles)
            let input = RGBImage(width: Int(size[0]), height: Int(size[1]), data: data)

            let cpu = try FilmPipeline(params: params).process(rgbIn: input)
            let plan = try FilmRenderPlan.build(params: params)
            let gpu = try backend.render(input, plan: plan)
            let error = deltaE(cpu.rgbOut.data, gpu.rgbOut.data)
            progress("METAL-PARITY slice2 \(name): mean dE2000 \(error.mean), "
                + "max dE2000 \(error.max), max abs error "
                + "\(maxDifference(cpu.rgbOut.data, gpu.rgbOut.data))")
            XCTAssertLessThan(error.mean, 0.5, "\(name): the mean dE2000 of the GPU")

            // The taps of the chain, one by one.
            let logEFilm = maxDifference(cpu.logEFilm.data, gpu.logEFilm.data)
            let cmyFilm = maxDifference(cpu.cmyFilm.data, gpu.cmyFilm.data)
            let logEPrint = maxDifference(cpu.logEPrint.data, gpu.logEPrint.data)
            let cmyPrint = maxDifference(cpu.cmyPrint.data, gpu.cmyPrint.data)
            progress("METAL-PARITY slice2 \(name): the taps, max abs error: "
                + "log_e_film \(logEFilm), cmy_film \(cmyFilm), "
                + "log_e_print \(logEPrint), cmy_print \(cmyPrint)")
            XCTAssertLessThan(logEFilm, 1e-3, "\(name): log_e_film")
            XCTAssertLessThan(cmyFilm, 1e-3, "\(name): cmy_film")
            XCTAssertLessThan(logEPrint, 1e-3, "\(name): log_e_print")
            XCTAssertLessThan(cmyPrint, 1e-3, "\(name): cmy_print")

            // The GPU against the executable specification of the kernels
            // (the `Float32` plan evaluator): the two must agree to the
            // rounding of the arithmetic.
            let specification = try FilmPlanEvaluatorFloat32.evaluate(plan: plan, rgbIn: input)
            let difference = maxDifference(specification.rgbOut.data, gpu.rgbOut.data)
            progress("METAL-PARITY slice2 \(name): the GPU against the float32 "
                + "specification, max abs error \(difference)")
            XCTAssertLessThan(difference, 1e-3, "\(name): the GPU against the specification")
        }
    }

    /// The GPU reproduces the CPU pipeline of a subset of the catalogue.
    ///
    /// The catalogue of the slice 4 holds the 148 looks of the engine; the
    /// test runs a **subset** of them, because the Metal tests run on a CI
    /// machine and the whole catalogue would double the duration of the
    /// job.
    ///
    /// The subset covers **every family** of the catalogue:
    ///
    /// | The look | The family |
    /// |---|---|
    /// | `kodak_portra_400__kodak_portra_endura` | a negative film, the print path |
    /// | `kodak_portra_400__kodak_2383` | a negative film, another paper |
    /// | `kodak_portra_400__kodak_portra_endura__scan` | a negative film, the direct scan |
    /// | `fujifilm_velvia_100__kodak_portra_endura__scan` | a slide (a positive film), the direct scan |
    ///
    /// The 144 looks that are not in the subset are **not** validated on
    /// the GPU: they are validated on the CPU reference (the 148 looks of
    /// `CatalogParityTests` and of `FilmPlanEvaluatorTests`), which
    /// exercises the same plan (and therefore the same kernels).
    func testTheGPUReproducesTheCPUChainOfTheCatalogue() throws {
        let start = Date()
        progress("METAL-PROGRESS testTheGPUReproducesTheCPUChainOfTheCatalogue start")
        defer {
            progress(
                "METAL-PROGRESS testTheGPUReproducesTheCPUChainOfTheCatalogue end "
                    + "\(Date().timeIntervalSince(start)) s"
            )
        }
        let backend = try makeBackend()
        let fixture = try JSONValue.load(named: "slice4_catalog")
        let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)
        let image = try XCTUnwrap(fixture["test_image"])
        let size = try XCTUnwrap(image["size"]?.doubles)
        let data = try XCTUnwrap(image["data"]?.flatDoubles)
        let input = RGBImage(width: Int(size[0]), height: Int(size[1]), data: data)

        let subset = [
            // A negative film, the print path.
            "kodak_portra_400__kodak_portra_endura",
            // A negative film, another paper.
            "kodak_portra_400__kodak_2383",
            // A negative film, the direct scan.
            "kodak_portra_400__kodak_portra_endura__scan",
            // A slide (a positive film), the direct scan.
            "fujifilm_velvia_100__kodak_portra_endura__scan",
        ]
        for entry in cases {
            let id = try XCTUnwrap(entry["id"]?.string)
            guard subset.contains(id) else { continue }
            let params = try catalogueParams(entry)
            let cpu = try FilmPipeline(params: params).process(rgbIn: input)
            let plan = try FilmRenderPlan.build(params: params)
            let gpu = try backend.render(input, plan: plan)
            let error = deltaE(cpu.rgbOut.data, gpu.rgbOut.data)
            progress("METAL-PARITY slice4 \(id): mean dE2000 \(error.mean), "
                + "max dE2000 \(error.max)")
            XCTAssertLessThan(error.mean, 0.5, "\(id): the mean dE2000 of the GPU")
        }
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

    // MARK: - The spatial effects

    /// The GPU reproduces the spatial effects of the CPU pipeline.
    ///
    /// The ten cases of the slice 5 exercise the halation, the diffusion
    /// filters, the lens blurs and the unsharp mask: they are the passes of
    /// the GPU pipeline, and the test checks that they do not change the
    /// image more than they change it on the CPU.
    func testTheGPUReproducesTheSpatialEffects() throws {
        let start = Date()
        progress("METAL-PROGRESS testTheGPUReproducesTheSpatialEffects start")
        defer {
            progress(
                "METAL-PROGRESS testTheGPUReproducesTheSpatialEffects end "
                    + "\(Date().timeIntervalSince(start)) s"
            )
        }
        let backend = try makeBackend()
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
            let params = try makePipelineParams(
                fixture: entry, film: film, print: printProfile
            )
            let cpu = try FilmPipeline(params: params).process(rgbIn: input)
            let plan = try FilmRenderPlan.build(params: params)
            let gpu = try backend.render(input, plan: plan)
            let error = deltaE(cpu.rgbOut.data, gpu.rgbOut.data)
            progress("METAL-PARITY slice5 \(id): mean dE2000 \(error.mean), "
                + "max dE2000 \(error.max)")
            XCTAssertLessThan(error.mean, 0.5, "\(id): the mean dE2000 of the GPU")
        }
    }

    // MARK: - The grain

    /// The grain of the GPU draws from the same distribution as the grain of
    /// the CPU.
    ///
    /// The comparison uses the statistical gate of the slice 6: the spread
    /// of the upstream is the scale of the difference, and the critical
    /// value is the Bonferroni corrected Student t quantile of the family of
    /// the slice 6 (`k = 7.8362`, see `docs/PORTING.md` §3.4).
    func testTheGrainOfTheGPUHasTheStatisticsOfTheCPUGrain() throws {
        let start = Date()
        progress("METAL-PROGRESS testTheGrainOfTheGPUHasTheStatisticsOfTheCPUGrain start")
        defer {
            progress(
                "METAL-PROGRESS testTheGrainOfTheGPUHasTheStatisticsOfTheCPUGrain end "
                    + "\(Date().timeIntervalSince(start)) s"
            )
        }
        let backend = try makeBackend()
        let fixture = try JSONValue.load(named: "slice6_stochastic")
        let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)
        let images = try XCTUnwrap(fixture["images"])
        let size = try XCTUnwrap(images["size"]?.doubles)
        let flat = try XCTUnwrap(images["flat"]?.flatDoubles)
        let image = RGBImage(width: Int(size[0]), height: Int(size[1]), data: flat)

        let entry = try XCTUnwrap(cases.first)
        let id = try XCTUnwrap(entry["id"]?.string)
        let film = try ProfileLoader.load(stock: try XCTUnwrap(entry["film"]?.string))
        let printProfile = try ProfileLoader.load(
            stock: try XCTUnwrap(entry["print"]?.string)
        )
        let aggregate = try XCTUnwrap(entry["grain"]?["aggregate"])

        // The seeds of the comparison (six realisations of each
        // implementation).
        let seeds: [UInt64] = [0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6]
        // The critical value of the gate (the Bonferroni corrected Student
        // t quantile of the family of the slice 6).
        let k = 7.8362
        let upstreamSeeds = 12

        var cpuMeans = [[Double]](repeating: [], count: 3)
        var cpuStds = [[Double]](repeating: [], count: 3)
        var gpuMeans = [[Double]](repeating: [], count: 3)
        var gpuStds = [[Double]](repeating: [], count: 3)

        // The plan of the reference (the grain off) does not depend on the
        // seed: it is built once (the plan of a render is the expensive
        // part of the test in a debug build).
        var plainParams = try makePipelineParams(
            fixture: entry, film: film, print: printProfile
        )
        plainParams.stochastic.seed = seeds[0]
        plainParams.filmRender.grain.active = false
        plainParams.printRender.glare.active = false
        let plainPlan = try FilmRenderPlan.build(params: plainParams)

        for seed in seeds {
            var params = try makePipelineParams(
                fixture: entry, film: film, print: printProfile
            )
            params.stochastic.seed = seed
            params.filmRender.grain.active = true
            params.printRender.glare.active = false

            var plain = params
            plain.filmRender.grain.active = false
            let reference = try FilmPipeline(params: plain).process(rgbIn: image)
            let cpu = try FilmPipeline(params: params).process(rgbIn: image)
            let cpuField = zip(cpu.cmyFilm.data, reference.cmyFilm.data).map { $0 - $1 }
            let cpuStatistics = channelStatistics(cpuField)
            for channel in 0..<3 {
                cpuMeans[channel].append(cpuStatistics[channel].mean)
                cpuStds[channel].append(cpuStatistics[channel].std)
            }

            let gpuPlan = try FilmRenderPlan.build(params: params)
            let gpu = try backend.render(image, plan: gpuPlan)
            let gpuReference = try backend.render(image, plan: plainPlan)
            let gpuField = zip(gpu.cmyFilm.data, gpuReference.cmyFilm.data).map { $0 - $1 }
            let gpuStatistics = channelStatistics(gpuField)
            for channel in 0..<3 {
                gpuMeans[channel].append(gpuStatistics[channel].mean)
                gpuStds[channel].append(gpuStatistics[channel].std)
            }
        }

        // The comparison, with the spread of the upstream as the scale.
        var worst = 0.0
        for channel in 0..<3 {
            for (name, values) in [("mean", gpuMeans[channel]), ("std", gpuStds[channel])] {
                let cpuValue = cpuMeans[channel].reduce(0, +) / Double(seeds.count)
                let gpuValue = values.reduce(0, +) / Double(seeds.count)
                let upstream = try XCTUnwrap(aggregate["\(name)_\(channel)"])
                let upstreamMean = try XCTUnwrap(upstream["mean"]?.double)
                let upstreamStd = try XCTUnwrap(upstream["std"]?.double)
                let scale = upstreamStd * (1.0 / Double(seeds.count)
                    + 1.0 / Double(upstreamSeeds)).squareRoot()
                let deviation = abs(gpuValue - cpuValue)
                let tolerance = k * scale
                worst = Swift.max(worst, deviation / Swift.max(scale, 1e-300))
                progress("METAL-PARITY slice6 \(id): the grain \(name)_\(channel): "
                    + "the GPU \(gpuValue), the CPU \(cpuValue), the upstream "
                    + "\(upstreamMean) +- \(upstreamStd), the deviation "
                    + "\(deviation), the tolerance \(tolerance)")
                XCTAssertLessThanOrEqual(
                    deviation, tolerance,
                    "\(id): the grain \(name)_\(channel) of the GPU is not the "
                        + "grain of the CPU"
                )
            }
        }
        progress("METAL-PARITY slice6 \(id): the worst z-score of the grain: \(worst)")
    }

    // MARK: - The timing

    /// The GPU is faster than the CPU on a 1024 × 1024 image.
    ///
    /// The test only **prints** the times: the assertion would be a
    /// measurement of the CI machine, not a property of the port.
    ///
    /// The test is **skipped** unless the environment variable
    /// `RUN_TIMING=1` is set: the CPU side of the measurement costs about
    /// a hundred seconds per run in a debug build (the release build is
    /// about twenty times faster), so the measurement runs in its own step
    /// of the CI, in release.
    func testTheTimingOfTheGPUAndOfTheCPU() throws {
        guard ProcessInfo.processInfo.environment["RUN_TIMING"] == "1" else {
            throw XCTSkip(
                "the timing test only runs when RUN_TIMING=1 (the release step of the CI)"
            )
        }
        let start = Date()
        progress("METAL-PROGRESS testTheTimingOfTheGPUAndOfTheCPU start")
        defer {
            progress(
                "METAL-PROGRESS testTheTimingOfTheGPUAndOfTheCPU end "
                    + "\(Date().timeIntervalSince(start)) s"
            )
        }
        let backend = try makeBackend()
        let width = 1024
        let height = 1024
        // A synthetic camera image: a horizontal ramp.
        var data = [Double](repeating: 0, count: width * height * 3)
        for row in 0..<height {
            for column in 0..<width {
                let value = 0.05 + 0.9 * Double(column) / Double(width)
                for channel in 0..<3 {
                    data[(row * width + column) * 3 + channel] = value
                }
            }
        }
        let image = RGBImage(width: width, height: height, data: data)
        let film = try ProfileLoader.load(stock: "kodak_portra_400")
        let printProfile = try ProfileLoader.load(stock: "kodak_portra_endura")
        let params = PipelineParams(
            film: film,
            print: printProfile,
            camera: CameraParams(autoExposure: false),
            filmRender: FilmRenderParams(grain: GrainParams(active: false)),
            printRender: PrintRenderParams(glare: GlareParams(active: false)),
            scanner: ScannerParams(unsharpMaskSigma: 0, unsharpMaskAmount: 0)
        )

        // The warm up.
        _ = try backend.render(image, params: params)

        var gpuTimes: [Double] = []
        var cpuTimes: [Double] = []
        for _ in 0..<3 {
            let start = Date()
            _ = try backend.render(image, params: params)
            gpuTimes.append(Date().timeIntervalSince(start))

            let cpuStart = Date()
            _ = try FilmPipeline(params: params).process(rgbIn: image)
            cpuTimes.append(Date().timeIntervalSince(cpuStart))
        }
        gpuTimes.sort()
        cpuTimes.sort()
        progress("METAL-TIMING 1024x1024: the GPU \(gpuTimes[1]) s, "
            + "the CPU \(cpuTimes[1]) s, the speed up "
            + "\(cpuTimes[1] / Swift.max(gpuTimes[1], 1e-9))x")
    }
}

#endif
