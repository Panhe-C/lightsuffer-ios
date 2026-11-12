import CoreGraphics
import Foundation
import ImageIO
import LightSufferPreview
import UniformTypeIdentifiers

/// Image I/O encoding adapted from FrameKit/ImageExporter.swift @ f6de465.
/// Source pixels have already been EXIF-uprighted by PhotoDecoder.
enum ExportImageEncoder {
    static func encode(
        image: CGImage,
        request: ExportRequest,
        sourceProperties: [CFString: Any]
    ) throws -> Data {
        let typeIdentifier = typeIdentifier(for: request.format)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw ExportImageEncoderError.cannotCreate(request.format)
        }

        let metadataPlan = try request.metadataPlan(
            pixelWidth: image.width,
            pixelHeight: image.height
        )
        var properties = metadata(
            from: sourceProperties,
            plan: metadataPlan
        )
        // Both user-selectable formats are lossy. JPEG follows the
        // mini-program default q=0.92; HEIC uses the same explicit quality.
        properties[kCGImageDestinationLossyCompressionQuality] = request.quality
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportImageEncoderError.cannotWrite(request.format)
        }
        return output as Data
    }

    /// The uniform type identifier of a format.
    static func typeIdentifier(for format: ExportFormat) -> String {
        switch format {
        case .jpeg: return UTType.jpeg.identifier
        case .heic: return UTType.heic.identifier
        }
    }

    /// Carries EXIF, GPS, IPTC and all other source groups through, replacing
    /// orientation/dimensions and dropping read-only container identity keys.
    static func metadata(
        from source: [CFString: Any],
        plan: ExportMetadataPlan
    ) -> [CFString: Any] {
        var properties = source
        properties[kCGImagePropertyOrientation] = plan.outputOrientation
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)

        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = plan.pixelWidth
        exif[kCGImagePropertyExifPixelYDimension] = plan.pixelHeight
        // Some SDKs do not export an EXIF Orientation constant.
        exif[ExportMetadataPlan.orientationKey as CFString] = plan.outputOrientation
        properties[kCGImagePropertyExifDictionary] = exif

        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = plan.outputOrientation
        tiff[kCGImagePropertyTIFFXResolution] = tiff[kCGImagePropertyTIFFXResolution] ?? 72
        tiff[kCGImagePropertyTIFFYResolution] = tiff[kCGImagePropertyTIFFYResolution] ?? 72
        tiff[kCGImagePropertyTIFFResolutionUnit] = tiff[kCGImagePropertyTIFFResolutionUnit] ?? 2
        for key in ExportMetadataPlan.readOnlyTIFFKeys {
            tiff.removeValue(forKey: key as CFString)
        }
        properties[kCGImagePropertyTIFFDictionary] = tiff
        return properties
    }
}

enum ExportImageEncoderError: LocalizedError {
    case cannotCreate(ExportFormat)
    case cannotWrite(ExportFormat)

    var errorDescription: String? {
        switch self {
        case let .cannotCreate(format):
            return "This device cannot create a \(format.displayName) export."
        case let .cannotWrite(format):
            return "The \(format.displayName) export could not be encoded."
        }
    }
}
