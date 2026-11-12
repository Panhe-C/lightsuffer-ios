import FilmPhysics
import LightSufferPreview
import XCTest

final class ExportImageBufferTests: XCTestCase {

    /// A deterministic image whose values identify their position, so a wrong
    /// row or column cannot pass unnoticed.
    private func makeImage(width: Int, height: Int) -> RGBImage {
        var data = [Double](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 3
                data[index] = Double(y * width + x)
                data[index + 1] = Double(y * width + x) + 0.25
                data[index + 2] = Double(y * width + x) + 0.5
            }
        }
        return RGBImage(width: width, height: height, data: data)
    }

    func testCropKeepsTheInterleavedRGBRGBLayout() throws {
        let image = makeImage(width: 7, height: 5)
        let rect = ExportPixelRect(x: 2, y: 1, width: 3, height: 2)
        let cropped = try ExportImageBuffer.crop(image, to: rect)
        XCTAssertEqual(cropped.width, 3)
        XCTAssertEqual(cropped.height, 2)
        XCTAssertEqual(cropped.data.count, 3 * 2 * 3)
        for row in 0..<2 {
            for column in 0..<3 {
                let source = ((1 + row) * 7 + (2 + column)) * 3
                let destination = (row * 3 + column) * 3
                XCTAssertEqual(cropped.data[destination], image.data[source], accuracy: 0)
                XCTAssertEqual(cropped.data[destination + 1], image.data[source + 1], accuracy: 0)
                XCTAssertEqual(cropped.data[destination + 2], image.data[source + 2], accuracy: 0)
            }
        }
        // The source is untouched.
        XCTAssertEqual(image.data.count, 7 * 5 * 3)
        XCTAssertEqual(image.data[0], 0, accuracy: 0)
    }

    func testStitchPlacesEveryInteriorWithoutGaps() throws {
        let width = 11
        let height = 7
        let source = makeImage(width: width, height: height)
        var destination = try ExportImageBuffer.make(width: width, height: height)
        let tiles = [
            ExportPixelRect(x: 0, y: 0, width: 5, height: 4),
            ExportPixelRect(x: 5, y: 0, width: 6, height: 4),
            ExportPixelRect(x: 0, y: 4, width: 5, height: 3),
            ExportPixelRect(x: 5, y: 4, width: 6, height: 3),
        ]
        for tile in tiles {
            let cropped = try ExportImageBuffer.crop(source, to: tile)
            try ExportImageBuffer.stitch(cropped, into: &destination, at: tile)
        }
        XCTAssertEqual(destination.data, source.data)
    }

    func testCropAndStitchRoundTripKeepsEveryPixelOfTheFrame() throws {
        let width = 23
        let height = 17
        let source = makeImage(width: width, height: height)
        let plan = try ExportTilePlanner.plan(
            width: width,
            height: height,
            maxTileSize: 8,
            maxTilePixels: 64,
            overlap: 3
        )
        var stitched = try ExportImageBuffer.make(width: width, height: height)
        for tile in plan.tiles {
            let cropped = try ExportImageBuffer.crop(source, to: tile.sourceRect)
            let interior = try ExportImageBuffer.crop(
                cropped,
                to: ExportPixelRect(
                    x: tile.cropX,
                    y: tile.cropY,
                    width: tile.outputRect.width,
                    height: tile.outputRect.height
                )
            )
            try ExportImageBuffer.stitch(interior, into: &stitched, at: tile.outputRect)
        }
        XCTAssertEqual(stitched.data, source.data)
    }

    func testTheByteBuffersCropAndStitchLikeTheDoubleOnes() throws {
        let width = 9
        let height = 6
        var bytes = [UInt8](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            bytes[index * 3] = UInt8(index % 251)
            bytes[index * 3 + 1] = UInt8((index + 7) % 251)
            bytes[index * 3 + 2] = UInt8((index + 13) % 251)
        }

        let rect = ExportPixelRect(x: 1, y: 2, width: 4, height: 3)
        let cropped = try ExportImageBuffer.crop(rgb: bytes, width: width, height: height, to: rect)
        XCTAssertEqual(cropped.count, 4 * 3 * 3)
        for row in 0..<3 {
            for column in 0..<4 {
                let source = ((2 + row) * width + (1 + column)) * 3
                let destination = (row * 4 + column) * 3
                XCTAssertEqual(cropped[destination], bytes[source])
                XCTAssertEqual(cropped[destination + 1], bytes[source + 1])
                XCTAssertEqual(cropped[destination + 2], bytes[source + 2])
            }
        }

        var destination = [UInt8](repeating: 0, count: width * height * 3)
        try ExportImageBuffer.stitch(
            rgb: cropped,
            into: &destination,
            width: width,
            height: height,
            at: ExportPixelRect(x: 5, y: 3, width: 4, height: 3)
        )
        for row in 0..<3 {
            for column in 0..<4 {
                let source = (row * 4 + column) * 3
                let destinationIndex = ((3 + row) * width + (5 + column)) * 3
                XCTAssertEqual(destination[destinationIndex], cropped[source])
                XCTAssertEqual(destination[destinationIndex + 1], cropped[source + 1])
                XCTAssertEqual(destination[destinationIndex + 2], cropped[source + 2])
            }
        }
    }

    func testOutOfBoundsAndMismatchedTilesAreRejected() throws {
        let image = makeImage(width: 4, height: 4)
        XCTAssertThrowsError(
            try ExportImageBuffer.crop(image, to: ExportPixelRect(x: 3, y: 0, width: 2, height: 2))
        ) { error in
            XCTAssertEqual(error as? ExportImageBufferError, .rectangleOutOfBounds)
        }
        XCTAssertThrowsError(
            try ExportImageBuffer.crop(image, to: ExportPixelRect(x: -1, y: 0, width: 2, height: 2))
        ) { error in
            XCTAssertEqual(error as? ExportImageBufferError, .rectangleOutOfBounds)
        }
        XCTAssertThrowsError(try ExportImageBuffer.make(width: 0, height: 4)) { error in
            XCTAssertEqual(error as? ExportImageBufferError, .invalidDimensions)
        }
        var destination = try ExportImageBuffer.make(width: 4, height: 4)
        let tile = makeImage(width: 3, height: 4)
        XCTAssertThrowsError(
            try ExportImageBuffer.stitch(
                tile,
                into: &destination,
                at: ExportPixelRect(x: 0, y: 0, width: 4, height: 4)
            )
        ) { error in
            XCTAssertEqual(error as? ExportImageBufferError, .sizeMismatch)
        }
    }
}
