import CoreGraphics
import Foundation
import LightSufferPreview

enum CGImagePixelsError: LocalizedError {
    case sRGBUnavailable
    case contextCreationFailed
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .sRGBUnavailable:
            return "The sRGB colour space is unavailable."
        case .contextCreationFailed:
            return "A pixel buffer could not be created for the preview."
        case .imageCreationFailed:
            return "The preview image could not be created."
        }
    }
}

/// Core Graphics adapter for the platform-neutral sRGB pixel buffer.
enum CGImagePixels {

    /// Returns an upright, sRGB display image and its tightly packed RGB
    /// pixels.  The context uses RGBA with a known row stride; alpha is dropped
    /// by `SRGBPixelBuffer` before the pixels enter the film engine.
    static func decode(
        _ image: CGImage,
        to size: PreviewSize
    ) throws -> (displayImage: CGImage, pixels: SRGBPixelBuffer) {
        guard let colourSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CGImagePixelsError.sRGBUnavailable
        }
        let bytesPerRow = size.width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * size.height)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )

        return try rgba.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: size.width,
                height: size.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colourSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else {
                throw CGImagePixelsError.contextCreationFailed
            }
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: size.width, height: size.height)
            )
            guard let displayImage = context.makeImage() else {
                throw CGImagePixelsError.imageCreationFailed
            }
            let pixels = try SRGBPixelBuffer(
                width: size.width,
                height: size.height,
                rgba: Array(rawBuffer.bindMemory(to: UInt8.self)),
                bytesPerRow: bytesPerRow
            )
            return (displayImage, pixels)
        }
    }

    /// Creates a display image from encoded-sRGB pixels returned by the
    /// default film pipeline.  No second transfer-function conversion occurs.
    static func makeImage(from pixels: SRGBPixelBuffer) throws -> CGImage {
        guard let colourSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CGImagePixelsError.sRGBUnavailable
        }
        let providerData = Data(pixels.rgbaBytes()) as CFData
        guard let provider = CGDataProvider(data: providerData) else {
            throw CGImagePixelsError.imageCreationFailed
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let image = CGImage(
            width: pixels.width,
            height: pixels.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pixels.width * 4,
            space: colourSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw CGImagePixelsError.imageCreationFailed
        }
        return image
    }
}
