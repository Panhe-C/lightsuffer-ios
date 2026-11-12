import CoreGraphics
import FilmPhysics
import Foundation
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

    @Published private(set) var activity: Activity = .idle
    @Published private(set) var originalImage: CGImage?
    @Published private(set) var gradedImage: CGImage?
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

    private let session: PreviewSession
    private var selectionID = 0
    private var preparedPhoto: PreparedPhoto?
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?

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

        errorMessage = nil
        backendName = nil
        preparedPhoto = nil
        originalImage = nil
        gradedImage = nil

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
            } catch {
                guard session.isCurrent(request.generation),
                      !Task.isCancelled,
                      !(error is CancellationError) else { return }
                activity = .idle
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum PreviewSelectionError: LocalizedError {
    case emptyPhoto

    var errorDescription: String? {
        "The selected photo did not provide any image data."
    }
}
