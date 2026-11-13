import XCTest
import FilmPhysics
@testable import LightSufferPreview

final class PreviewLookTests: XCTestCase {

    func testEveryMeteringMethodMapsToTheCameraAndInvalidNamesAreRejected() throws {
        for method in AutoExposure.methods {
            let params = try PreviewLook.pipelineParams(
                for: PreviewLook.defaultLook,
                adjustments: PreviewAdjustments(autoExposureEnabled: true, meteringMethod: method)
            )
            XCTAssertTrue(params.camera.autoExposure)
            XCTAssertEqual(params.camera.autoExposureMethod, method)
            XCTAssertEqual(params.stochastic.grainSampler, .fast)
        }
        XCTAssertThrowsError(try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments(meteringMethod: "not_a_method")
        ))
    }

    func testDefaultLookLoadsBundledProfilesAndKeepsFastGrainSampler() throws {
        let params = try PreviewLook.pipelineParams()

        XCTAssertEqual(params.film.info.stock, "kodak_portra_400")
        XCTAssertTrue(params.film.isFilm)
        XCTAssertEqual(params.print.info.stock, "kodak_portra_endura")
        XCTAssertTrue(params.print.isPaper)
        XCTAssertEqual(params.stochastic.grainSampler, .fast)
        XCTAssertEqual(StochasticParams().grainSampler, .fast)

        // These are the colour-space assumptions of SRGBPixelBuffer.
        XCTAssertEqual(params.io.inputColorSpace, "ProPhoto RGB")
        XCTAssertFalse(params.io.inputCCTFDecoding)
        XCTAssertEqual(params.io.outputColorSpace, "sRGB")
        XCTAssertTrue(params.io.outputCCTFEncoding)
    }
}
