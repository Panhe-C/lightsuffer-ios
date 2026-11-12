import FilmPhysics
import LightSufferPreview
import XCTest

final class ExportPlannerTests: XCTestCase {

    func testDeviceBudgetClampsTheWorkingSetAndTheTextureDimension() {
        let generous = ExportDeviceBudget.standard(
            maxTextureDimension: 32_768,
            workingSetBytes: 4 * 1024 * 1024 * 1024
        )
        XCTAssertEqual(generous.maxTileSize, ExportDeviceBudget.metalMaxTextureDimension)
        XCTAssertEqual(
            generous.maxTilePixels,
            ExportDeviceBudget.maximumWorkingSetBytes / ExportDeviceBudget.bytesPerPixel
        )

        let tiny = ExportDeviceBudget.standard(
            maxTextureDimension: 4_096,
            workingSetBytes: 1024
        )
        XCTAssertEqual(tiny.maxTileSize, 4_096)
        XCTAssertEqual(
            tiny.maxTilePixels,
            ExportDeviceBudget.minimumWorkingSetBytes / ExportDeviceBudget.bytesPerPixel
        )

        let workingSet = ExportDeviceBudget.workingSetBytes(
            recommendedMaxWorkingSetSize: 1_000_000_000
        )
        XCTAssertEqual(workingSet, 250_000_000)
        XCTAssertEqual(
            ExportDeviceBudget.workingSetBytes(recommendedMaxWorkingSetSize: 1_000_000),
            ExportDeviceBudget.minimumWorkingSetBytes
        )
        XCTAssertEqual(
            ExportDeviceBudget.workingSetBytes(recommendedMaxWorkingSetSize: 100_000_000_000),
            ExportDeviceBudget.maximumWorkingSetBytes
        )
    }

    func testSmallFrameIsExportedInASinglePass() throws {
        let request = ExportRequest(
            look: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments()
        )
        let budget = ExportDeviceBudget(maxTileSize: 8_192, maxTilePixels: 13_000_000)
        let plan = try ExportPlanner.plan(
            request: request,
            imageWidth: 4_032,
            imageHeight: 3_024,
            budget: budget
        )
        XCTAssertTrue(plan.isSinglePass)
        XCTAssertEqual(plan.tileCount, 1)
        XCTAssertEqual(plan.overlap, try ExportSpatialPolicy.requiredOverlap(
            params: request.pipelineParams(),
            width: 4_032,
            height: 3_024
        ))
    }

    func testLargeFrameIsTiledAndTheInteriorsCoverItExactly() throws {
        let request = ExportRequest(
            look: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments(),
            borderStyle: .film120
        )
        let budget = ExportDeviceBudget(maxTileSize: 1_024, maxTilePixels: 600_000)
        let plan = try ExportPlanner.plan(
            request: request,
            imageWidth: 4_032,
            imageHeight: 3_024,
            budget: budget
        )
        XCTAssertFalse(plan.isSinglePass)
        XCTAssertGreaterThan(plan.tileCount, 1)
        XCTAssertGreaterThan(plan.overlap, 0)

        var coverage = [Int](repeating: 0, count: 4_032 * 3_024)
        for tile in plan.tiles {
            XCTAssertLessThanOrEqual(tile.sourceRect.width, budget.maxTileSize)
            XCTAssertLessThanOrEqual(tile.sourceRect.height, budget.maxTileSize)
            XCTAssertLessThanOrEqual(tile.sourceRect.pixelCount, budget.maxTilePixels)
            for y in tile.outputRect.y..<tile.outputRect.maxY {
                for x in tile.outputRect.x..<tile.outputRect.maxX {
                    coverage[y * 4_032 + x] += 1
                }
            }
        }
        XCTAssertTrue(coverage.allSatisfy { $0 == 1 })
    }

    func testThePlanKeepsTheFastSamplerAndThePhysicalPixelScale() throws {
        let request = ExportRequest(
            look: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments()
        )
        let params = try request.pipelineParams()
        XCTAssertEqual(params.stochastic.grainSampler, .fast)
        let plan = try ExportPlanner.plan(
            params: params,
            imageWidth: 6_000,
            imageHeight: 4_000,
            budget: ExportDeviceBudget(maxTileSize: 4_096, maxTilePixels: 8_000_000)
        )
        let tile = try XCTUnwrap(plan.tiles.first)
        let tileParams = try ExportSpatialPolicy.parametersForTile(
            params: params,
            tileWidth: tile.sourceRect.width,
            tileHeight: tile.sourceRect.height,
            fullWidth: plan.imageWidth,
            fullHeight: plan.imageHeight
        )
        XCTAssertEqual(tileParams.stochastic.grainSampler, .fast)
        let fullPixel = Halation.pixelSizeUM(
            filmFormatMM: params.camera.filmFormatMM,
            width: plan.imageWidth,
            height: plan.imageHeight
        )
        let tilePixel = Halation.pixelSizeUM(
            filmFormatMM: tileParams.camera.filmFormatMM,
            width: tile.sourceRect.width,
            height: tile.sourceRect.height
        )
        XCTAssertEqual(tilePixel, fullPixel, accuracy: 1e-12)
    }
}
