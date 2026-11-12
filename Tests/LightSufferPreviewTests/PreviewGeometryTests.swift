import XCTest
@testable import LightSufferPreview

final class PreviewGeometryTests: XCTestCase {

    func testEXIFOrientationsSwapOnlyTransposedDimensions() throws {
        for orientation: UInt32 in [1, 2, 3, 4] {
            XCTAssertEqual(
                try PreviewGeometry.orientedSize(
                    width: 4000, height: 3000, exifOrientation: orientation
                ),
                PreviewSize(width: 4000, height: 3000)
            )
        }
        for orientation: UInt32 in [5, 6, 7, 8] {
            XCTAssertEqual(
                try PreviewGeometry.orientedSize(
                    width: 4000, height: 3000, exifOrientation: orientation
                ),
                PreviewSize(width: 3000, height: 4000)
            )
        }
    }

    func testLongEdgeScalingPreservesWholeFrameAspectRatio() throws {
        XCTAssertEqual(
            try PreviewGeometry.targetSize(width: 4000, height: 3000),
            PreviewSize(width: 1280, height: 960)
        )
        XCTAssertEqual(
            try PreviewGeometry.targetSize(
                width: 4000, height: 3000, exifOrientation: 6
            ),
            PreviewSize(width: 960, height: 1280)
        )
        XCTAssertEqual(
            try PreviewGeometry.targetSize(width: 3, height: 2),
            PreviewSize(width: 1280, height: 853)
        )
        XCTAssertEqual(
            try PreviewGeometry.targetSize(width: 1, height: 1000),
            PreviewSize(width: 1, height: 1280)
        )
    }

    func testInvalidGeometryIsRejected() {
        XCTAssertThrowsError(try PreviewGeometry.targetSize(width: 0, height: 100))
        XCTAssertThrowsError(
            try PreviewGeometry.targetSize(width: 100, height: 100, longEdge: 0)
        )
    }
}
