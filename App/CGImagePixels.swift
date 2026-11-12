import CoreGraphics
import CoreImage
import FilmPhysics
import Foundation
import LightSufferPreview

enum CGImagePixelsError: LocalizedError {
    case linearSRGBUnavailable
    case invalidDimensions
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .linearSRGBUnavailable:
            return "The extended linear sRGB working colour space is unavailable."
        case .invalidDimensions:
            return "The decoded image has invalid or excessively large dimensions."
        case .imageCreationFailed:
            return "The preview image could not be created."
        }
    }
}

/// Core Image / ColorSync adapter for the platform-neutral display buffer.
/// Engine input is never drawn into an 8-bit sRGB context: embedded profiles
/// and CIRAWFilter output are rendered as floating-point extended linear sRGB.
enum CGImagePixels {

    /// Returns an sRGB display image and scene-linear floating-point RGB.
    /// Extended linear sRGB permits negative and greater-than-one components,
    /// so the subsequent matrix conversion to ProPhoto does not silently clip
    /// a wide-gamut source to 8-bit sRGB. Display conversion alone clamps.
    static func decode(
        _ image: CGImage,
        to size: PreviewSize
    ) throws -> (displayImage: CGImage, linearSRGB: RGBImage) {
        try decode(CIImage(cgImage: image), to: size)
    }

    /// Renders an Image I/O or CIRAWFilter image to an exact target size.
    /// `CIContext.render(... format: .RGBAf ...)` is the floating-point /
    /// ColorSync boundary; no 8-bit encoded-sRGB engine-input pass remains.
    static func decode(
        _ image: CIImage,
        to size: PreviewSize
    ) throws -> (displayImage: CGImage, linearSRGB: RGBImage) {
        guard size.width > 0, size.height > 0 else {
            throw CGImagePixelsError.invalidDimensions
        }
        let (pixelCount, pixelOverflow) = size.width.multipliedReportingOverflow(by: size.height)
        let (componentCount, componentOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        let (bytesPerRow, rowOverflow) = size.width.multipliedReportingOverflow(
            by: 4 * MemoryLayout<Float>.stride
        )
        guard !pixelOverflow, !componentOverflow, !rowOverflow else {
            throw CGImagePixelsError.invalidDimensions
        }
        guard let colourSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            throw CGImagePixelsError.linearSRGBUnavailable
        }

        let sourceExtent = image.extent
        guard sourceExtent.width.isFinite, sourceExtent.height.isFinite,
              sourceExtent.width > 0, sourceExtent.height > 0,
              !sourceExtent.isInfinite, !sourceExtent.isNull else {
            throw CGImagePixelsError.imageCreationFailed
        }

        // One affine transform maps the source extent's origin to (0, 0) and
        // its size to PreviewGeometry's exact whole-frame target dimensions.
        let scaleX = CGFloat(size.width) / sourceExtent.width
        let scaleY = CGFloat(size.height) / sourceExtent.height
        let transform = CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: -sourceExtent.minX * scaleX,
            ty: -sourceExtent.minY * scaleY
        )
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let fitted = image.transformed(by: transform).cropped(to: bounds)
        let context = CIContext(options: [
            .workingColorSpace: colourSpace,
            .outputColorSpace: colourSpace,
            .cacheIntermediates: false,
        ])

        var rgba = [Float](repeating: 0, count: componentCount)
        rgba.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            context.render(
                fitted,
                toBitmap: baseAddress,
                rowBytes: bytesPerRow,
                bounds: bounds,
                format: .RGBAf,
                colorSpace: colourSpace
            )
        }

        var rgb: [Double] = []
        rgb.reserveCapacity(pixelCount * 3)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            rgb.append(Double(rgba[offset]))
            rgb.append(Double(rgba[offset + 1]))
            rgb.append(Double(rgba[offset + 2]))
        }
        let linear = RGBImage(width: size.width, height: size.height, data: rgb)
        return (try makeDisplayImage(linearSRGB: linear), linear)
    }

    /// Converts linear-sRGB input to the display-only encoded-sRGB image used
    /// by hold-to-compare. This clamp is intentionally after the engine input
    /// has been retained as floating point; it is not an engine-input clip.
    static func makeDisplayImage(linearSRGB: RGBImage) throws -> CGImage {
        let bytes = linearSRGB.data.map { value -> UInt8 in
            if value.isNaN { return 0 }
            let encoded = Colour.sRGBEncode(value)
            if encoded.isNaN { return 0 }
            let clamped = min(1.0, max(0.0, encoded))
            return UInt8((clamped * 255.0).rounded())
        }
        let pixels = try SRGBPixelBuffer(
            width: linearSRGB.width,
            height: linearSRGB.height,
            rgb: bytes
        )
        return try makeImage(from: pixels)
    }

    /// Creates a display image from encoded-sRGB pixels returned by the
    /// default film pipeline. No second transfer-function conversion occurs.
    static func makeImage(from pixels: SRGBPixelBuffer) throws -> CGImage {
        guard let colourSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CGImagePixelsError.linearSRGBUnavailable
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
