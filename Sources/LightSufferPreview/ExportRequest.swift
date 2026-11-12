//
//  ExportRequest.swift
//  Full-resolution export planning, shared by iOS and Linux tests.
//

import FilmPhysics
import Foundation
import FrameCore

/// The two lossy still-image formats offered by the iOS exporter.
public enum ExportFormat: String, CaseIterable, Codable, Hashable, Sendable {
    case jpeg
    case heic

    public var displayName: String { rawValue.uppercased() }
}

/// Platform-neutral orientation and metadata policy for one encoded export.
///
/// Image I/O applies `sourceOrientation` while decoding. The encoded image is
/// therefore already upright, and every orientation tag is reset to 1. All
/// other metadata groups are carried through by the Apple adapter, except for
/// dimensions and other read-only container identity keys.
public struct ExportMetadataPlan: Equatable, Sendable {
    public let sourceOrientation: UInt32
    public let outputOrientation: UInt32
    public let bakesSourceOrientationIntoPixels: Bool
    public let carriesRemainingMetadata: Bool
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        sourceOrientation: UInt32,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws {
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw ExportRequestError.invalidDimensions
        }
        self.sourceOrientation = (1...8).contains(sourceOrientation) ? sourceOrientation : 1
        self.outputOrientation = 1
        self.bakesSourceOrientationIntoPixels = true
        self.carriesRemainingMetadata = true
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Raw Image I/O dictionary names, duplicated here so the policy can be
    /// tested without importing ImageIO on Linux.
    public static let exifDictionaryKey = "{Exif}"
    public static let tiffDictionaryKey = "{TIFF}"
    public static let gpsDictionaryKey = "{GPS}"
    public static let iptcDictionaryKey = "{IPTC}"
    public static let orientationKey = "Orientation"
    public static let pixelWidthKey = "PixelWidth"
    public static let pixelHeightKey = "PixelHeight"
    public static let exifPixelXDimensionKey = "PixelXDimension"
    public static let exifPixelYDimensionKey = "PixelYDimension"

    /// TIFF container keys which Image I/O must regenerate rather than copy.
    public static let readOnlyTIFFKeys = [
        "ImageWidth", "ImageLength", "BitsPerSample", "SampleFormat",
        "PhotometricInterpretation", "SamplesPerPixel", "RowsPerStrip",
        "StripByteCounts", "PlanarConfiguration", "ColorMap",
    ]
}

public enum ExportRequestError: LocalizedError, Equatable {
    case invalidDimensions

    public var errorDescription: String? {
        "The export dimensions must be positive."
    }
}

/// An immutable snapshot of everything needed by a full-resolution export.
/// BorderStyle is a trivial raw-value enum; the unchecked Sendable conformance
/// avoids changing the vendored FrameCore source solely for a marker protocol.
public struct ExportRequest: @unchecked Sendable {
    public static let defaultQuality = 0.92
    public static let offeredBorderStyles: [BorderStyle] = [
        .none, .film120, .edgeBlackThin, .edgeWhiteThin, .edgeBlack, .edgeWhite,
    ]

    public let look: StockCatalog.Look
    public let adjustments: PreviewAdjustments
    public let inputSettings: PhotoInputSettings
    public let format: ExportFormat
    public let quality: Double
    public let borderStyle: BorderStyle
    public let stockName: String
    public let sourceOrientation: UInt32

    public init(
        look: StockCatalog.Look,
        adjustments: PreviewAdjustments,
        inputSettings: PhotoInputSettings = PhotoInputSettings(),
        format: ExportFormat = .jpeg,
        quality: Double = ExportRequest.defaultQuality,
        borderStyle: BorderStyle = .none,
        stockName: String? = nil,
        sourceOrientation: UInt32 = 1
    ) {
        self.look = look
        self.adjustments = adjustments
        self.inputSettings = inputSettings
        self.format = format
        self.quality = quality.isFinite ? min(1, max(0.01, quality)) : Self.defaultQuality
        self.borderStyle = borderStyle
        self.stockName = stockName ?? look.film.name
        self.sourceOrientation = (1...8).contains(sourceOrientation) ? sourceOrientation : 1
    }

    /// Uses the exact same stock digest, physical adjustments and input tags
    /// as preview. The Apple export decoder applies the same input settings to
    /// a fresh full-resolution decode of the original bytes.
    public func pipelineParams() throws -> PipelineParams {
        try PreviewLook.pipelineParams(
            for: look,
            adjustments: adjustments,
            inputSettings: inputSettings
        )
    }

    /// Computes margins around the original, uncropped full-resolution grade.
    public func borderLayout(photoW: Int, photoH: Int) throws -> Layout {
        try BorderLayout.compute(style: borderStyle, photoW: photoW, photoH: photoH)
    }

    public var paintOptions: PaintOptions {
        PaintOptions(stockName: stockName)
    }

    public func metadataPlan(pixelWidth: Int, pixelHeight: Int) throws -> ExportMetadataPlan {
        try ExportMetadataPlan(
            sourceOrientation: sourceOrientation,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}

public enum ExportProgressStage: String, Equatable, Sendable {
    case decoding
    case planning
    case rendering
    case framing
    case encoding
    case saving
}

public struct ExportProgress: Equatable, Sendable {
    public let stage: ExportProgressStage
    public let fractionCompleted: Double
    public let completedTiles: Int
    public let totalTiles: Int

    public init(
        stage: ExportProgressStage,
        fractionCompleted: Double,
        completedTiles: Int = 0,
        totalTiles: Int = 0
    ) {
        self.stage = stage
        self.fractionCompleted = min(1, max(0, fractionCompleted))
        self.completedTiles = completedTiles
        self.totalTiles = totalTiles
    }
}

public enum ExportPipelineError: LocalizedError, Equatable {
    case cancelled

    public var errorDescription: String? { "Export cancelled." }
}

/// Cooperative cancellation between decode, tiles, framing, encoding and save.
/// A synchronous engine render already in flight is allowed to return, just as
/// in the preview generation discipline; its result is then discarded.
public final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func check() throws {
        if isCancelled { throw ExportPipelineError.cancelled }
    }
}
