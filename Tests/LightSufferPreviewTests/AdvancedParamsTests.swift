import FilmPhysics
import LightSufferPreview
import XCTest

/// The tests of the advanced parameter panel.
///
/// They cover the catalog (the mapping of the upstream manifest onto the
/// Swift engine), the apply order, the reset and the guards of the
/// unported parameters.  They do **not** execute the SwiftUI sheet, Metal or
/// a device.
final class AdvancedParamsTests: XCTestCase {

    // MARK: - The catalog

    func testCatalogCoversTheWholeUpstreamManifest() {
        // The upstream manifest declares 107 parameters and instantiates the
        // diffusion group twice (the camera and the enlarger): 118 paths.
        XCTAssertEqual(AdvancedParams.count, 118)
        XCTAssertEqual(AdvancedParams.catalog.count, 118)
        XCTAssertEqual(Set(AdvancedParams.catalog.map(\.path)).count, 118)

        // The inventory: 84 parameters are written by the panel, 6 belong to
        // the Adjustments sheet, 3 to the look, 2 to the Input policy, 1 is
        // locked to the contract of the app and 22 are not ported.
        XCTAssertEqual(AdvancedParams.appliedCount, 84)
        XCTAssertEqual(AdvancedParams.basicSheetOwnedCount, 6)
        XCTAssertEqual(AdvancedParams.externallyOwnedCount, 6)
        XCTAssertEqual(AdvancedParams.unportedCount, 22)
        XCTAssertEqual(
            AdvancedParams.appliedCount
                + AdvancedParams.basicSheetOwnedCount
                + AdvancedParams.externallyOwnedCount
                + AdvancedParams.unportedCount,
            118
        )

        // Every section of the panel exists and holds at least one parameter.
        for section in AdvancedSection.displayOrder {
            XCTAssertFalse(
                AdvancedParams.specs(in: section).isEmpty,
                "the section \(section.rawValue) is empty"
            )
        }
        XCTAssertEqual(AdvancedSection.displayOrder.count, AdvancedSection.allCases.count)
    }

    func testUnportedGroupsAreListedWithTheirReason() {
        // The chemistry is not ported: the group is listed, never applied.
        let chemistry = AdvancedParams.specs(in: .chemistry)
        XCTAssertEqual(chemistry.count, 8)
        for spec in chemistry {
            XCTAssertEqual(spec.availability, .unported(reason: spec.availability.reason ?? ""))
            XCTAssertNotNil(spec.availability.reason)
            XCTAssertTrue(spec.availability.reason?.contains("not ported") == true)
        }

        // Auto exposure is owned by the basic Camera section.
        let autoExposure = AdvancedParams.spec(for: "camera.auto_exposure")
        XCTAssertNotNil(autoExposure)
        XCTAssertEqual(autoExposure?.availability, .basicSheet)

        // The viewer and the workflow of the upstream GUI are not parameters
        // of the simulation.
        XCTAssertEqual(AdvancedParams.specs(in: .viewer).count, 14)
    }

    // MARK: - The mapping

    func testEveryAppliedPathMapsToARealEngineField() throws {
        let baseline = try StockCatalog.pipelineParams(
            film: PreviewLook.filmStock,
            print: PreviewLook.printStock
        )
        let baselineLeaves = leaves(baseline)

        for spec in AdvancedParams.catalog where spec.availability == .applied {
            guard let candidate = distinctValue(for: spec, baseline: baseline) else {
                XCTFail("no value for \(spec.path)")
                continue
            }
            var overrides = AdvancedOverrides()
            XCTAssertTrue(
                overrides.set(candidate.value, for: spec.path),
                "the panel refuses its own parameter \(spec.path)"
            )

            var params = baseline
            let report = AdvancedParams.apply(overrides, to: &params)
            XCTAssertEqual(report.applied, [spec.path])
            XCTAssertTrue(report.rejected.isEmpty)

            let changed = changedLeaves(from: baselineLeaves, to: leaves(params))
            if candidate.isDistinct {
                XCTAssertEqual(
                    Set(changed),
                    Set(spec.enginePaths),
                    "\(spec.path) changed \(changed) instead of \(spec.enginePaths)"
                )
            } else {
                // A parameter with a single accepted value (the ported
                // spectral method, the ported input compression): the value
                // is written, but it is the value of the baseline.
                XCTAssertTrue(changed.isEmpty)
            }
        }
    }

    func testTheBasicSheetOwnedPathsMapToRealEngineFieldsButTheSheetWins() throws {
        let baseline = try StockCatalog.pipelineParams(
            film: PreviewLook.filmStock,
            print: PreviewLook.printStock
        )
        let basicSheetPaths = AdvancedParams.catalog
            .filter { $0.availability == .basicSheet }
            .map(\.path)
        XCTAssertEqual(
            Set(basicSheetPaths),
            [
                "camera.exposure_compensation_ev",
                "camera.auto_exposure",
                "camera.auto_exposure_method",
                "film_render.grain.active",
                "film_render.halation.active",
                "film_render.halation.halation_amount",
            ]
        )

        for spec in AdvancedParams.catalog where spec.availability == .basicSheet {
            guard let candidate = distinctValue(for: spec, baseline: baseline) else {
                XCTFail("no value for \(spec.path)")
                continue
            }
            var overrides = AdvancedOverrides()
            XCTAssertTrue(overrides.set(candidate.value, for: spec.path))

            // The mapping is real: applied on the digested parameters, the
            // field changes.
            var direct = baseline
            AdvancedParams.apply(overrides, to: &direct)
            XCTAssertNotEqual(
                changedLeaves(from: leaves(baseline), to: leaves(direct)),
                []
            )

            // The Adjustments sheet is applied after the overrides: it wins.
            let adjustments = PreviewAdjustments(
                exposureCompensationEV: 1.25,
                grainEnabled: false,
                grainStrength: 1,
                halationEnabled: false,
                halationAmount: 2.5
            )
            let params = try PreviewLook.pipelineParams(
                for: PreviewLook.defaultLook,
                adjustments: adjustments,
                advancedOverrides: overrides
            )
            XCTAssertEqual(params.camera.exposureCompensationEV, 1.25)
            XCTAssertFalse(params.filmRender.grain.active)
            XCTAssertFalse(params.filmRender.halation.active)
            XCTAssertEqual(params.filmRender.halation.halationAmount, 2.5)
        }
    }

    func testUnportedPathsAreRefusedAndNeverApplied() throws {
        let baseline = try StockCatalog.pipelineParams(
            film: PreviewLook.filmStock,
            print: PreviewLook.printStock
        )
        let unported = AdvancedParams.catalog.filter {
            if case .unported = $0.availability { return true }
            return false
        }
        XCTAssertEqual(unported.count, 22)

        for spec in unported {
            var overrides = AdvancedOverrides()
            XCTAssertFalse(
                overrides.set(.double(1.5), for: spec.path),
                "the panel accepts the unported parameter \(spec.path)"
            )
            XCTAssertTrue(overrides.isEmpty)

            // Even a hand-built override is refused by the apply step.
            let forced = AdvancedOverrides(values: [spec.path: .double(1.5)])
            var params = baseline
            let report = AdvancedParams.apply(forced, to: &params)
            XCTAssertTrue(report.applied.isEmpty)
            XCTAssertNotNil(report.rejected[spec.path])
            XCTAssertEqual(leaves(params), leaves(baseline))
        }
    }

    func testUnsupportedAlgorithmNamesAreRefused() throws {
        var input = AdvancedOverrides()
        // The ported methods only.
        XCTAssertTrue(input.set(.choice("xy"), for: "io.input_gamut_compress.algorithm"))
        XCTAssertFalse(input.set(.choice("oklch"), for: "io.input_gamut_compress.algorithm"))

        var output = AdvancedOverrides()
        XCTAssertTrue(output.set(.choice("cam16ucs"), for: "io.output_gamut_compress.algorithm"))
        XCTAssertTrue(output.set(.choice("off"), for: "io.output_gamut_compress.algorithm"))
        XCTAssertFalse(output.set(.choice("aces_rgc"), for: "io.output_gamut_compress.algorithm"))
        XCTAssertFalse(output.set(.choice("oklch"), for: "io.output_gamut_compress.algorithm"))

        var settings = AdvancedOverrides()
        XCTAssertTrue(settings.set(.choice("hanatos2025"), for: "settings.rgb_to_raw_method"))
        XCTAssertFalse(settings.set(.choice("mallett2019"), for: "settings.rgb_to_raw_method"))

        // The refused names never reach the engine, even when they are
        // forced into the overrides.
        let refused = AdvancedOverrides(values: [
            "io.input_gamut_compress.algorithm": .choice("oklch"),
            "io.output_gamut_compress.algorithm": .choice("aces_rgc"),
            "settings.rgb_to_raw_method": .choice("mallett2019"),
        ])
        var params = try PreviewLook.pipelineParams(for: PreviewLook.defaultLook)
        let report = AdvancedParams.apply(refused, to: &params)
        XCTAssertTrue(report.applied.isEmpty)
        XCTAssertEqual(report.rejected.count, 3)
        XCTAssertEqual(params.io.inputGamutCompress.algorithm, "xy")
        XCTAssertEqual(params.io.outputGamutCompress.algorithm, "cam16ucs")
        XCTAssertEqual(params.settings.rgbToRawMethod, "hanatos2025")
        XCTAssertFalse(params.camera.autoExposure)
    }

    func testBasicAutoExposureControlsWinOverAdvancedOverrides() throws {
        var overrides = AdvancedOverrides()
        XCTAssertTrue(overrides.set(.bool(true), for: "camera.auto_exposure"))
        XCTAssertTrue(overrides.set(.choice("median"), for: "camera.auto_exposure_method"))

        var params = try PreviewLook.pipelineParams()
        AdvancedParams.apply(overrides, to: &params)
        XCTAssertTrue(params.camera.autoExposure)
        XCTAssertEqual(params.camera.autoExposureMethod, "median")

        let accepted = try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments(autoExposureEnabled: true, meteringMethod: "matrix"),
            advancedOverrides: overrides
        )
        XCTAssertTrue(accepted.camera.autoExposure)
        XCTAssertEqual(accepted.camera.autoExposureMethod, "matrix")
        let defaultParams = try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook, advancedOverrides: overrides
        )
        XCTAssertFalse(defaultParams.camera.autoExposure)
        XCTAssertEqual(defaultParams.camera.autoExposureMethod, "center_weighted")
    }

    // MARK: - The defaults

    func testAFreshSessionHasNoOverrideAndMatchesTheBaseline() throws {
        let session = PreviewSession(scheduler: TestScheduler())
        XCTAssertTrue(session.advancedOverrides.isEmpty)
        XCTAssertEqual(session.advancedOverrides.count, 0)

        let baseline = try PreviewLook.pipelineParams(
            for: session.look,
            adjustments: session.adjustments,
            inputSettings: session.inputSettings
        )
        let params = try session.requestForTesting().pipelineParams()
        XCTAssertEqual(params, baseline)

        // The defaults of the app are unchanged.
        XCTAssertEqual(params.film.info.stock, "kodak_portra_400")
        XCTAssertEqual(params.print.info.stock, "kodak_portra_endura")
        XCTAssertEqual(params.stochastic.grainSampler, .fast)
        XCTAssertFalse(params.camera.autoExposure)
        XCTAssertEqual(params.io.inputColorSpace, "ProPhoto RGB")
        XCTAssertFalse(params.io.inputCCTFDecoding)
        XCTAssertEqual(params.io.outputColorSpace, "sRGB")
        XCTAssertTrue(params.io.outputCCTFEncoding)
        XCTAssertEqual(params.camera.exposureCompensationEV, 0)
    }

    func testOneOverrideChangesOnlyItsField() throws {
        let baseline = try PreviewLook.pipelineParams(for: PreviewLook.defaultLook)

        var overrides = AdvancedOverrides()
        overrides.set(.double(1.5), for: "film_render.dir_couplers.amount")
        let coupled = try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook,
            advancedOverrides: overrides
        )
        XCTAssertEqual(coupled.filmRender.dirCouplers.amount, 1.5)
        XCTAssertEqual(
            changedLeaves(from: leaves(baseline), to: leaves(coupled)),
            ["filmRender.dirCouplers.amount"]
        )

        // The glare, the enlarger filter and a diffusion strength behave the
        // same way.
        var glare = AdvancedOverrides()
        glare.set(.double(0.2), for: "print_render.glare.percent")
        let glared = try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook,
            advancedOverrides: glare
        )
        XCTAssertEqual(glared.printRender.glare.percent, 0.2)
        XCTAssertEqual(
            changedLeaves(from: leaves(baseline), to: leaves(glared)),
            ["printRender.glare.percent"]
        )

        var filter = AdvancedOverrides()
        filter.set(.double(5), for: "enlarger.y_filter_shift")
        let filtered = try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook,
            advancedOverrides: filter
        )
        XCTAssertEqual(filtered.enlarger.yFilterShift, 5)
        XCTAssertEqual(
            changedLeaves(from: leaves(baseline), to: leaves(filtered)),
            ["enlarger.yFilterShift"]
        )

        var diffusion = AdvancedOverrides()
        diffusion.set(.double(0.75), for: "camera.diffusion_filter.strength")
        let diffused = try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook,
            advancedOverrides: diffusion
        )
        XCTAssertEqual(diffused.camera.diffusionFilter.strength, 0.75)
        XCTAssertEqual(
            changedLeaves(from: leaves(baseline), to: leaves(diffused)),
            ["camera.diffusionFilter.strength"]
        )
    }

    func testTheOverridesSurviveALookChange() throws {
        let session = PreviewSession(scheduler: TestScheduler())
        var overrides = AdvancedOverrides()
        overrides.set(.double(0.8), for: "film_render.halation.scatter_amount")
        session.advancedOverrides = overrides

        try session.selectFilm(stock: "kodak_vision3_250d")
        XCTAssertEqual(session.advancedOverrides, overrides)

        let params = try session.requestForTesting().pipelineParams()
        XCTAssertEqual(params.film.info.stock, "kodak_vision3_250d")
        XCTAssertEqual(params.filmRender.halation.scatterAmount, 0.8)
        XCTAssertEqual(params.stochastic.grainSampler, .fast)

        // The override is re-applied on the fresh digest of the new look.
        let digest = try StockCatalog.pipelineParams(
            film: session.look.film.stock,
            print: session.look.print?.stock
        )
        XCTAssertNotEqual(digest.filmRender.halation.scatterAmount, 0.8)
    }

    func testTheGrainStrengthMultipliesTheOverriddenParticleScale() throws {
        var overrides = AdvancedOverrides()
        overrides.set(.vector([2, 2, 2]), for: "film_render.grain.particle_scale")
        let params = try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments(grainStrength: 1.5),
            advancedOverrides: overrides
        )
        XCTAssertEqual(params.filmRender.grain.particleScale, [3, 3, 3])
        XCTAssertEqual(
            params.filmRender.grain.particleAreaUM2,
            try PreviewLook.pipelineParams().filmRender.grain.particleAreaUM2
        )
    }

    func testResetClearsTheOverridesAndRestoresTheBaseline() throws {
        let session = PreviewSession(scheduler: TestScheduler())
        let baseline = try PreviewLook.pipelineParams(
            for: session.look,
            adjustments: session.adjustments,
            inputSettings: session.inputSettings
        )

        var overrides = AdvancedOverrides()
        overrides.set(.double(1.5), for: "film_render.dir_couplers.amount")
        overrides.set(.double(0.2), for: "print_render.glare.percent")
        session.advancedOverrides = overrides
        XCTAssertFalse(session.advancedOverrides.isEmpty)
        XCTAssertNotEqual(try session.requestForTesting().pipelineParams(), baseline)

        // The global reset clears the overrides: the digest of the stock is
        // preserved, not wiped.
        session.advancedOverrides = AdvancedOverrides()
        XCTAssertTrue(session.advancedOverrides.isEmpty)
        let reset = try session.requestForTesting().pipelineParams()
        XCTAssertEqual(reset, baseline)
        XCTAssertEqual(reset.stochastic.grainSampler, .fast)
        XCTAssertFalse(reset.camera.autoExposure)
        XCTAssertEqual(reset.io.inputColorSpace, "ProPhoto RGB")
        XCTAssertFalse(reset.io.inputCCTFDecoding)
        XCTAssertEqual(reset.film.info.stock, "kodak_portra_400")
        XCTAssertEqual(reset.print.info.stock, "kodak_portra_endura")
    }

    func testASectionResetOnlyClearsItsOwnSection() throws {
        var overrides = AdvancedOverrides()
        overrides.set(.double(1.5), for: "film_render.dir_couplers.amount")
        overrides.set(.double(0.2), for: "print_render.glare.percent")

        let remaining = overrides.removing(section: .glare)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining.contains("film_render.dir_couplers.amount"))
        XCTAssertFalse(remaining.contains("print_render.glare.percent"))
    }

    // MARK: - The predicate of the sections

    func testTheSectionPredicateIsTrueOnlyForTheSectionThatHoldsAnOverride() {
        // No override at all: no section holds one.
        let empty = AdvancedOverrides()
        for section in AdvancedSection.displayOrder {
            XCTAssertFalse(
                empty.contains(section: section),
                "the section \(section.rawValue) holds an override"
            )
        }

        // An override of one section only: that section holds one, the
        // others hold none.  The predicate of a section never depends on
        // the overrides of the other sections.
        var overrides = AdvancedOverrides()
        overrides.set(.double(1.5), for: "film_render.dir_couplers.amount")
        XCTAssertTrue(overrides.contains(section: .couplers))
        XCTAssertFalse(overrides.contains(section: .glare))
        XCTAssertFalse(overrides.contains(section: .grain))
        XCTAssertFalse(overrides.contains(section: .scanner))
    }

    func testTheSectionPredicateFollowsTheResetOfOneSection() {
        // One override of each of two sections.
        var overrides = AdvancedOverrides()
        overrides.set(.double(1.5), for: "film_render.dir_couplers.amount")
        overrides.set(.double(0.2), for: "print_render.glare.percent")
        XCTAssertTrue(overrides.contains(section: .couplers))
        XCTAssertTrue(overrides.contains(section: .glare))

        // The reset of one section clears that section only.
        let remaining = overrides.removing(section: .couplers)
        XCTAssertFalse(remaining.contains(section: .couplers))
        XCTAssertTrue(remaining.contains(section: .glare))

        // The reset of the last section leaves no section with an override.
        let cleared = remaining.removing(section: .glare)
        XCTAssertFalse(cleared.contains(section: .glare))
        XCTAssertFalse(cleared.contains(section: .couplers))
        XCTAssertTrue(cleared.isEmpty)
    }

    // MARK: - The session and the export

    func testAnOverrideChangeInvalidatesTheGeneration() throws {
        let scheduler = TestScheduler()
        let session = PreviewSession(scheduler: scheduler)
        session.photoDidChange()
        session.photoBecameReady()
        scheduler.advance()

        let oldGeneration = session.currentGeneration
        var overrides = AdvancedOverrides()
        overrides.set(.double(1.5), for: "film_render.dir_couplers.amount")
        session.advancedOverrides = overrides

        XCTAssertNotEqual(session.currentGeneration, oldGeneration)
        XCTAssertFalse(session.isCurrent(oldGeneration))
        XCTAssertTrue(session.hasPendingRender)

        scheduler.advance()
        let request = session.requestForTesting()
        XCTAssertEqual(request.advancedOverrides, overrides)
        XCTAssertEqual(request.generation, session.currentGeneration)
        XCTAssertEqual(try request.pipelineParams().filmRender.dirCouplers.amount, 1.5)
    }

    func testTheExportSnapshotUsesTheSameOverrides() throws {
        var overrides = AdvancedOverrides()
        overrides.set(.double(1.5), for: "film_render.dir_couplers.amount")
        overrides.set(.double(0.75), for: "camera.diffusion_filter.strength")

        let request = ExportRequest(
            look: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments(),
            advancedOverrides: overrides
        )
        let params = try request.pipelineParams()
        XCTAssertEqual(params.filmRender.dirCouplers.amount, 1.5)
        XCTAssertEqual(params.camera.diffusionFilter.strength, 0.75)
        XCTAssertEqual(params.stochastic.grainSampler, .fast)
        XCTAssertFalse(params.camera.autoExposure)

        // The export and the preview of the same state agree.
        let preview = PreviewRenderRequest(
            generation: PreviewGeneration(rawValue: 1),
            look: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments(),
            advancedOverrides: overrides
        )
        XCTAssertEqual(try preview.pipelineParams(), params)
    }

    func testAPhotoChangeKeepsTheOverrides() throws {
        let session = PreviewSession(scheduler: TestScheduler())
        var overrides = AdvancedOverrides()
        overrides.set(.double(1.5), for: "film_render.dir_couplers.amount")
        session.advancedOverrides = overrides

        session.photoDidChange()
        XCTAssertEqual(session.advancedOverrides, overrides)
        XCTAssertEqual(session.inputSettings, PhotoInputSettings())
    }
}

// MARK: - The helpers of the tests

private extension PreviewSession {
    /// The immutable snapshot the debounce callback emits.
    func requestForTesting() -> PreviewRenderRequest {
        PreviewRenderRequest(
            generation: currentGeneration,
            look: look,
            adjustments: adjustments,
            inputSettings: inputSettings,
            advancedOverrides: advancedOverrides
        )
    }
}

private final class TestScheduler: PreviewRenderScheduling {
    private struct Entry {
        let action: () -> Void
        var cancelled = false
    }

    private var entries: [Entry] = []

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> PreviewScheduledRender {
        entries.append(Entry(action: action))
        return PreviewScheduledRender { [weak self] in
            guard let index = self?.entries.indices.last else { return }
            self?.entries[index].cancelled = true
        }
    }

    func advance() {
        let due = entries.filter { !$0.cancelled }
        entries.removeAll()
        for entry in due { entry.action() }
    }
}

/// The parameter surface of the engine, without the profiles.
///
/// The profiles never change, so they are left out of the comparison.
private struct ParameterSurface {
    var camera: CameraParams
    var filmRender: FilmRenderParams
    var printRender: PrintRenderParams
    var enlarger: EnlargerParams
    var scanner: ScannerParams
    var io: IOParams
    var settings: SettingsParams
    var stochastic: StochasticParams
}

private func surface(_ params: PipelineParams) -> ParameterSurface {
    ParameterSurface(
        camera: params.camera,
        filmRender: params.filmRender,
        printRender: params.printRender,
        enlarger: params.enlarger,
        scanner: params.scanner,
        io: params.io,
        settings: params.settings,
        stochastic: params.stochastic
    )
}

/// Every scalar leaf of the parameter surface, keyed by its dotted path.
private func leaves(_ params: PipelineParams) -> [String: String] {
    flatten(surface(params))
}

private func flatten(_ value: Any, prefix: String = "") -> [String: String] {
    let mirror = Mirror(reflecting: value)
    var result: [String: String] = [:]
    for child in mirror.children {
        let label = child.label ?? ""
        let path = prefix.isEmpty ? label : "\(prefix).\(label)"
        if let number = child.value as? Double {
            result[path] = String(number)
        } else if let number = child.value as? Int {
            result[path] = String(number)
        } else if let flag = child.value as? Bool {
            result[path] = flag ? "true" : "false"
        } else if let text = child.value as? String {
            result[path] = text
        } else if let numbers = child.value as? [Double] {
            result[path] = numbers.map { String($0) }.joined(separator: ",")
        } else {
            result.merge(flatten(child.value, prefix: path)) { _, new in new }
        }
    }
    return result
}

/// The leaves that changed between two parameter sets.
private func changedLeaves(
    from baseline: [String: String],
    to params: [String: String]
) -> [String] {
    var changed: [String] = []
    for (path, value) in params where baseline[path] != value {
        changed.append(path)
    }
    for (path, value) in baseline where params[path] != value {
        if !changed.contains(path) { changed.append(path) }
    }
    return changed.sorted()
}

/// A value of the parameter that differs from the value of the baseline.
///
/// A parameter with a single accepted value (the ported spectral method,
/// the ported input compression) has no other value: the current one is
/// returned with `isDistinct == false`.
private func distinctValue(
    for spec: AdvancedParamSpec,
    baseline: PipelineParams
) -> (value: AdvancedValue, isDistinct: Bool)? {
    let current = AdvancedParams.value(of: spec.path, in: baseline)
    switch spec.kind {
    case .toggle:
        let flag = current?.boolValue ?? false
        return (.bool(!flag), true)
    case .slider:
        let number = current?.doubleValue ?? 0
        let low = spec.range.lowerBound
        let high = spec.range.upperBound
        let candidate = number < low ? low : (number > high ? high : number + (high - low) / 4)
        if candidate == number {
            return (.double(number == low ? high : low), true)
        }
        return (.double(candidate), true)
    case .stepper:
        let number = current?.intValue ?? Int(spec.range.lowerBound)
        let low = Int(spec.range.lowerBound)
        let high = Int(spec.range.upperBound)
        return (.int(number == low ? high : low), true)
    case .choice:
        let name = current?.choiceValue
        guard let other = spec.choices.first(where: { $0 != name }) else {
            guard let name else { return nil }
            return (.choice(name), false)
        }
        return (.choice(other), true)
    case .vector:
        guard let values = current?.vectorValue, values.count == spec.components.count else {
            return nil
        }
        var updated: [Double] = []
        for (index, component) in spec.components.enumerated() {
            let number = values[index]
            let low = component.range.lowerBound
            let high = component.range.upperBound
            let candidate = number < low ? low : (number > high ? high : number + (high - low) / 4)
            updated.append(candidate == number ? (number == low ? high : low) : candidate)
        }
        return (.vector(updated), true)
    }
}
