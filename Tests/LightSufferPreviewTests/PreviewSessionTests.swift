import FilmPhysics
import LightSufferPreview
import XCTest

final class PreviewSessionTests: XCTestCase {

    func testDefaultLookIsPortra400OnPortraEnduraWithFastGrain() throws {
        let session = PreviewSession(scheduler: TestPreviewScheduler())

        XCTAssertEqual(session.look.film.stock, "kodak_portra_400")
        XCTAssertEqual(session.look.print?.stock, "kodak_portra_endura")
        XCTAssertFalse(session.look.scanFilm)

        let params = try session.renderRequestForTesting().pipelineParams()
        XCTAssertEqual(params.film.info.stock, "kodak_portra_400")
        XCTAssertEqual(params.print.info.stock, "kodak_portra_endura")
        XCTAssertFalse(params.io.scanFilm)
        XCTAssertFalse(params.camera.autoExposure)
        XCTAssertEqual(params.stochastic.grainSampler, .fast)
        XCTAssertEqual(params.camera.exposureCompensationEV, 0)
    }

    func testEveryCatalogueFilmIsListedAndSelectsItsDefaultOutput() throws {
        let session = PreviewSession(scheduler: TestPreviewScheduler())

        XCTAssertEqual(session.availableFilms.map(\.stock), StockCatalog.films.map(\.stock))
        XCTAssertEqual(session.availableFilms.count, 20)

        for film in StockCatalog.films {
            try session.selectFilm(stock: film.stock)
            XCTAssertEqual(session.look.film, film)
            if film.isPositive {
                XCTAssertTrue(session.look.scanFilm)
                XCTAssertNil(session.look.print)
            } else {
                XCTAssertFalse(session.look.scanFilm)
                XCTAssertEqual(session.look.print, StockCatalog.defaultPrint(for: film.stock))
            }
        }
    }

    func testPaperAndDirectScanSetPipelinePathWithoutChangingFilm() throws {
        let session = PreviewSession(scheduler: TestPreviewScheduler())
        try session.selectFilm(stock: "kodak_gold_200")
        try session.selectPrint(stock: "kodak_2383")

        let printed = try session.renderRequestForTesting().pipelineParams()
        XCTAssertEqual(session.look.film.stock, "kodak_gold_200")
        XCTAssertEqual(session.look.print?.stock, "kodak_2383")
        XCTAssertFalse(session.look.scanFilm)
        XCTAssertEqual(printed.film.info.stock, "kodak_gold_200")
        XCTAssertEqual(printed.print.info.stock, "kodak_2383")
        XCTAssertFalse(printed.io.scanFilm)

        try session.selectDirectScan()
        let scanned = try session.renderRequestForTesting().pipelineParams()
        XCTAssertEqual(session.look.film.stock, "kodak_gold_200")
        XCTAssertNil(session.look.print)
        XCTAssertTrue(session.look.scanFilm)
        XCTAssertEqual(scanned.film.info.stock, "kodak_gold_200")
        // PipelineParams still carries a profile for its direct-scan colour
        // reference API, but the printing stage is skipped and no paper is
        // presented as selected by the session.
        XCTAssertEqual(
            scanned.print.info.stock,
            StockCatalog.defaultPrint(for: "kodak_gold_200")?.stock
        )
        XCTAssertTrue(scanned.io.scanFilm)
        XCTAssertEqual(scanned.stochastic.grainSampler, .fast)
    }

    func testEveryPrintMediumIsAvailableAndPositiveFilmsRejectPaper() throws {
        let session = PreviewSession(scheduler: TestPreviewScheduler())
        XCTAssertEqual(
            session.availablePrintMedia.map(\.stock),
            StockCatalog.printMedia.map(\.stock)
        )
        XCTAssertEqual(session.availablePrintMedia.count, 8)

        for medium in StockCatalog.printMedia {
            try session.selectPrint(stock: medium.stock)
            XCTAssertEqual(session.look.print, medium)
            XCTAssertFalse(session.look.scanFilm)
        }

        try session.selectFilm(stock: "fujifilm_velvia_100")
        XCTAssertThrowsError(try session.selectPrint(stock: "kodak_portra_endura")) { error in
            XCTAssertEqual(
                error as? PreviewLookError,
                .printNotAvailableForPositive("fujifilm_velvia_100")
            )
        }
        XCTAssertEqual(session.look.film.stock, "fujifilm_velvia_100")
        XCTAssertTrue(session.look.scanFilm)
        XCTAssertNil(session.look.print)
    }

    func testBasicAdjustmentsMapToDigestedEngineFields() throws {
        let baseline = try PreviewLook.pipelineParams()
        let neutral = try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments()
        )

        XCTAssertEqual(PreviewAdjustments().exposureCompensationEV, 0)
        XCTAssertEqual(neutral.camera.exposureCompensationEV, 0)
        XCTAssertEqual(neutral.filmRender.grain, baseline.filmRender.grain)
        XCTAssertEqual(neutral.filmRender.halation, baseline.filmRender.halation)
        XCTAssertEqual(neutral.stochastic.grainSampler, .fast)

        let adjustments = PreviewAdjustments(
            exposureCompensationEV: 1.25,
            grainEnabled: false,
            grainStrength: 1.75,
            halationEnabled: false,
            halationAmount: 2.25
        )
        let adjusted = try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook,
            adjustments: adjustments
        )

        XCTAssertEqual(adjusted.camera.exposureCompensationEV, 1.25)
        XCTAssertFalse(adjusted.camera.autoExposure)
        XCTAssertFalse(adjusted.filmRender.grain.active)
        XCTAssertEqual(
            adjusted.filmRender.grain.particleAreaUM2,
            baseline.filmRender.grain.particleAreaUM2
        )
        XCTAssertEqual(
            adjusted.filmRender.grain.particleScaleLayers,
            baseline.filmRender.grain.particleScaleLayers
        )
        XCTAssertEqual(adjusted.filmRender.grain.particleScale.count, 3)
        for (actual, digested) in zip(
            adjusted.filmRender.grain.particleScale,
            baseline.filmRender.grain.particleScale
        ) {
            XCTAssertEqual(actual, digested * 1.75, accuracy: 1e-12)
        }
        XCTAssertFalse(adjusted.filmRender.halation.active)
        XCTAssertEqual(adjusted.filmRender.halation.halationAmount, 2.25)
        XCTAssertEqual(adjusted.stochastic.grainSampler, .fast)
    }

    func testLookChangesPreserveBasicAdjustmentsButUseNewDigestedGrain() throws {
        let session = PreviewSession(scheduler: TestPreviewScheduler())
        session.adjustments = PreviewAdjustments(
            exposureCompensationEV: -0.75,
            grainEnabled: true,
            grainStrength: 1.4,
            halationEnabled: true,
            halationAmount: 0.65
        )
        try session.selectFilm(stock: "kodak_vision3_250d")

        let newBaseline = try PreviewLook.pipelineParams(for: session.look)
        let params = try session.renderRequestForTesting().pipelineParams()
        XCTAssertEqual(params.film.info.stock, "kodak_vision3_250d")
        XCTAssertEqual(params.print.info.stock, "kodak_2383")
        XCTAssertEqual(params.camera.exposureCompensationEV, -0.75)
        XCTAssertEqual(params.filmRender.halation.halationAmount, 0.65)
        for (actual, digested) in zip(
            params.filmRender.grain.particleScale,
            newBaseline.filmRender.grain.particleScale
        ) {
            XCTAssertEqual(actual, digested * 1.4, accuracy: 1e-12)
        }
        XCTAssertEqual(params.stochastic.grainSampler, .fast)
    }

    func testNewerChangeRejectsStaleGenerationResult() {
        let scheduler = TestPreviewScheduler()
        let session = PreviewSession(scheduler: scheduler)
        session.photoDidChange()
        session.photoBecameReady()
        let oldGeneration = session.currentGeneration
        scheduler.advance()

        XCTAssertTrue(session.isCurrent(oldGeneration))
        session.adjustments.exposureCompensationEV = 0.5
        let newGeneration = session.currentGeneration

        XCTAssertNotEqual(newGeneration, oldGeneration)
        XCTAssertFalse(session.isCurrent(oldGeneration))
        XCTAssertNil(session.accept("stale", for: oldGeneration))
        XCTAssertEqual(session.accept("fresh", for: newGeneration), "fresh")

        session.photoDidChange()
        XCTAssertNil(session.accept("old photo", for: newGeneration))
    }

    func testUpdateBurstLeavesOnePendingRenderAndFiresOnceAfterInterval() throws {
        let scheduler = TestPreviewScheduler()
        let session = PreviewSession(scheduler: scheduler)
        var requests: [PreviewRenderRequest] = []
        session.onRender = { requests.append($0) }

        session.photoDidChange()
        XCTAssertEqual(scheduler.livePendingCount, 0)
        session.photoBecameReady()
        XCTAssertEqual(scheduler.livePendingCount, 1)

        for tick in 0..<20 {
            session.adjustments.exposureCompensationEV = Double(tick) / 100
        }
        try session.selectFilm(stock: "fujifilm_pro_400h")
        try session.selectDirectScan()

        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(scheduler.livePendingCount, 1)
        XCTAssertFalse(scheduler.scheduledDelays.isEmpty)
        for delay in scheduler.scheduledDelays {
            XCTAssertEqual(delay, PreviewSession.defaultDebounceInterval)
            XCTAssertEqual(delay, 0.200)
        }

        scheduler.advance()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(scheduler.livePendingCount, 0)
        XCTAssertEqual(requests[0].generation, session.currentGeneration)
        XCTAssertEqual(requests[0].look.film.stock, "fujifilm_pro_400h")
        XCTAssertTrue(requests[0].look.scanFilm)
        XCTAssertEqual(requests[0].adjustments.exposureCompensationEV, 0.19)
    }

    func testInputSettingsInvalidateAndSurviveLookAndBasicChanges() throws {
        let scheduler = TestPreviewScheduler()
        let session = PreviewSession(scheduler: scheduler)
        session.photoDidChange()
        session.photoBecameReady()
        scheduler.advance()

        let oldGeneration = session.currentGeneration
        let settings = PhotoInputSettings(
            whiteBalanceMode: .custom,
            customTemperature: 4300,
            customTint: 1.05,
            inputColorSpace: .explicit("Display P3")
        )
        session.inputSettings = settings
        XCTAssertNotEqual(session.currentGeneration, oldGeneration)
        XCTAssertFalse(session.isCurrent(oldGeneration))
        XCTAssertTrue(session.hasPendingRender)

        try session.selectFilm(stock: "kodak_vision3_250d")
        session.adjustments.exposureCompensationEV = 0.25
        XCTAssertEqual(session.inputSettings, settings)
        scheduler.advance()

        let request = session.renderRequestForTesting()
        XCTAssertEqual(request.inputSettings, settings)
        let params = try request.pipelineParams()
        XCTAssertEqual(params.io.inputColorSpace, "ProPhoto RGB")
        XCTAssertFalse(params.io.inputCCTFDecoding)
        XCTAssertEqual(params.stochastic.grainSampler, .fast)
        XCTAssertEqual(params.camera.exposureCompensationEV, 0.25)
    }

    func testNewPhotoResetsInputSettingsByDefault() {
        let session = PreviewSession(scheduler: TestPreviewScheduler())
        session.inputSettings = PhotoInputSettings(
            whiteBalanceMode: .tungsten,
            customTemperature: 3200,
            customTint: 1.1,
            inputColorSpace: .explicit("sRGB")
        )
        session.photoDidChange()
        XCTAssertEqual(session.inputSettings, PhotoInputSettings())

        session.inputSettings = PhotoInputSettings(whiteBalanceMode: .daylight)
        session.photoDidChange(resetInputSettings: false)
        XCTAssertEqual(session.inputSettings.whiteBalanceMode, .daylight)
    }

    func testCancelledCallbackThatStillRunsCannotEmitStaleRequest() {
        let scheduler = TestPreviewScheduler()
        let session = PreviewSession(scheduler: scheduler)
        var requests: [PreviewRenderRequest] = []
        session.onRender = { requests.append($0) }
        session.photoDidChange()
        session.photoBecameReady()
        session.adjustments.halationAmount = 1.5

        // Simulates a callback already dequeued when cancellation arrives.
        scheduler.advanceIncludingCancelled()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].generation, session.currentGeneration)
        XCTAssertEqual(requests[0].adjustments.halationAmount, 1.5)
    }
}

private extension PreviewSession {
    /// Constructs the same immutable snapshot the debounce callback emits.
    /// This helper is test-only; it does not schedule or perform a render.
    func renderRequestForTesting() -> PreviewRenderRequest {
        PreviewRenderRequest(
            generation: currentGeneration,
            look: look,
            adjustments: adjustments,
            inputSettings: inputSettings
        )
    }
}

private final class TestPreviewScheduler: PreviewRenderScheduling {
    private struct Entry {
        let id: Int
        let action: () -> Void
        var cancelled = false
    }

    private var nextID = 0
    private var entries: [Entry] = []
    private(set) var scheduledDelays: [TimeInterval] = []

    var livePendingCount: Int {
        entries.filter { !$0.cancelled }.count
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> PreviewScheduledRender {
        let id = nextID
        nextID += 1
        scheduledDelays.append(delay)
        entries.append(Entry(id: id, action: action))
        return PreviewScheduledRender { [weak self] in
            guard let index = self?.entries.firstIndex(where: { $0.id == id }) else { return }
            self?.entries[index].cancelled = true
        }
    }

    func advance() {
        runEntries(includeCancelled: false)
    }

    func advanceIncludingCancelled() {
        runEntries(includeCancelled: true)
    }

    private func runEntries(includeCancelled: Bool) {
        let due = entries.filter { includeCancelled || !$0.cancelled }
        entries.removeAll()
        for entry in due {
            entry.action()
        }
    }
}
