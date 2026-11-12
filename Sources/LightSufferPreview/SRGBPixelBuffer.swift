//
//  SRGBPixelBuffer.swift
//  light suffer胶片 — preview support
//

import FilmPhysics

public enum PixelBufferError: Error, Equatable {
    case invalidDimensions
    case invalidByteCount
    case invalidRowStride
}

/// An 8-bit, row-major, interleaved RGB buffer in encoded sRGB.
///
/// This is the display-side representation.  The default film pipeline
/// expects *linear ProPhoto RGB* (`IOParams.inputColorSpace == "ProPhoto RGB"`
/// and `inputCCTFDecoding == false`) and returns *encoded sRGB*
/// (`outputColorSpace == "sRGB"` and `outputCCTFEncoding == true`).
public struct SRGBPixelBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int

    /// RGBRGB…, three bytes per pixel, with no row padding.
    public let rgb: [UInt8]

    public init(width: Int, height: Int, rgb: [UInt8]) throws {
        let byteCount = try Self.expectedByteCount(
            width: width, height: height, components: 3
        )
        guard rgb.count == byteCount else {
            throw PixelBufferError.invalidByteCount
        }
        self.width = width
        self.height = height
        self.rgb = rgb
    }

    /// Copies RGBA pixels into tightly packed RGB, ignoring alpha and any row
    /// padding.  This is the layout produced by the app's Core Graphics
    /// decoding context.
    public init(
        width: Int,
        height: Int,
        rgba: [UInt8],
        bytesPerRow: Int
    ) throws {
        let packedRowBytes = try Self.expectedByteCount(
            width: width, height: 1, components: 4
        )
        guard bytesPerRow >= packedRowBytes else {
            throw PixelBufferError.invalidRowStride
        }
        let (stridedByteCount, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflow, rgba.count == stridedByteCount else {
            throw PixelBufferError.invalidByteCount
        }

        var packed: [UInt8] = []
        packed.reserveCapacity(try Self.expectedByteCount(width: width, height: height, components: 3))
        for row in 0..<height {
            let rowStart = row * bytesPerRow
            for column in 0..<width {
                let source = rowStart + column * 4
                packed.append(rgba[source])
                packed.append(rgba[source + 1])
                packed.append(rgba[source + 2])
            }
        }
        self.width = width
        self.height = height
        self.rgb = packed
    }

    /// Decodes sRGB and converts it to the default pipeline's linear ProPhoto
    /// RGB input.  No clipping is applied to the floating-point colour values.
    ///
    /// `FilmPhysics.RGBImage` is row-major **interleaved** RGB (`RGBRGB…`),
    /// not three planar channel arrays.
    public func linearProPhotoRGB() -> RGBImage {
        let matrix = ColourScience.matrixRGBToRGB(from: .sRGB, to: .proPhotoRGB)
        var output: [Double] = []
        output.reserveCapacity(rgb.count)
        for offset in stride(from: 0, to: rgb.count, by: 3) {
            let encoded = [
                Double(rgb[offset]) / 255.0,
                Double(rgb[offset + 1]) / 255.0,
                Double(rgb[offset + 2]) / 255.0,
            ]
            let linear = encoded.map(Colour.sRGBDecode)
            output.append(contentsOf: Colour.multiply(matrix: matrix, vector: linear))
        }
        return RGBImage(width: width, height: height, data: output)
    }

    /// Converts the default pipeline's already sRGB-encoded floating-point
    /// output to display bytes.  Display conversion clamps to 0…1; NaN maps to
    /// zero and infinities clamp to the corresponding endpoint.
    public init(encodedSRGB image: RGBImage) throws {
        let byteCount = try Self.expectedByteCount(
            width: image.width, height: image.height, components: 3
        )
        guard image.data.count == byteCount else {
            throw PixelBufferError.invalidByteCount
        }
        self.width = image.width
        self.height = image.height
        self.rgb = image.data.map(Self.byte(fromUnitValue:))
    }

    /// Expands the tightly packed RGB pixels to opaque RGBA for Core Graphics.
    public func rgbaBytes() -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(width * height * 4)
        for offset in stride(from: 0, to: rgb.count, by: 3) {
            output.append(rgb[offset])
            output.append(rgb[offset + 1])
            output.append(rgb[offset + 2])
            output.append(255)
        }
        return output
    }

    private static func expectedByteCount(
        width: Int,
        height: Int,
        components: Int
    ) throws -> Int {
        guard width > 0, height > 0 else {
            throw PixelBufferError.invalidDimensions
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: components)
        guard !pixelOverflow, !byteOverflow else {
            throw PixelBufferError.invalidByteCount
        }
        return byteCount
    }

    private static func byte(fromUnitValue value: Double) -> UInt8 {
        if value.isNaN { return 0 }
        let clamped = min(1.0, max(0.0, value))
        return UInt8((clamped * 255.0).rounded())
    }
}
