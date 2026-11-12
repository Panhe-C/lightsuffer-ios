import CoreGraphics
import FilmPhysics
import Foundation
import FrameCore
import LightSufferPreview
import PhotosUI
import SwiftUI

@MainActor
final class PreviewViewModel: ObservableObject {
    enum Activity: Equatable {
        case idle
        case loading
        case rendering
    }

    /// The state of the full-resolution export.
    enum ExportState: Equatable {
        case idle
        case running(ExportProgress)
        case cancelled
        case saved(String)
        case failed(String)
    }

    @Published private(set) var activity: Activity = .idle
    @Published private(set) var originalImage: CGImage?
    @Published private(set) var gradedImage: CGImage?
    /// The 1280 pixel grade with the border of the export; `nil` when no
    /// border is selected.
    @Published private(set) var framedImage: CGImage?
    @Published private(set) var backendName: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var look: StockCatalog.Look
    @Published var adjustments: PreviewAdjustments {
        didSet {
            guard adjustments != oldValue else { return }
            let previousGeneration = session.currentGeneration
            session.adjustments = adjustments
            guard session.currentGeneration != previousGeneration else { return }
            renderDidInvalidate()
        }
    }

    // MARK: - The export

    @Published private(set) var exportState: ExportState = .idle
    @Published private(set) var exportBorderStyle: BorderStyle = .none
    @Published private(set) var exportFormat: ExportFormat = .jpeg
    /// The look of the running export: an export keeps the snapshot it was
    /// started with, so a later change of the look does not modify it.
    @Published private(set) var exportSnapshotName: String?

    private let session: PreviewSession
    private var selectionID = 0
    private var preparedPhoto: PreparedPhoto?
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportCancellation: ExportCancellation?
    private var exportGeneration: UInt64 = 0

    init() {
        let session = PreviewSession()
        self.session = session
        self.look = session.look
        self.adjustments = session.adjustments

        // MainQueuePreviewRenderScheduler calls back on the main queue.  The
        // task hop gives this MainActor view model an explicit isolation handoff.
        session.onRender = { [weak self] request in
            Task { @MainActor in
                self?.render(request)
            }
        }
    }

    var films: [StockDescriptor] { session.availableFilms }
    var printMedia: [StockDescriptor] { session.availablePrintMedia }

    var outputSelection: String {
        look.print?.stock ?? PreviewLook.directScanIdentifier
    }

    /// Whether an export is running right now.
    var isExportRunning: Bool {
        if case .running = exportState { return true }
        return false
    }

    /// Whether the export button may be used.
    var canExport: Bool {
        preparedPhoto != nil && !isExportRunning
    }

    func selectFilm(stock: String) {
        performLookChange {
            try session.selectFilm(stock: stock)
        }
    }

    func selectOutput(_ selection: String) {
        performLookChange {
            if selection == PreviewLook.directScanIdentifier {
                try session.selectDirectScan()
            } else {
                try session.selectPrint(stock: selection)
            }
        }
    }

    func select(_ item: PhotosPickerItem?) {
        selectionID += 1
        let currentSelection = selectionID
        loadTask?.cancel()
        renderTask?.cancel()
        loadTask = nil
        renderTask = nil
        session.photoDidChange()

        // A new photo invalidates a running export.
        cancelExport()

        errorMessage = nil
        backendName = nil
        preparedPhoto = nil
        originalImage = nil
        gradedImage = nil
        framedImage = nil

        guard let item else {
            activity = .idle
            return
        }
        activity = .loading

        loadTask = Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PreviewSelectionError.emptyPhoto
                }
                try Task.checkCancellation()

                let prepared = try await Task.detached(priority: .userInitiated) {
                    try PhotoDecoder.decode(data: data)
                }.value
                try Task.checkCancellation()
                guard currentSelection == selectionID else { return }

                preparedPhoto = prepared
                originalImage = prepared.original
                activity = .rendering
                // Look changes made while decoding are already reflected in
                // the session generation and in the request it will emit.
                session.photoBecameReady()
            } catch {
                guard currentSelection == selectionID,
                      !Task.isCancelled,
                      !(error is CancellationError) else { return }
                activity = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    private func performLookChange(_ change: () throws -> Void) {
        do {
            let previousGeneration = session.currentGeneration
            try change()
            look = session.look
            guard session.currentGeneration != previousGeneration else { return }
            errorMessage = nil
            renderDidInvalidate()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renderDidInvalidate() {
        renderTask?.cancel()
        renderTask = nil
        errorMessage = nil
        if preparedPhoto != nil {
            // This covers both the debounce interval and the actual render.
            activity = .rendering
        }
    }

    private func render(_ request: PreviewRenderRequest) {
        guard session.isCurrent(request.generation),
              let preparedPhoto else { return }

        activity = .rendering
        renderTask?.cancel()
        renderTask = Task {
            do {
                // Parameter/profile loading, backend creation and the complete
                // physical render all stay off the main actor.  Engine rendering
                // is synchronous, so cancellation is enforced by the generation
                // check when the detached work returns.
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try PreviewRenderer.render(preparedPhoto, request: request)
                }.value
                try Task.checkCancellation()
                guard let rendered = session.accept(
                    rendered,
                    for: request.generation
                ) else { return }

                gradedImage = rendered.image
                backendName = rendered.backendName
                errorMessage = nil
                activity = .idle
                // The border of the export is shown on the preview too, with
                // the layout of the full resolution frame.
                applyBorderPreview()
            } catch {
                guard session.isCurrent(request.generation),
                      !Task.isCancelled,
                      !(error is CancellationError) else { return }
                activity = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - The export

    /// Selects the border of the export.
    ///
    /// The border is painted around the picture; the picture itself is never
    /// cropped.  The preview shows the same layout as the export.
    func selectBorder(style: BorderStyle) {
        guard style != exportBorderStyle else { return }
        exportBorderStyle = style
        applyBorderPreview()
    }

    /// Selects the format of the export.
    func selectFormat(format: ExportFormat) {
        exportFormat = format
    }

    /// Frames the 1280 pixel preview with the selected border.
    ///
    /// The layout is computed from the size of the **full** source frame, so
    /// the border of the preview has the proportions of the border of the
    /// export.  The film grade itself stays the existing 1280 pixel render.
    private func applyBorderPreview() {
        guard let gradedImage, let preparedPhoto else {
            framedImage = nil
            return
        }
        guard exportBorderStyle != .none else {
            framedImage = nil
            return
        }
        do {
            framedImage = try FramedImageRenderer.renderPreview(
                photo: gradedImage,
                sourceSize: preparedPhoto.sourceSize,
                style: exportBorderStyle,
                stockName: look.film.name
            )
        } catch {
            framedImage = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Starts the full-resolution export.
    ///
    /// The export runs on the snapshot of the look, the adjustments, the
    /// border and the format of this moment: a later change of the look does
    /// not modify the file that is being written.  A newer export cancels the
    /// running one.
    func startExport() {
        guard let photo = preparedPhoto else { return }
        guard !isExportRunning else { return }

        let request = ExportRequest(
            look: look,
            adjustments: adjustments,
            format: exportFormat,
            quality: ExportRequest.defaultQuality,
            borderStyle: exportBorderStyle,
            stockName: look.film.name,
            sourceOrientation: photo.source.orientation
        )

        // A newer export cancels the previous one.
        exportCancellation?.cancel()
        exportTask?.cancel()

        exportGeneration &+= 1
        let generation = exportGeneration
        let cancellation = ExportCancellation()
        exportCancellation = cancellation
        exportSnapshotName = look.name
        exportState = .running(ExportProgress(stage: .decoding, fractionCompleted: 0))

        let report: @Sendable (ExportProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.exportGeneration == generation else { return }
                guard self.isExportRunning else { return }
                self.exportState = .running(progress)
            }
        }

        exportTask = Task {
            do {
                // The whole export (the decode, the tiled render, the framing,
                // the encoding and the save) stays off the main actor.
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try await ExportPipeline.run(
                        photo: photo,
                        request: request,
                        progress: report,
                        cancellation: cancellation
                    )
                }.value
                try Task.checkCancellation()
                guard generation == exportGeneration else { return }
                exportCancellation = nil
                exportSnapshotName = nil
                exportState = .saved(summary(for: outcome))
            } catch {
                guard generation == exportGeneration else { return }
                exportCancellation = nil
                exportSnapshotName = nil
                if error is CancellationError || (error as? ExportPipelineError) == .cancelled {
                    exportState = .cancelled
                } else {
                    exportState = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Cancels the running export.
    ///
    /// The export stops at the next stage or at the next tile; a render that
    /// is already running may finish, and its result is then discarded.
    func cancelExport() {
        guard isExportRunning else { return }
        exportCancellation?.cancel()
        exportCancellation = nil
        exportTask?.cancel()
        exportTask = nil
        // The generation invalidates the result of the cancelled export.
        exportGeneration &+= 1
        exportSnapshotName = nil
        exportState = .cancelled
    }

    /// The text of the progress of an export.
    func exportProgressText(_ progress: ExportProgress) -> String {
        switch progress.stage {
        case .decoding:
            return "Decoding the full-resolution photo…"
        case .planning:
            return "Planning the tiles…"
        case .rendering:
            guard progress.totalTiles > 1 else {
                return "Rendering the full-resolution grade…"
            }
            return "Rendering tile \(min(progress.completedTiles + 1, progress.totalTiles)) of \(progress.totalTiles)…"
        case .framing:
            return "Drawing the border…"
        case .encoding:
            return "Encoding…"
        case .saving:
            return "Saving to the photo library…"
        }
    }

    private func summary(for outcome: ExportOutcome) -> String {
        let megabytes = Double(outcome.byteCount) / 1_048_576
        return String(
            format: "Saved to your photo library. %.1f MB, %d tile(s), %@ backend.",
            megabytes,
            outcome.tileCount,
            outcome.backendName
        )
    }
}

private enum PreviewSelectionError: LocalizedError {
    case emptyPhoto

    var errorDescription: String? {
        "The selected photo did not provide any image data."
    }
}
