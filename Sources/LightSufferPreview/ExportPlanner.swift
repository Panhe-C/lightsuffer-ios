//
//  ExportPlanner.swift
//  The platform-neutral plan of one full-resolution export.
//

import FilmPhysics
import Foundation

/// The complete plan of one export: the overlap the spatial effects need and
/// the tiles that cover the frame.
public struct ExportPlan: Equatable, Sendable {
    /// The width of the exported frame, in pixels (the whole photo).
    public let imageWidth: Int
    /// The height of the exported frame, in pixels (the whole photo).
    public let imageHeight: Int
    /// The overlap every tile keeps around its interior.
    public let overlap: Int
    /// The budget the plan was built with.
    public let budget: ExportDeviceBudget
    /// The tiles, in rendering order.
    public let tiles: [ExportTile]

    /// Whether the whole frame is rendered in one pass.
    public var isSinglePass: Bool {
        tiles.count == 1 && tiles[0].sourceRect == tiles[0].outputRect
    }

    /// The number of tiles of the export.
    public var tileCount: Int { tiles.count }

    public init(
        imageWidth: Int,
        imageHeight: Int,
        overlap: Int,
        budget: ExportDeviceBudget,
        tiles: [ExportTile]
    ) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.overlap = overlap
        self.budget = budget
        self.tiles = tiles
    }
}

public enum ExportPlanner {

    /// Plans the export of a request for a frame of the given size.
    ///
    /// The parameters of the request are the parameters of the preview, so the
    /// overlap is the overlap the *same* grade needs.
    public static func plan(
        request: ExportRequest,
        imageWidth: Int,
        imageHeight: Int,
        budget: ExportDeviceBudget
    ) throws -> ExportPlan {
        let params = try request.pipelineParams()
        return try plan(
            params: params,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            budget: budget
        )
    }

    /// Plans the export of a frame with already built parameters.
    ///
    /// The overlap is computed on the **full** frame: the spatial effects of
    /// the engine work on the physical size of a pixel, so the overlap of the
    /// full frame is the overlap every tile needs.
    public static func plan(
        params: PipelineParams,
        imageWidth: Int,
        imageHeight: Int,
        budget: ExportDeviceBudget
    ) throws -> ExportPlan {
        let overlap = try ExportSpatialPolicy.requiredOverlap(
            params: params,
            width: imageWidth,
            height: imageHeight
        )
        let tilePlan = try ExportTilePlanner.plan(
            width: imageWidth,
            height: imageHeight,
            maxTileSize: budget.maxTileSize,
            maxTilePixels: budget.maxTilePixels,
            overlap: overlap
        )
        return ExportPlan(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            overlap: overlap,
            budget: budget,
            tiles: tilePlan.tiles
        )
    }
}
