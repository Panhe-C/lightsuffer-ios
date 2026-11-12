//
//  ExportImageBuffer.swift
//  The crop and the stitch of the tiled full-resolution export.
//
//  `FilmPhysics.RGBImage` stores its pixels row major and **interleaved**
//  (`RGBRGB…`), three values per pixel, with no padding between the rows.
//  The helpers below copy whole rows, so a tile never disturbs the layout of
//  the buffer it comes from.
//

import FilmPhysics
import Foundation

public enum ExportImageBufferError: LocalizedError, Equatable {
    case invalidDimensions
    case rectangleOutOfBounds
    case sizeMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "The export image dimensions must be positive."
        case .rectangleOutOfBounds:
            return "The export tile rectangle lies outside the image."
        case .sizeMismatch:
            return "The export tile does not match the rectangle it is copied into."
        }
    }
}

/// The pixel helpers of the tiled export.
///
/// The export never rescales the grade: the interiors of the tiles partition
/// the original frame exactly, so the stitched image is bit-for-bit the same
/// picture as a single-pass render, up to the grain of the stochastic passes.
///
/// Two layouts are supported: the `Double` buffer of `FilmPhysics.RGBImage`
/// (the linear ProPhoto input of the engine and the encoded sRGB output of a
/// tile) and the tightly packed display bytes of `SRGBPixelBuffer`.  The
/// exporter stitches the **bytes** of the rendered tiles, so the memory of a
/// large frame stays a quarter of the size of its `Double` buffer.
public enum ExportImageBuffer {

    /// A zeroed buffer of the given size.
    public static func make(width: Int, height: Int) throws -> RGBImage {
        guard width > 0, height > 0 else { throw ExportImageBufferError.invalidDimensions }
        let count = width * height * 3
        return RGBImage(width: width, height: height, data: [Double](repeating: 0, count: count))
    }

    /// Copies a rectangle out of an image.
    ///
    /// The result has its own tightly packed rows; the source is untouched.
    public static func crop(_ image: RGBImage, to rect: ExportPixelRect) throws -> RGBImage {
        guard image.width > 0, image.height > 0 else {
            throw ExportImageBufferError.invalidDimensions
        }
        try validate(rect, in: image)
        var data = [Double](repeating: 0, count: rect.width * rect.height * 3)
        let rowValues = rect.width * 3
        for row in 0..<rect.height {
            let source = ((rect.y + row) * image.width + rect.x) * 3
            let destination = row * rowValues
            data.replaceSubrange(
                destination..<(destination + rowValues),
                with: image.data[source..<(source + rowValues)]
            )
        }
        return RGBImage(width: rect.width, height: rect.height, data: data)
    }

    /// Copies a tile into a destination image at a rectangle.
    ///
    /// The tile must have exactly the size of the rectangle; the parts of the
    /// destination outside the rectangle keep their value.
    public static func stitch(
        _ tile: RGBImage,
        into destination: inout RGBImage,
        at rect: ExportPixelRect
    ) throws {
        guard destination.width > 0, destination.height > 0 else {
            throw ExportImageBufferError.invalidDimensions
        }
        guard tile.width == rect.width, tile.height == rect.height else {
            throw ExportImageBufferError.sizeMismatch
        }
        try validate(rect, in: destination)
        let rowValues = rect.width * 3
        for row in 0..<rect.height {
            let source = row * rowValues
            let destinationStart = ((rect.y + row) * destination.width + rect.x) * 3
            destination.data.replaceSubrange(
                destinationStart..<(destinationStart + rowValues),
                with: tile.data[source..<(source + rowValues)]
            )
        }
    }

    // MARK: - The display bytes

    /// Copies a rectangle out of an interleaved RGB byte buffer.
    ///
    /// The display bytes of a stitched export are a quarter of the size of the
    /// `Double` buffer of the same picture, so the export stitches the bytes
    /// and keeps the `Double` buffer of the frame for the tiles only.
    public static func crop(
        rgb: [UInt8],
        width: Int,
        height: Int,
        to rect: ExportPixelRect
    ) throws -> [UInt8] {
        guard width > 0, height > 0 else { throw ExportImageBufferError.invalidDimensions }
        guard rgb.count == width * height * 3 else {
            throw ExportImageBufferError.sizeMismatch
        }
        try validate(rect, width: width, height: height)
        var result = [UInt8](repeating: 0, count: rect.width * rect.height * 3)
        let rowBytes = rect.width * 3
        for row in 0..<rect.height {
            let source = ((rect.y + row) * width + rect.x) * 3
            let destination = row * rowBytes
            result.replaceSubrange(
                destination..<(destination + rowBytes),
                with: rgb[source..<(source + rowBytes)]
            )
        }
        return result
    }

    /// Copies an interleaved RGB byte tile into a destination buffer.
    public static func stitch(
        rgb tile: [UInt8],
        into destination: inout [UInt8],
        width: Int,
        height: Int,
        at rect: ExportPixelRect
    ) throws {
        guard width > 0, height > 0 else { throw ExportImageBufferError.invalidDimensions }
        guard destination.count == width * height * 3 else {
            throw ExportImageBufferError.sizeMismatch
        }
        guard tile.count == rect.width * rect.height * 3 else {
            throw ExportImageBufferError.sizeMismatch
        }
        try validate(rect, width: width, height: height)
        let rowBytes = rect.width * 3
        for row in 0..<rect.height {
            let source = row * rowBytes
            let destinationStart = ((rect.y + row) * width + rect.x) * 3
            destination.replaceSubrange(
                destinationStart..<(destinationStart + rowBytes),
                with: tile[source..<(source + rowBytes)]
            )
        }
    }

    private static func validate(_ rect: ExportPixelRect, in image: RGBImage) throws {
        try validate(rect, width: image.width, height: image.height)
    }

    private static func validate(_ rect: ExportPixelRect, width: Int, height: Int) throws {
        guard rect.width > 0, rect.height > 0,
              rect.x >= 0, rect.y >= 0,
              rect.maxX <= width, rect.maxY <= height else {
            throw ExportImageBufferError.rectangleOutOfBounds
        }
    }
}
