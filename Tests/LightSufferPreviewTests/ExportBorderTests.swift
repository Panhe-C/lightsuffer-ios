import FrameCore
import LightSufferPreview
import XCTest

final class ExportBorderTests: XCTestCase {
    private let aspects = [
        (4032, 3024), (3024, 4032), (3000, 2000), (2000, 3000),
        (2000, 2000), (6000, 1000), (1000, 6000), (64, 48),
    ]

    func testRequiredStylesNeverCropOnEveryAspect() throws {
        let styles: [BorderStyle] = [
            .film120, .edgeBlackThin, .edgeWhiteThin, .edgeBlack, .edgeWhite,
        ]
        for style in styles {
            for (width, height) in aspects {
                let layout = try BorderLayout.compute(style: style, photoW: width, photoH: height)
                XCTAssertEqual(layout.photoW, width, "\(style.rawValue) width")
                XCTAssertEqual(layout.photoH, height, "\(style.rawValue) height")
                XCTAssertEqual(layout.outerW, width + layout.left + layout.right)
                XCTAssertEqual(layout.outerH, height + layout.top + layout.bottom)
                XCTAssertGreaterThan(layout.left, 0)
                XCTAssertGreaterThan(layout.top, 0)
                XCTAssertGreaterThan(layout.right, 0)
                XCTAssertGreaterThan(layout.bottom, 0)
                XCTAssertEqual(try BorderLayout.compute(style: style, photoW: width, photoH: height), layout)
            }
        }
    }

    func testNoBorderIsIdentity() throws {
        for (width, height) in aspects {
            let layout = try BorderLayout.compute(style: .none, photoW: width, photoH: height)
            XCTAssertEqual(layout.photoW, width)
            XCTAssertEqual(layout.photoH, height)
            XCTAssertEqual(layout.outerW, width)
            XCTAssertEqual(layout.outerH, height)
            XCTAssertEqual(layout.left + layout.top + layout.right + layout.bottom, 0)
            let canvas = RecordingCanvas()
            BorderPainter.draw(on: canvas, layout: layout)
            XCTAssertTrue(canvas.calls.isEmpty)
        }
    }

    func testOfferedBorderSelectionAndFilmNamePrint() throws {
        XCTAssertEqual(
            ExportRequest.offeredBorderStyles,
            [.none, .film120, .edgeBlackThin, .edgeWhiteThin, .edgeBlack, .edgeWhite]
        )
        XCTAssertEqual(BorderStyle.film120.displayName, "120 胶片")
        XCTAssertEqual(BorderStyle.edgeBlackThin.displayName, "不规则细黑边")
        XCTAssertEqual(BorderStyle.edgeWhiteThin.displayName, "不规则细白边")

        let layout = try BorderLayout.compute(style: .film120, photoW: 3000, photoH: 2000)
        let canvas = RecordingCanvas()
        BorderPainter.draw(
            on: canvas,
            layout: layout,
            options: PaintOptions(stockName: "Kodak Portra 400")
        )
        let printed = canvas.calls.compactMap { call -> String? in
            guard call.first as? String == "fillText" else { return nil }
            return call.dropFirst().first as? String
        }
        XCTAssertTrue(printed.contains("KODAK PORTRA 400"))
    }
}
