import FilmPhysics
import LightSufferPreview
import XCTest

final class ExportTilePlannerTests: XCTestCase {
    func testSinglePassWhenImageFitsDimensionAndPixelBudget() throws {
        let plan = try ExportTilePlanner.plan(
            width: 4032,
            height: 3024,
            maxTileSize: 8192,
            maxTilePixels: 13_000_000,
            overlap: 128
        )
        XCTAssertTrue(plan.isSinglePass)
        XCTAssertEqual(plan.tiles.count, 1)
        XCTAssertEqual(plan.stitchWidth, 4032)
        XCTAssertEqual(plan.stitchHeight, 3024)
        let tile = try XCTUnwrap(plan.tiles.first)
        XCTAssertEqual(tile.sourceRect, tile.outputRect)
        XCTAssertEqual(tile.cropX, 0)
        XCTAssertEqual(tile.cropY, 0)

        let tooLittleMemory = try ExportTilePlanner.plan(
            width: 4032,
            height: 3024,
            maxTileSize: 8192,
            maxTilePixels: 12_000_000,
            overlap: 128
        )
        XCTAssertFalse(tooLittleMemory.isSinglePass)
        XCTAssertGreaterThan(tooLittleMemory.tiles.count, 1)
    }

    func testMultiTileInteriorsExactlyCoverStitchWithoutOverlap() throws {
        let width = 517
        let height = 389
        let plan = try ExportTilePlanner.plan(
            width: width,
            height: height,
            maxTileSize: 128,
            maxTilePixels: 10_000,
            overlap: 13
        )
        XCTAssertGreaterThan(plan.tiles.count, 1)
        var coverage = [Int](repeating: 0, count: width * height)
        for tile in plan.tiles {
            let source = tile.sourceRect
            let output = tile.outputRect
            XCTAssertGreaterThanOrEqual(source.x, 0)
            XCTAssertGreaterThanOrEqual(source.y, 0)
            XCTAssertLessThanOrEqual(source.maxX, width)
            XCTAssertLessThanOrEqual(source.maxY, height)
            XCTAssertLessThanOrEqual(source.width, plan.maxTileSize)
            XCTAssertLessThanOrEqual(source.height, plan.maxTileSize)
            XCTAssertLessThanOrEqual(source.pixelCount, plan.maxTilePixels)
            XCTAssertEqual(tile.cropX, output.x - source.x)
            XCTAssertEqual(tile.cropY, output.y - source.y)
            XCTAssertGreaterThanOrEqual(tile.cropX, 0)
            XCTAssertGreaterThanOrEqual(tile.cropY, 0)
            XCTAssertLessThanOrEqual(tile.cropX + output.width, source.width)
            XCTAssertLessThanOrEqual(tile.cropY + output.height, source.height)
            for y in output.y..<output.maxY {
                for x in output.x..<output.maxX {
                    coverage[y * width + x] += 1
                }
            }
        }
        XCTAssertTrue(coverage.allSatisfy { $0 == 1 })
        XCTAssertEqual(plan.stitchWidth, width)
        XCTAssertEqual(plan.stitchHeight, height)
    }

    func testLargeImageTileAreasPartitionOriginalAndRespectBudgets() throws {
        let plan = try ExportTilePlanner.plan(
            width: 4032,
            height: 3024,
            maxTileSize: 1024,
            maxTilePixels: 600_000,
            overlap: 32
        )
        XCTAssertGreaterThan(plan.tiles.count, 1)
        XCTAssertEqual(plan.tiles.map { $0.outputRect.pixelCount }.reduce(0, +), 4032 * 3024)
        for (index, tile) in plan.tiles.enumerated() {
            XCTAssertLessThanOrEqual(tile.sourceRect.width, 1024)
            XCTAssertLessThanOrEqual(tile.sourceRect.height, 1024)
            XCTAssertLessThanOrEqual(tile.sourceRect.pixelCount, 600_000)
            for other in plan.tiles.dropFirst(index + 1) {
                XCTAssertFalse(tile.outputRect.intersects(other.outputRect))
            }
        }
    }

    func testImpossibleOverlapBudgetIsRejected() {
        XCTAssertThrowsError(
            try ExportTilePlanner.plan(
                width: 4000,
                height: 3000,
                maxTileSize: 128,
                maxTilePixels: 16_384,
                overlap: 64
            )
        ) { error in
            XCTAssertEqual(error as? ExportTilePlannerError, .overlapLeavesNoInterior)
        }
    }

    func testTileParametersPreserveFullFramePhysicalPixelScaleAndFastSampler() throws {
        let params = try PreviewLook.pipelineParams()
        let fullWidth = 4032
        let fullHeight = 3024
        let tileWidth = 1024
        let tileHeight = 768
        let tileParams = try ExportSpatialPolicy.parametersForTile(
            params: params,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            fullWidth: fullWidth,
            fullHeight: fullHeight
        )
        let fullPixel = Halation.pixelSizeUM(
            filmFormatMM: params.camera.filmFormatMM,
            width: fullWidth,
            height: fullHeight
        )
        let tilePixel = Halation.pixelSizeUM(
            filmFormatMM: tileParams.camera.filmFormatMM,
            width: tileWidth,
            height: tileHeight
        )
        XCTAssertEqual(tilePixel, fullPixel, accuracy: 1e-12)
        XCTAssertEqual(tileParams.stochastic.grainSampler, .fast)
        XCTAssertGreaterThan(
            try ExportSpatialPolicy.requiredOverlap(
                params: params,
                width: fullWidth,
                height: fullHeight
            ),
            0
        )
    }
}
