import FilmPhysics
import LightSufferPreview
import XCTest

final class ChemistryControlsTests: XCTestCase {
    func testChemistryInvalidatesPreviewAndExportKeepsItsOwnSnapshot() throws {
        let scheduler = ChemistryScheduler()
        let session = PreviewSession(scheduler: scheduler)
        var requests: [PreviewRenderRequest] = []
        session.onRender = { requests.append($0) }
        session.photoBecameReady()
        scheduler.advance()
        let previous = try XCTUnwrap(requests.last)
        session.advancedOverrides.set(
            .double(0.65), for: "print_render.density_curves_morph.developer_exhaustion"
        )
        session.advancedOverrides.set(
            .double(1.4), for: "print_render.density_curves_morph.gamma_factor_fast"
        )
        XCTAssertFalse(session.isCurrent(previous.generation))
        scheduler.advance()
        let preview = try XCTUnwrap(requests.last)
        let export = ExportRequest(
            look: session.look, adjustments: session.adjustments,
            advancedOverrides: session.advancedOverrides
        )
        let expected = try preview.pipelineParams().printRender.densityCurvesMorph
        XCTAssertEqual(expected.developerExhaustion, 0.65)
        XCTAssertEqual(expected.gammaFactorFast, 1.4)
        session.advancedOverrides = session.advancedOverrides.removing(section: .chemistry)
        XCTAssertFalse(session.isCurrent(preview.generation))
        XCTAssertEqual(try export.pipelineParams().printRender.densityCurvesMorph, expected)
        XCTAssertEqual(try preview.pipelineParams().printRender.densityCurvesMorph, expected)
        scheduler.advance()
        let restored = try XCTUnwrap(requests.last)
        XCTAssertEqual(
            try restored.pipelineParams().printRender.densityCurvesMorph,
            PrintCurvesMorphParams()
        )
    }

    func testAllChemistryControlsAreAppliedAndResetToTheStockDefaults() throws {
        let specs = AdvancedParams.specs(in: .chemistry)
        XCTAssertEqual(specs.count, 8)
        XCTAssertTrue(specs.allSatisfy { $0.availability == .applied })
        var overrides = AdvancedOverrides()
        for spec in specs {
            let value: AdvancedValue = spec.kind == .toggle ? .bool(false) : .double(0.75)
            XCTAssertTrue(overrides.set(value, for: spec.path), spec.path)
        }
        let modified = try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook, advancedOverrides: overrides
        )
        let baseline = try PreviewLook.pipelineParams(for: PreviewLook.defaultLook)
        XCTAssertNotEqual(modified.printRender, baseline.printRender)
        overrides = overrides.removing(section: .chemistry)
        let restored = try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook, advancedOverrides: overrides
        )
        XCTAssertEqual(restored.printRender, baseline.printRender)
    }
}

private final class ChemistryScheduler: PreviewRenderScheduling {
    private var pending: (() -> Void)?

    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> PreviewScheduledRender {
        pending = action
        return PreviewScheduledRender { [weak self] in self?.pending = nil }
    }

    func advance() {
        let action = pending
        pending = nil
        action?()
    }
}
