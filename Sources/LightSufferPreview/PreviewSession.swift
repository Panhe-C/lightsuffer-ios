//
//  PreviewSession.swift
//  light suffer胶片 — preview session support
//

import FilmPhysics
import Foundation

/// A monotonically increasing identity for a photo / look / adjustment state.
public struct PreviewGeneration: Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// All immutable state needed by one off-main-thread render.
public struct PreviewRenderRequest: Sendable {
    public let generation: PreviewGeneration
    public let look: StockCatalog.Look
    public let adjustments: PreviewAdjustments

    public init(
        generation: PreviewGeneration,
        look: StockCatalog.Look,
        adjustments: PreviewAdjustments
    ) {
        self.generation = generation
        self.look = look
        self.adjustments = adjustments
    }

    /// Loads and digests the look, then applies the basic physical adjustments.
    /// The app calls this inside its detached render task.
    public func pipelineParams() throws -> PipelineParams {
        try PreviewLook.pipelineParams(for: look, adjustments: adjustments)
    }
}

/// A cancellable debounce callback.
public struct PreviewScheduledRender {
    private let cancellation: () -> Void

    public init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        cancellation()
    }
}

/// Injection point for a clock / scheduler.  No wall-clock sleeps are needed
/// in unit tests.  The production scheduler and the session are both confined
/// to the app's main thread; test schedulers invoke callbacks synchronously.
public protocol PreviewRenderScheduling {
    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> PreviewScheduledRender
}

public struct MainQueuePreviewRenderScheduler: PreviewRenderScheduling {
    public init() {}

    public func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> PreviewScheduledRender {
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return PreviewScheduledRender(cancellation: work.cancel)
    }
}

/// Platform-neutral state and scheduling for the interactive preview.
///
/// The view model owns photo decoding and backend execution.  This type owns
/// the selected look, basic adjustments, debounce policy and generation-based
/// stale-result rejection.  Every mutation cancels the pending debounce.  A
/// cancelled callback is also guarded by its generation, so even a scheduler
/// that is already firing cannot emit an obsolete request.
public final class PreviewSession {
    public static let defaultDebounceInterval: TimeInterval = 0.200

    public private(set) var look: StockCatalog.Look
    public var adjustments: PreviewAdjustments {
        didSet {
            guard adjustments != oldValue else { return }
            invalidateAndSchedule()
        }
    }

    public private(set) var currentGeneration = PreviewGeneration(rawValue: 0)
    public private(set) var hasReadyPhoto = false
    public var onRender: ((PreviewRenderRequest) -> Void)?

    public let debounceInterval: TimeInterval
    private let scheduler: any PreviewRenderScheduling
    private var pendingRender: PreviewScheduledRender?

    public init(
        debounceInterval: TimeInterval = PreviewSession.defaultDebounceInterval,
        scheduler: any PreviewRenderScheduling = MainQueuePreviewRenderScheduler()
    ) {
        self.look = PreviewLook.defaultLook
        self.adjustments = PreviewAdjustments()
        self.debounceInterval = debounceInterval
        self.scheduler = scheduler
    }

    deinit {
        pendingRender?.cancel()
    }

    public var availableFilms: [StockDescriptor] { StockCatalog.films }
    public var availablePrintMedia: [StockDescriptor] { StockCatalog.printMedia }
    public var hasPendingRender: Bool { pendingRender != nil }

    /// Selects a film and its `targetPrint`; a positive selects direct scan.
    public func selectFilm(stock: String) throws {
        let selected = try PreviewLook.look(film: stock)
        updateLook(selected)
    }

    /// Changes only the print medium, preserving film and basic adjustments.
    public func selectPrint(stock: String) throws {
        let selected = try PreviewLook.look(film: look.film.stock, print: stock)
        updateLook(selected)
    }

    /// Changes only the output path to a direct scan, preserving the film.
    public func selectDirectScan() throws {
        let selected = try PreviewLook.look(film: look.film.stock, print: nil)
        updateLook(selected)
    }

    /// Begins a new photo state.  This immediately invalidates all older work;
    /// `photoBecameReady` arms the debounce after decoding has completed.
    public func photoDidChange() {
        hasReadyPhoto = false
        invalidateAndSchedule()
    }

    /// Marks the current photo as decoded and ready for rendering.
    public func photoBecameReady() {
        guard !hasReadyPhoto else { return }
        hasReadyPhoto = true
        schedule()
    }

    /// Whether work from `generation` still belongs to the current session.
    public func isCurrent(_ generation: PreviewGeneration) -> Bool {
        hasReadyPhoto && generation == currentGeneration
    }

    /// Returns a result only when its generation is still current.  The app
    /// uses this at the single point where a completed render is published.
    public func accept<Result>(
        _ result: Result,
        for generation: PreviewGeneration
    ) -> Result? {
        guard isCurrent(generation) else { return nil }
        return result
    }

    private func updateLook(_ selected: StockCatalog.Look) {
        guard selected != look else { return }
        look = selected
        invalidateAndSchedule()
    }

    private func invalidateAndSchedule() {
        currentGeneration = PreviewGeneration(rawValue: currentGeneration.rawValue &+ 1)
        pendingRender?.cancel()
        pendingRender = nil
        schedule()
    }

    private func schedule() {
        guard hasReadyPhoto else { return }
        let generation = currentGeneration
        pendingRender = scheduler.schedule(after: debounceInterval) { [weak self] in
            self?.debounceFired(generation: generation)
        }
    }

    private func debounceFired(generation: PreviewGeneration) {
        guard isCurrent(generation) else { return }
        pendingRender = nil
        onRender?(
            PreviewRenderRequest(
                generation: generation,
                look: look,
                adjustments: adjustments
            )
        )
    }
}
