import CoreGraphics
import Foundation
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

    private var selectionID = 0
    private var renderTask: Task<Void, Never>?

    func select(_ item: PhotosPickerItem?) {
        selectionID += 1
        let currentSelection = selectionID
        renderTask?.cancel()
        errorMessage = nil
        backendName = nil
        originalImage = nil
        gradedImage = nil

        guard let item else {
            activity = .idle
            renderTask = nil
            return
        }
        activity = .loading

        renderTask = Task {
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

                originalImage = prepared.original
                activity = .rendering

                // Backend creation, profile loading and the complete physical
                // render stay off the main actor.  A long 1280px CPU fallback
                // is expected and leaves the picker and hold comparison live.
                let rendered = try await Task.detached(priority: .userInitiated) {
                    try PreviewRenderer.render(prepared)
                }.value
                try Task.checkCancellation()
                guard currentSelection == selectionID else { return }

                gradedImage = rendered.image
                backendName = rendered.backendName
                activity = .idle
            } catch {
                guard currentSelection == selectionID,
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
