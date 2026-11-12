//
//  PreviewGeometry.swift
//  light suffer胶片 — preview support
//
//  Platform-neutral EXIF orientation and preview sizing.  The app gives the
//  orientation to Image I/O, which performs the actual pixel rotation; these
//  functions define and test the upright dimensions independently of UIKit.
//

import Foundation

/// An integer pixel size.
public struct PreviewSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public enum PreviewGeometryError: Error, Equatable {
    case invalidDimensions
    case invalidLongEdge
}

/// Geometry for a whole-frame, EXIF-upright preview.
public enum PreviewGeometry {

    /// The long edge used by the first app-shell preview.
    public static let defaultLongEdge = 1280

    /// Returns the dimensions after applying an EXIF orientation.
    ///
    /// EXIF values 5 through 8 transpose the image and therefore exchange
    /// width and height.  Unknown values are treated as 1 (up), matching the
    /// usual Image I/O fallback for missing or invalid orientation metadata.
    public static func orientedSize(
        width: Int,
        height: Int,
        exifOrientation: UInt32 = 1
    ) throws -> PreviewSize {
        guard width > 0, height > 0 else {
            throw PreviewGeometryError.invalidDimensions
        }
        if (5...8).contains(exifOrientation) {
            return PreviewSize(width: height, height: width)
        }
        return PreviewSize(width: width, height: height)
    }

    /// Fits the whole upright image to an exact long edge, preserving aspect
    /// ratio and rounding the short edge to its nearest pixel.
    public static func targetSize(
        width: Int,
        height: Int,
        exifOrientation: UInt32 = 1,
        longEdge: Int = PreviewGeometry.defaultLongEdge
    ) throws -> PreviewSize {
        guard longEdge > 0 else {
            throw PreviewGeometryError.invalidLongEdge
        }
        let upright = try orientedSize(
            width: width, height: height, exifOrientation: exifOrientation
        )
        let sourceLongEdge = max(upright.width, upright.height)
        let sourceShortEdge = min(upright.width, upright.height)
        let shortEdge = max(
            1,
            Int(
                (Double(sourceShortEdge) * Double(longEdge) / Double(sourceLongEdge)).rounded()
            )
        )
        if upright.width >= upright.height {
            return PreviewSize(width: longEdge, height: shortEdge)
        }
        return PreviewSize(width: shortEdge, height: longEdge)
    }
}
