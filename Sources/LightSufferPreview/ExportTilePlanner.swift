//
//  ExportTilePlanner.swift
//  Platform-neutral overlapped tile geometry for full-resolution export.
//

import Foundation

public struct ExportPixelRect: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var pixelCount: Int { width * height }

    public func intersects(_ other: ExportPixelRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }
}

/// One whole-image engine invocation. `sourceRect` includes overlap in the
/// original image; `outputRect` is the non-overlapping interior copied to the
/// stitched result. The crop origin inside the rendered tile is
/// `outputRect.x/y - sourceRect.x/y`.
public struct ExportTile: Equatable, Sendable {
    public let index: Int
    public let sourceRect: ExportPixelRect
    public let outputRect: ExportPixelRect

    public init(index: Int, sourceRect: ExportPixelRect, outputRect: ExportPixelRect) {
        self.index = index
        self.sourceRect = sourceRect
        self.outputRect = outputRect
    }

    public var cropX: Int { outputRect.x - sourceRect.x }
    public var cropY: Int { outputRect.y - sourceRect.y }
}

public struct ExportTilePlan: Equatable, Sendable {
    public let imageWidth: Int
    public let imageHeight: Int
    public let overlap: Int
    public let maxTileSize: Int
    public let maxTilePixels: Int
    public let tiles: [ExportTile]

    public var isSinglePass: Bool { tiles.count == 1 && tiles[0].sourceRect == tiles[0].outputRect }
    public var stitchWidth: Int { imageWidth }
    public var stitchHeight: Int { imageHeight }
}

public enum ExportTilePlannerError: LocalizedError, Equatable {
    case invalidImageSize
    case invalidTileBudget
    case overlapLeavesNoInterior

    public var errorDescription: String? {
        switch self {
        case .invalidImageSize:
            return "The export image dimensions must be positive."
        case .invalidTileBudget:
            return "The export tile size and pixel budget must be positive."
        case .overlapLeavesNoInterior:
            return "The export device budget is too small for the spatial-effect overlap."
        }
    }
}

public enum ExportTilePlanner {
    /// Plans a covering of the original image. Single-pass is selected only
    /// when the unexpanded image fits both limits. Otherwise each square core
    /// is chosen so that even an interior tile with overlap on every side fits
    /// `maxTileSize` and `maxTilePixels`.
    ///
    /// Output interiors partition the original exactly. Input rectangles are
    /// expanded by `overlap` and clamped at the original image boundary.
    public static func plan(
        width: Int,
        height: Int,
        maxTileSize: Int,
        maxTilePixels: Int,
        overlap: Int
    ) throws -> ExportTilePlan {
        guard width > 0, height > 0 else { throw ExportTilePlannerError.invalidImageSize }
        guard maxTileSize > 0, maxTilePixels > 0, overlap >= 0 else {
            throw ExportTilePlannerError.invalidTileBudget
        }

        let imageFits = width <= maxTileSize && height <= maxTileSize
            && Double(width) * Double(height) <= Double(maxTilePixels)
        if imageFits {
            let whole = ExportPixelRect(x: 0, y: 0, width: width, height: height)
            return ExportTilePlan(
                imageWidth: width,
                imageHeight: height,
                overlap: overlap,
                maxTileSize: maxTileSize,
                maxTilePixels: maxTilePixels,
                tiles: [ExportTile(index: 0, sourceRect: whole, outputRect: whole)]
            )
        }

        let pixelLimitedSide = Int(Double(maxTilePixels).squareRoot())
        let renderSide = min(maxTileSize, pixelLimitedSide)
        let doubledOverlap = overlap.multipliedReportingOverflow(by: 2)
        guard !doubledOverlap.overflow else { throw ExportTilePlannerError.overlapLeavesNoInterior }
        let coreExtent = renderSide - doubledOverlap.partialValue
        guard coreExtent > 0 else { throw ExportTilePlannerError.overlapLeavesNoInterior }

        let columns = partitions(of: width, maximumExtent: coreExtent)
        let rows = partitions(of: height, maximumExtent: coreExtent)
        var tiles: [ExportTile] = []
        tiles.reserveCapacity(columns.count * rows.count)
        for row in rows {
            for column in columns {
                let output = ExportPixelRect(
                    x: column.start,
                    y: row.start,
                    width: column.extent,
                    height: row.extent
                )
                let sourceX = max(0, output.x - overlap)
                let sourceY = max(0, output.y - overlap)
                let sourceMaxX = min(width, output.maxX + overlap)
                let sourceMaxY = min(height, output.maxY + overlap)
                let source = ExportPixelRect(
                    x: sourceX,
                    y: sourceY,
                    width: sourceMaxX - sourceX,
                    height: sourceMaxY - sourceY
                )
                tiles.append(ExportTile(index: tiles.count, sourceRect: source, outputRect: output))
            }
        }
        return ExportTilePlan(
            imageWidth: width,
            imageHeight: height,
            overlap: overlap,
            maxTileSize: maxTileSize,
            maxTilePixels: maxTilePixels,
            tiles: tiles
        )
    }

    private static func partitions(
        of total: Int,
        maximumExtent: Int
    ) -> [(start: Int, extent: Int)] {
        let count = (total + maximumExtent - 1) / maximumExtent
        let base = total / count
        let remainder = total % count
        var result: [(start: Int, extent: Int)] = []
        result.reserveCapacity(count)
        var start = 0
        for index in 0..<count {
            // Even partitioning avoids a tiny final strip and still respects
            // the maximum core extent computed above.
            let extent = base + (index < remainder ? 1 : 0)
            result.append((start, extent))
            start += extent
        }
        return result
    }
}
