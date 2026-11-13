import FilmPhysics
import LightSufferPreview
import XCTest

final class AutoExposureExportTests: XCTestCase {
    func testWholeFrameExposureIsSharedByTilesForEveryMeteringMethod() throws {
        let width = 20
        let height = 10
        var data: [Double] = []
        for y in 0..<height {
            for x in 0..<width {
                let value = x < width / 2 ? 0.02 : 0.7 + Double(y) * 0.01
                data.append(contentsOf: [value, value * 0.8, value * 0.6])
            }
        }
        let full = RGBImage(width: width, height: height, data: data)
        for method in AutoExposure.methods {
            var params = try PreviewLook.pipelineParams(
                for: PreviewLook.defaultLook,
                adjustments: PreviewAdjustments(
                    grainEnabled: false, halationEnabled: false,
                    autoExposureEnabled: true, meteringMethod: method
                )
            )
            params.filmRender.dirCouplers.diffusionSizeUM = 0
            params.printRender.glare.active = false
            params.scanner.unsharpMaskAmount = 0
            let exposure = try AutoExposure.resolve(params: params, meteringImage: full)
            let expected = try CPUBackend().render(full, params: params)
            var stitched = try ExportImageBuffer.make(width: width, height: height)
            for x in [0, width / 2] {
                let rect = ExportPixelRect(x: x, y: 0, width: width / 2, height: height)
                let tile = try ExportImageBuffer.crop(full, to: rect)
                let tileParams = try ExportSpatialPolicy.parametersForTile(
                    params: exposure.params,
                    tileWidth: tile.width, tileHeight: tile.height,
                    fullWidth: width, fullHeight: height
                )
                XCTAssertFalse(tileParams.camera.autoExposure)
                let rendered = try CPUBackend().render(exposure.apply(to: tile), params: tileParams)
                try ExportImageBuffer.stitch(rendered, into: &stitched, at: rect)
            }
            XCTAssertEqual(stitched, expected, "\(method): no per-tile metering or double exposure")
        }
    }

    func testPreviewMeteringResultCanGradeADifferentResolutionWithoutRemetering() throws {
        let params = try PreviewLook.pipelineParams(
            for: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments(autoExposureEnabled: true, meteringMethod: "average")
        )
        let preview = RGBImage(width: 2, height: 1, data: [0.184, 0.184, 0.184, 0.184, 0.184, 0.184])
        let exposure = try AutoExposure.resolve(params: params, meteringImage: preview)
        let bright = RGBImage(width: 4, height: 1, data: [Double](repeating: 0.9, count: 12))
        XCTAssertEqual(exposure.ev, 0, accuracy: 1e-12)
        XCTAssertEqual(exposure.apply(to: bright), bright)
        XCTAssertLessThan(try AutoExposure.resolve(params: params, meteringImage: bright).ev, -2)
        XCTAssertFalse(exposure.params.camera.autoExposure)
    }
}
