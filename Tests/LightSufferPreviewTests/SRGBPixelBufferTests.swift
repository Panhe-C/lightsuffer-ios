import XCTest
import FilmPhysics
@testable import LightSufferPreview

final class SRGBPixelBufferTests: XCTestCase {

    func testRGBImageIsInterleavedAndConvertedToLinearProPhoto() throws {
        let pixels = try SRGBPixelBuffer(
            width: 2,
            height: 2,
            rgb: [
                255, 0, 0,   0, 255, 0,
                0, 0, 255,   128, 128, 128,
            ]
        )

        let image = pixels.linearProPhotoRGB()
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.data.count, 12)

        let matrix = ColourScience.matrixRGBToRGB(from: .sRGB, to: .proPhotoRGB)
        let expectedRed = Colour.multiply(matrix: matrix, vector: [1, 0, 0])
        XCTAssertEqual(image[0, 0, 0], expectedRed[0], accuracy: 1e-12)
        XCTAssertEqual(image[0, 0, 1], expectedRed[1], accuracy: 1e-12)
        XCTAssertEqual(image[0, 0, 2], expectedRed[2], accuracy: 1e-12)

        // The transfer function is decoded exactly once, before the same
        // matrix conversion used by the engine's colour-science primitives.
        let grey = (0..<3).map { image[1, 1, $0] }
        let linearGrey = Colour.sRGBDecode(128.0 / 255.0)
        let expectedGrey = Colour.multiply(
            matrix: matrix, vector: [linearGrey, linearGrey, linearGrey]
        )
        for channel in 0..<3 {
            XCTAssertEqual(grey[channel], expectedGrey[channel], accuracy: 1e-12)
        }
    }

    func testRGBAInputIgnoresAlphaAndRowPadding() throws {
        let pixels = try SRGBPixelBuffer(
            width: 1,
            height: 2,
            rgba: [
                1, 2, 3, 4, 99, 99, 99, 99,
                5, 6, 7, 8, 88, 88, 88, 88,
            ],
            bytesPerRow: 8
        )
        XCTAssertEqual(pixels.rgb, [1, 2, 3, 5, 6, 7])
        XCTAssertEqual(pixels.rgbaBytes(), [1, 2, 3, 255, 5, 6, 7, 255])
    }

    func testEncodedSRGBOutputClampsOnlyAtDisplayBoundary() throws {
        let image = RGBImage(
            width: 2,
            height: 1,
            data: [0, 0.5, 1, -0.1, 1.1, .nan]
        )
        let pixels = try SRGBPixelBuffer(encodedSRGB: image)
        XCTAssertEqual(pixels.rgb, [0, 128, 255, 0, 255, 0])
    }

    func testMalformedBuffersAreRejected() {
        XCTAssertThrowsError(try SRGBPixelBuffer(width: 1, height: 1, rgb: [0, 0]))
        XCTAssertThrowsError(
            try SRGBPixelBuffer(
                width: 2, height: 1, rgba: [0, 0, 0, 0], bytesPerRow: 4
            )
        )
        XCTAssertThrowsError(
            try SRGBPixelBuffer(
                encodedSRGB: RGBImage(width: 1, height: 1, data: [0, 0])
            )
        )
    }
}
