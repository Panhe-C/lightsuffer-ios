//
//  PhotoLibraryWriter.swift
//  The add-only write of an export into the photo library.
//
//  The exporter never asks for read access to the library: the app only needs
//  to *add* the exported photo, so the authorization is requested for the
//  `addOnly` access level.
//

import Foundation
import LightSufferPreview
import Photos

enum PhotoLibraryWriterError: LocalizedError {
    case authorizationDenied
    case authorizationRestricted
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "The photo library refused to add the export. Allow 'Add Photos' in the Settings of the app."
        case .authorizationRestricted:
            return "This device does not allow the app to add photos to the library."
        case let .saveFailed(reason):
            return "The export could not be saved to the photo library: \(reason)"
        }
    }
}

enum PhotoLibraryWriter {

    /// The authorization of the **add only** access of the library.
    ///
    /// The read access of the library is never requested.
    static func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    /// Requests the add-only authorization of the library.
    static func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Saves the encoded export into the photo library.
    ///
    /// The authorization is asked for only when it has not been decided yet;
    /// a refusal is an error, never a crash.
    static func save(data: Data, format: ExportFormat) async throws {
        var status = authorizationStatus()
        if status == .notDetermined {
            status = await requestAuthorization()
        }
        switch status {
        case .authorized:
            break
        case .restricted:
            throw PhotoLibraryWriterError.authorizationRestricted
        default:
            throw PhotoLibraryWriterError.authorizationDenied
        }
        try await performChanges(data: data, format: format)
    }

    /// The creation request of the asset.
    ///
    /// `PHAssetCreationRequest` is only valid inside the change block of
    /// `performChanges`, so it cannot be built outside of it.
    private static func performChanges(data: Data, format: ExportFormat) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = ExportImageEncoder.typeIdentifier(for: format)
                request.addResource(with: .photo, data: data, options: options)
            }) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(
                        throwing: PhotoLibraryWriterError.saveFailed(
                            error?.localizedDescription ?? "the photo library refused the asset"
                        )
                    )
                }
            }
        }
    }
}
