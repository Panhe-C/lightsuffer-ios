import CoreGraphics
import FilmPhysics
import Foundation
import ImageIO
import LightSufferPreview

/// Immutable Core Graphics images are safe to hand back to the main actor.
struct PreparedPhoto: @unchecked Sendable {
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
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoDecoderError.unreadablePhoto
        }
        guard let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PhotoDecoderError.missingImage
        }
        guard sourceImage.width > 0, sourceImage.height > 0 else {
            throw PhotoDecoderError.missingDimensions
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let targetSize = try PreviewGeometry.targetSize(
            width: sourceImage.width,
            height: sourceImage.height,
            exifOrientation: orientation
        )

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: PreviewGeometry.defaultLongEdge,
        ]
        guard let upright = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else {
            throw PhotoDecoderError.missingImage
        }

        // Drawing into an explicit sRGB RGBA context both finishes any needed
        // upscale and gives the pixel converter a known colour space/layout.
        let converted = try CGImagePixels.decode(upright, to: targetSize)
        return PreparedPhoto(
            original: converted.displayImage,
            input: converted.pixels.linearProPhotoRGB()
        )
    }
}
