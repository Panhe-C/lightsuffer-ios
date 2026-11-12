import CoreGraphics
import FilmPhysics
import Foundation
import ImageIO
import LightSufferPreview

/// Original encoded bytes and source metadata are retained for the separate
/// full-resolution export decode. The preview itself remains capped at 1280 px.
struct PhotoSource: @unchecked Sendable {
    let data: Data
    let properties: [CFString: Any]
    let orientation: UInt32
}

/// Immutable Core Graphics images are safe to hand back to the main actor.
struct PreparedPhoto: @unchecked Sendable {
    let source: PhotoSource
    let sourceSize: PreviewSize
    let original: CGImage
    let input: RGBImage
}

enum PhotoDecoderError: LocalizedError {
    case unreadablePhoto
    case missingImage
    case missingDimensions

    var errorDescription: String? {
        switch self {
        case .unreadablePhoto:
            return "The selected photo could not be read."
        case .missingImage:
            return "The selected photo has no decodable image."
        case .missingDimensions:
            return "The selected photo has no valid dimensions."
        }
    }
}

enum PhotoDecoder {

    /// Decodes the complete image, applies EXIF orientation through Image I/O,
    /// and normalizes the display pixels to sRGB at an exact 1280px long edge.
    /// No crop thumbnail option is used: the thumbnail is always generated
    /// from the full source frame.
    static func decode(data: Data) throws -> PreparedPhoto {
        try decode(data: data, longEdge: PreviewGeometry.defaultLongEdge)
    }

    /// A separate export decode: every EXIF-upright source pixel is retained;
    /// the preview's 1280 px cap is deliberately not applied. The only size
    /// guard is the documented 400 MP absurd-output safety limit.
    static func decodeFullResolution(photo: PreparedPhoto) throws -> PreparedPhoto {
        try FramedImageRenderer.checkSize(
            width: photo.sourceSize.width,
            height: photo.sourceSize.height
        )
        return try decode(data: photo.source.data, longEdge: nil)
    }

    private static func decode(data: Data, longEdge: Int?) throws -> PreparedPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoDecoderError.unreadablePhoto
        }
        guard let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PhotoDecoderError.missingImage
        }
        guard sourceImage.width > 0, sourceImage.height > 0 else {
            throw PhotoDecoderError.missingDimensions
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let rawOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation: UInt32 = (1...8).contains(rawOrientation) ? rawOrientation : 1
        let orientedSize = try PreviewGeometry.orientedSize(
            width: sourceImage.width,
            height: sourceImage.height,
            exifOrientation: orientation
        )
        let targetSize = try longEdge.map {
            try PreviewGeometry.targetSize(
                width: sourceImage.width,
                height: sourceImage.height,
                exifOrientation: orientation,
                longEdge: $0
            )
        } ?? orientedSize

        var thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let longEdge {
            thumbnailOptions[kCGImageSourceThumbnailMaxPixelSize] = longEdge
        }
        guard let upright = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else {
            throw PhotoDecoderError.missingImage
        }

        // Drawing into an explicit sRGB RGBA context finishes any preview
        // scaling and gives the pixel converter a known colour space/layout.
        // At full resolution this is a 1:1 draw of the upright source.
        let converted = try CGImagePixels.decode(upright, to: targetSize)
        return PreparedPhoto(
            source: PhotoSource(data: data, properties: properties, orientation: orientation),
            sourceSize: orientedSize,
            original: converted.displayImage,
            input: converted.pixels.linearProPhotoRGB()
        )
    }

}
