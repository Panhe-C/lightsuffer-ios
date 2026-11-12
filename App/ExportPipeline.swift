//
//  ExportPipeline.swift
//  The single entry point of an export.
//
//  decode → plan → tiled render → frame → encode → save
//

import Foundation
import LightSufferPreview

/// What an export produced.
struct ExportOutcome: Sendable {
    /// The number of tiles the frame was rendered with.
    let tileCount: Int
    /// The backend that rendered the tiles.
    let backendName: String
    /// The size of the encoded file, in bytes.
    let byteCount: Int
}

enum ExportPipeline {

    /// Runs the whole export off the main actor.
    ///
    /// - Parameters:
    ///   - photo: the photo of the preview; the export decodes its source
    ///     again, at full resolution.
    ///   - request: the immutable snapshot of the look, the adjustments, the
    ///     border, the format and the orientation of the export.
    ///   - progress: the progress of the export.
    ///   - cancellation: the cooperative cancellation of the export.  It is
    ///     honoured between the stages and between the tiles; a render that is
    ///     already running may finish, and its result is then discarded.
    static func run(
        photo: PreparedPhoto,
        request: ExportRequest,
        progress: @escaping @Sendable (ExportProgress) -> Void,
        cancellation: ExportCancellation
    ) async throws -> ExportOutcome {
        let result = try ExportOrchestrator.render(
            photo: photo,
            request: request,
            budget: ExportOrchestrator.deviceBudget(),
            progress: progress,
            cancellation: cancellation
        )

        // The last moment a cancellation can stop the export: the request of
        // the photo library is not submitted yet.
        try cancellation.check()
        progress(ExportProgress(stage: .saving, fractionCompleted: 0.97))
        try await PhotoLibraryWriter.save(data: result.data, format: request.format)
        progress(ExportProgress(stage: .saving, fractionCompleted: 1))

        return ExportOutcome(
            tileCount: result.tileCount,
            backendName: result.backendName,
            byteCount: result.data.count
        )
    }
}
