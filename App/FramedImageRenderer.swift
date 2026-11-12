import CoreGraphics
import Foundation
import FrameCore
import LightSufferPreview

/// Core Graphics placement of an already upright, encoded-sRGB grade into the
/// unmodified FrameCore painter. The full-resolution path draws 1:1: the photo
/// is never cropped or resampled to make room for a border.
enum FramedImageRenderer {
    static let maximumPixels = 400_000_000

    static func renderFull(
        photo: CGImage,
        layout: Layout,
        paint: PaintOptions
    ) throws -> CGImage {
        guard photo.width == layout.photoW, photo.height == layout.photoH else {
            throw FramedImageRendererError.dimensionMismatch
        }
        try checkSize(width: layout.outerW, height: layout.outerH)
        if layout.style == .none { return photo }

        let context = try makeContext(width: layout.outerW, height: layout.outerH)
        context.interpolationQuality = .none
        prepareTopDown(context, width: layout.outerW, height: layout.outerH)
        drawPhoto(photo, in: context, layout: layout, destinationSize: nil)
        BorderPainter.draw(on: CGCanvas(context: context), layout: layout, options: resolved(paint))
        guard let image = context.makeImage() else { throw FramedImageRendererError.imageFailed }
        return image
    }

    /// Uses the full-source layout and scales the complete canvas for preview.
    /// The underlying film grade remains the existing 1280 px preview render.
    static func renderPreview(
        photo: CGImage,
        sourceSize: PreviewSize,
        style: BorderStyle,
        stockName: String,
        longEdge: Int = PreviewGeometry.defaultLongEdge
    ) throws -> CGImage {
        if style == .none { return photo }
        let layout = try BorderLayout.compute(
            style: style,
            photoW: sourceSize.width,
            photoH: sourceSize.height
        )
        let outerLongEdge = max(layout.outerW, layout.outerH)
        let scale = Double(max(16, longEdge)) / Double(outerLongEdge)
        let width = max(1, Int((Double(layout.outerW) * scale).rounded()))
        let height = max(1, Int((Double(layout.outerH) * scale).rounded()))
        let context = try makeContext(width: width, height: height)
        context.interpolationQuality = .high
        prepareTopDown(context, width: width, height: height)
        context.scaleBy(x: scale, y: scale)
        drawPhoto(
            photo,
            in: context,
            layout: layout,
            destinationSize: CGSize(width: layout.photoW, height: layout.photoH)
        )
        BorderPainter.draw(
            on: CGCanvas(context: context),
            layout: layout,
            options: resolved(PaintOptions(stockName: stockName))
        )
        guard let image = context.makeImage() else { throw FramedImageRendererError.imageFailed }
        return image
    }

    static func checkSize(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw FramedImageRendererError.contextFailed }
        guard Double(width) * Double(height) <= Double(maximumPixels) else {
            throw FramedImageRendererError.tooLarge(width: width, height: height)
        }
    }

    private static func makeContext(width: Int, height: Int) throws -> CGContext {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: info.rawValue
        ) else {
            throw FramedImageRendererError.contextFailed
        }
        return context
    }

    private static func prepareTopDown(_ context: CGContext, width: Int, height: Int) {
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
    }

    private static func drawPhoto(
        _ photo: CGImage,
        in context: CGContext,
        layout: Layout,
        destinationSize: CGSize?
    ) {
        let size = destinationSize ?? CGSize(width: layout.photoW, height: layout.photoH)
        context.saveGState()
        context.translateBy(
            x: CGFloat(layout.left),
            y: -(CGFloat(layout.top) + CGFloat(layout.photoH))
        )
        context.scaleBy(x: 1, y: -1)
        context.draw(photo, in: CGRect(origin: .zero, size: size))
        context.restoreGState()
    }

    private static func resolved(_ paint: PaintOptions) -> PaintOptions {
        var options = paint
        if options.printSqueeze == BorderConstants.defaultPrintSqueeze,
           CGCanvas.edgeFont(size: 10).isCondensed {
            options.printSqueeze = 1
        }
        return options
    }
}

enum FramedImageRendererError: LocalizedError {
    case tooLarge(width: Int, height: Int)
    case dimensionMismatch
    case contextFailed
    case imageFailed

    var errorDescription: String? {
        switch self {
        case let .tooLarge(width, height):
            return "The framed output \(width)×\(height) exceeds the 400 MP safety limit."
        case .dimensionMismatch:
            return "The full-resolution grade and border layout dimensions do not match."
        case .contextFailed:
            return "A bitmap canvas could not be created for the framed output."
        case .imageFailed:
            return "The framed output image could not be created."
        }
    }
}
