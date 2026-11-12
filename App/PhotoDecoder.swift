import CoreGraphics
import CoreImage
import FilmPhysics
import Foundation
import ImageIO
import LightSufferPreview
import UniformTypeIdentifiers

/// Original encoded bytes and source metadata are retained for every later
/// input-policy decode and for the separate full-resolution export decode.
struct PhotoSource: @unchecked Sendable {
    let data: Data
    let properties: [CFString: Any]
    let orientation: UInt32
    let kind: PhotoKind
    let typeIdentifier: String?
    let filename: String?
}

/// Immutable Core Graphics images and value-type pixels are safe to hand back
/// to the main actor. The dictionary in PhotoSource is the unchecked part.
struct PreparedPhoto: @unchecked Sendable {
    let source: PhotoSource
    let sourceSize: PreviewSize
    let original: CGImage
    let input: RGBImage
    let inputSettings: PhotoInputSettings
    let inputStatus: String

    var kind: PhotoKind { source.kind }
}

enum PhotoDecoderError: LocalizedError {
    case unreadablePhoto
    case missingImage
    case missingDimensions
    case rawDemosaicUnavailable
    case rawOutputUnavailable

    var errorDescription: String? {
        switch self {
        case .unreadablePhoto:
            return "The selected photo could not be read."
        case .missingImage:
            return "The selected photo has no decodable image."
        case .missingDimensions:
            return "The selected photo has no valid dimensions."
        case .rawDemosaicUnavailable:
            return "This looks like a RAW, ProRAW or DNG photo, but CIRAWFilter could not open it. The file was not silently decoded as an 8-bit processed image."
        case .rawOutputUnavailable:
            return "CIRAWFilter opened this RAW photo but could not produce a scene-linear image."
        }
    }
}

enum PhotoDecoder {

    /// Decodes the complete image, applies EXIF orientation, colour-manages to
    /// floating-point linear RGB, and fits the whole frame to 1280 px.
    static func decode(
        data: Data,
        typeIdentifier: String? = nil,
        filename: String? = nil,
        settings: PhotoInputSettings = PhotoInputSettings()
    ) throws -> PreparedPhoto {
        try decode(
            data: data,
            typeIdentifier: typeIdentifier,
            filename: filename,
            settings: settings,
            longEdge: PreviewGeometry.defaultLongEdge
        )
    }

    /// A separate export decode from the original bytes. Every EXIF-upright
    /// source pixel is retained; the preview's 1280 px cap is not reused.
    static func decodeFullResolution(
        photo: PreparedPhoto,
        settings: PhotoInputSettings? = nil
    ) throws -> PreparedPhoto {
        try FramedImageRenderer.checkSize(
            width: photo.sourceSize.width,
            height: photo.sourceSize.height
        )
        return try decode(
            data: photo.source.data,
            typeIdentifier: photo.source.typeIdentifier,
            filename: photo.source.filename,
            settings: settings ?? photo.inputSettings,
            longEdge: nil
        )
    }

    private static func decode(
        data: Data,
        typeIdentifier: String?,
        filename: String?,
        settings: PhotoInputSettings,
        longEdge: Int?
    ) throws -> PreparedPhoto {
        // Resolve the I/O policy before any pixels reach the engine. Unknown
        // names and invalid custom WB fail here, not after a wrong-colour render.
        _ = try settings.resolvedInputColorSpace
        _ = try settings.resolvedWhiteBalance()

        let imageSource = CGImageSourceCreateWithData(data as CFData, nil)
        let sourceType = imageSource.flatMap { CGImageSourceGetType($0) as String? }
        let hintedKind = PhotoKind.detect(
            typeIdentifier: typeIdentifier,
            filename: filename,
            data: data
        )
        let detectedKind = PhotoKind.detect(
            typeIdentifier: sourceType ?? typeIdentifier,
            filename: filename,
            data: data
        )
        var properties = imageSource.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        } ?? [:]

        let rawMetadata = properties[kCGImagePropertyDNGDictionary] != nil ||
            properties["{Raw}" as CFString] != nil
        let requiresRAW = hintedKind.isRAW || detectedKind.isRAW || rawMetadata ||
            isRAWTypeIdentifier(typeIdentifier) || isRAWTypeIdentifier(sourceType)
        // HEIC must be probed because ProRAW can be HEIC-wrapped. JPEG and PNG
        // remain on Image I/O unless another explicit RAW hint contradicts them.
        let shouldProbeRAW = requiresRAW || detectedKind == .heic || detectedKind == .unknown
        let rawFilter = shouldProbeRAW ? CIRAWFilter(
            imageData: data,
            identifierHint: sourceType ?? typeIdentifier
        ) : nil
        if requiresRAW, rawFilter == nil {
            throw PhotoDecoderError.rawDemosaicUnavailable
        }

        if let rawFilter {
            if properties.isEmpty {
                for (key, value) in rawFilter.properties {
                    guard let stringKey = key as? String else { continue }
                    properties[stringKey as CFString] = value
                }
            }
            let kind = rawKind(
                detected: requiresRAW && hintedKind.isRAW ? hintedKind : detectedKind,
                sourceType: sourceType ?? typeIdentifier,
                properties: properties
            )
            return try decodeRAW(
                rawFilter,
                data: data,
                kind: kind,
                typeIdentifier: sourceType ?? typeIdentifier,
                filename: filename,
                properties: properties,
                settings: settings,
                longEdge: longEdge
            )
        }

        // A candidate that did not require RAW (notably ordinary HEIC) may
        // continue through Image I/O only when CIRAWFilter did not claim it.
        guard let imageSource else { throw PhotoDecoderError.unreadablePhoto }
        guard let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw PhotoDecoderError.missingImage
        }
        guard sourceImage.width > 0, sourceImage.height > 0 else {
            throw PhotoDecoderError.missingDimensions
        }

        let orientation = exifOrientation(properties: properties)
        let orientedSize = try PreviewGeometry.orientedSize(
            width: sourceImage.width,
            height: sourceImage.height,
            exifOrientation: orientation
        )
        let targetSize = try targetSize(
            sourceWidth: sourceImage.width,
            sourceHeight: sourceImage.height,
            orientation: orientation,
            orientedSize: orientedSize,
            longEdge: longEdge
        )

        var thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let longEdge {
            thumbnailOptions[kCGImageSourceThumbnailMaxPixelSize] = longEdge
        }
        guard let upright = CGImageSourceCreateThumbnailAtIndex(
            imageSource, 0, thumbnailOptions as CFDictionary
        ) else {
            throw PhotoDecoderError.missingImage
        }

        // ColorSync honours the embedded profile while rendering into an
        // extended floating-point linear-sRGB buffer. No 8-bit sRGB engine pass.
        let converted = try CGImagePixels.decode(upright, to: targetSize)
        let input = try engineInput(from: converted.linearSRGB, settings: settings)
        let kind = detectedKind == .unknown ? hintedKind : detectedKind
        let status = try statusString(
            kind: kind,
            settings: settings,
            decoder: "Image I/O + ColorSync floating-point decode."
        )
        return PreparedPhoto(
            source: PhotoSource(
                data: data,
                properties: properties,
                orientation: orientation,
                kind: kind,
                typeIdentifier: sourceType ?? typeIdentifier,
                filename: filename
            ),
            sourceSize: orientedSize,
            original: converted.displayImage,
            input: input,
            inputSettings: settings,
            inputStatus: status
        )
    }

    private static func decodeRAW(
        _ filter: CIRAWFilter,
        data: Data,
        kind: PhotoKind,
        typeIdentifier: String?,
        filename: String?,
        properties: [CFString: Any],
        settings: PhotoInputSettings,
        longEdge: Int?
    ) throws -> PreparedPhoto {
        let nativeWidth = Int(filter.nativeSize.width.rounded())
        let nativeHeight = Int(filter.nativeSize.height.rounded())
        guard nativeWidth > 0, nativeHeight > 0 else {
            throw PhotoDecoderError.missingDimensions
        }
        let orientation = exifOrientation(properties: properties)
        let orientedSize = try PreviewGeometry.orientedSize(
            width: nativeWidth,
            height: nativeHeight,
            exifOrientation: orientation
        )
        let target = try targetSize(
            sourceWidth: nativeWidth,
            sourceHeight: nativeHeight,
            orientation: orientation,
            orientedSize: orientedSize,
            longEdge: longEdge
        )

        filter.orientation = CGImagePropertyOrientation(rawValue: orientation) ?? .up
        filter.isDraftModeEnabled = false
        let decodeScale = min(
            1.0,
            Double(target.width) / Double(orientedSize.width)
        )
        filter.scaleFactor = Float(decodeScale)

        // iOS 17 CIRAWFilter scene-linear policy. Zero global/local tone
        // curves, baseline exposure and EDR; zero user exposure/shadow bias.
        // Disabling gamut mapping preserves out-of-range scene components for
        // the later floating-point ColorSync conversion.
        filter.exposure = 0
        filter.baselineExposure = 0
        filter.shadowBias = 0
        filter.boostAmount = 0
        filter.boostShadowAmount = 1 // inert when boostAmount is zero
        filter.localToneMapAmount = 0
        filter.contrastAmount = 0
        filter.detailAmount = 0
        filter.extendedDynamicRangeAmount = 0
        filter.isGamutMappingEnabled = false

        let whiteBalance = try settings.resolvedWhiteBalance()
        if !whiteBalance.usesCameraWhiteBalance {
            // Typed iOS 15+ properties, backed by inputNeutralTemperature and
            // inputNeutralTint. As-shot deliberately leaves both untouched.
            if let temperature = whiteBalance.neutralTemperature {
                filter.neutralTemperature = Float(temperature)
            }
            filter.neutralTint = Float(whiteBalance.neutralTint ?? 0)
        }
        guard let output = filter.outputImage else {
            throw PhotoDecoderError.rawOutputUnavailable
        }

        // CIRAWFilter output is colour-managed to extended linear sRGB and
        // rendered as 32-bit floats, then matrix-converted without clipping to
        // linear ProPhoto (or retained as linear sRGB for native sRGB input).
        let converted = try CGImagePixels.decode(output, to: target)
        let input = try engineInput(from: converted.linearSRGB, settings: settings)
        let status = try statusString(
            kind: kind,
            settings: settings,
            decoder: "CIRAWFilter scene-linear demosaic; boost, global/local tone mapping, local contrast/detail, baseline exposure and EDR are off. White balance: \(settings.whiteBalanceMode.displayName)."
        )
        return PreparedPhoto(
            source: PhotoSource(
                data: data,
                properties: properties,
                orientation: orientation,
                kind: kind,
                typeIdentifier: typeIdentifier,
                filename: filename
            ),
            sourceSize: orientedSize,
            original: converted.displayImage,
            input: input,
            inputSettings: settings,
            inputStatus: status
        )
    }

    private static func targetSize(
        sourceWidth: Int,
        sourceHeight: Int,
        orientation: UInt32,
        orientedSize: PreviewSize,
        longEdge: Int?
    ) throws -> PreviewSize {
        try longEdge.map {
            try PreviewGeometry.targetSize(
                width: sourceWidth,
                height: sourceHeight,
                exifOrientation: orientation,
                longEdge: $0
            )
        } ?? orientedSize
    }

    private static func engineInput(
        from linearSRGB: RGBImage,
        settings: PhotoInputSettings
    ) throws -> RGBImage {
        let resolution = try settings.resolvedInputColorSpace
        if resolution.engine.inputColorSpace == "sRGB" {
            // Chosen native-sRGB policy: linear pixels, CCTF decoding off.
            return linearSRGB
        }
        // Automatic, explicit ProPhoto, and every documented fallback arrive
        // here. Do not clamp: wide-gamut colours may use negative sRGB values.
        let matrix = ColourScience.matrixRGBToRGB(from: .sRGB, to: .proPhotoRGB)
        var output: [Double] = []
        output.reserveCapacity(linearSRGB.data.count)
        for offset in stride(from: 0, to: linearSRGB.data.count, by: 3) {
            let rgb = [
                linearSRGB.data[offset],
                linearSRGB.data[offset + 1],
                linearSRGB.data[offset + 2],
            ]
            output.append(contentsOf: Colour.multiply(matrix: matrix, vector: rgb))
        }
        return RGBImage(
            width: linearSRGB.width,
            height: linearSRGB.height,
            data: output
        )
    }

    private static func statusString(
        kind: PhotoKind,
        settings: PhotoInputSettings,
        decoder: String
    ) throws -> String {
        "\(decoder) \(try settings.status(for: kind))"
    }

    private static func exifOrientation(properties: [CFString: Any]) -> UInt32 {
        let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return (1...8).contains(raw) ? raw : 1
    }

    private static func isRAWTypeIdentifier(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        if PhotoKind.detect(typeIdentifier: identifier).isRAW { return true }
        return UTType(identifier)?.conforms(to: .rawImage) ?? false
    }

    private static func rawKind(
        detected: PhotoKind,
        sourceType: String?,
        properties: [CFString: Any]
    ) -> PhotoKind {
        if detected == .proraw || isProRAWType(sourceType) { return .proraw }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let make = tiff?[kCGImagePropertyTIFFMake] as? String
        let isAppleDNG = properties[kCGImagePropertyDNGDictionary] != nil &&
            make?.localizedCaseInsensitiveContains("Apple") == true
        // A HEIC accepted by CIRAWFilter is the HEIC-wrapped ProRAW case;
        // ordinary HEIC never reaches this branch.
        if detected == .heic || isAppleDNG { return .proraw }
        return .dng
    }

    private static func isProRAWType(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return PhotoKind.detect(typeIdentifier: identifier) == .proraw
    }
}
