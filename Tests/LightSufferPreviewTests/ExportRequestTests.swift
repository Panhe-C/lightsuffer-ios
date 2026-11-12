import FrameCore
import LightSufferPreview
import XCTest

final class ExportRequestTests: XCTestCase {
    func testDefaultRequestUsesJPEGQualityAndNoBorder() throws {
        let request = ExportRequest(
            look: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments()
        )
        XCTAssertEqual(request.format, .jpeg)
        XCTAssertEqual(request.quality, 0.92, accuracy: 1e-12)
        XCTAssertEqual(request.borderStyle, .none)
        XCTAssertEqual(request.stockName, "Kodak Portra 400")
        let layout = try request.borderLayout(photoW: 4032, photoH: 3024)
        XCTAssertEqual(layout.outerW, 4032)
        XCTAssertEqual(layout.outerH, 3024)
        XCTAssertEqual(try request.pipelineParams().stochastic.grainSampler, .fast)
    }

    func testHEICFilm120AndOrientationPlan() throws {
        let request = ExportRequest(
            look: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments(exposureCompensationEV: 0.5),
            format: .heic,
            quality: 0.87,
            borderStyle: .film120,
            sourceOrientation: 6
        )
        let layout = try request.borderLayout(photoW: 3024, photoH: 4032)
        let metadata = try request.metadataPlan(
            pixelWidth: layout.outerW,
            pixelHeight: layout.outerH
        )
        XCTAssertEqual(request.format, .heic)
        XCTAssertEqual(request.quality, 0.87, accuracy: 1e-12)
        XCTAssertEqual(metadata.sourceOrientation, 6)
        XCTAssertEqual(metadata.outputOrientation, 1)
        XCTAssertTrue(metadata.bakesSourceOrientationIntoPixels)
        XCTAssertTrue(metadata.carriesRemainingMetadata)
        XCTAssertEqual(metadata.pixelWidth, layout.outerW)
        XCTAssertEqual(metadata.pixelHeight, layout.outerH)
        XCTAssertEqual(ExportMetadataPlan.exifDictionaryKey, "{Exif}")
        XCTAssertEqual(ExportMetadataPlan.gpsDictionaryKey, "{GPS}")
        XCTAssertEqual(ExportMetadataPlan.iptcDictionaryKey, "{IPTC}")
        XCTAssertTrue(ExportMetadataPlan.readOnlyTIFFKeys.contains("ImageWidth"))
    }

    func testUnknownOrientationBecomesUpAndQualityIsBounded() throws {
        let request = ExportRequest(
            look: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments(),
            quality: 4,
            sourceOrientation: 99
        )
        let metadata = try request.metadataPlan(pixelWidth: 64, pixelHeight: 48)
        XCTAssertEqual(metadata.sourceOrientation, 1)
        XCTAssertEqual(metadata.outputOrientation, 1)
        XCTAssertEqual(request.quality, 1)
        XCTAssertThrowsError(try request.metadataPlan(pixelWidth: 0, pixelHeight: 48))
    }
}
