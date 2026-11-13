//
//  ExportOrchestrator.swift
//  The full-resolution export: the tiled GPU render, the framing and the
//  encoding of one photo.
//
//  The export runs entirely off the main actor.  It never crops the grade:
//  the tiles cover the whole frame, their interiors partition it exactly, and
//  the frame is only *framed* by the border painter, which adds margins
//  around the untouched picture.
//

import CoreGraphics
import FilmPhysics
import FilmPhysicsMetal
import Foundation
import LightSufferPreview
import Metal

/// The result of one export render.
struct ExportRenderResult: @unchecked Sendable {
    /// The framed image: the grade with its border.
    let image: CGImage
    /// The encoded JPEG or HEIC bytes.
    let data: Data
    /// The number of tiles the frame was rendered with.
    let tileCount: Int
    /// The backend that rendered the tiles.
    let backendName: String
}

enum ExportOrchestratorError: LocalizedError {
    case noBackend

    var errorDescription: String? {
        "No rendering backend is available for the export."
    }
}

/// The backend of the export.
///
/// The Metal port of the engine is preferred; the CPU reference is used when
/// there is no Metal device and as the last resort when the GPU cannot run a
/// tile.
private final class ExportBackend {
    private var metal: MetalBackend?
    private var cpu: CPUBackend?

    /// The name of the backend that renders the tiles.
    private(set) var name: String

    init() {
        // A Metal device alone is not enough: MetalBackend can return nil for
        // a missing command queue and can report a shader compilation error
        // through initializationError.  Both cases select the CPU reference.
        if let device = MTLCreateSystemDefaultDevice(),
           let backend = MetalBackend(device: device),
           backend.initializationError == nil {
            metal = backend
            cpu = nil
            name = "Metal"
        } else {
            metal = nil
            cpu = CPUBackend()
            name = "CPU"
        }
    }

    /// Renders one tile.  A GPU failure falls back to the CPU reference for
    /// the rest of the export.
    func render(_ image: RGBImage, params: PipelineParams) throws -> RGBImage {
        if let metal {
            do {
                return try metal.render(image, params: params)
            } catch {
                // The GPU could not run this tile: the rest of the export
                // falls back to the CPU reference.
                self.metal = nil
                self.cpu = CPUBackend()
                name = "CPU"
            }
        }
        guard let cpu else { throw ExportOrchestratorError.noBackend }
        return try cpu.render(image, params: params)
    }
}

enum ExportOrchestrator {

    /// The tile budget of the current device.
    ///
    /// The longest side of a tile is bounded by the dimension of a 2D texture
    /// of the Metal feature set (16384 pixels on every device that runs iOS
    /// 17) and the number of pixels of a tile is bounded by the working set
    /// the device recommends:
    ///
    ///     working set = clamp(0.25 × recommendedMaxWorkingSetSize,
    ///                          64 MiB, 512 MiB)
    ///     tile pixels = working set ÷ 192 bytes per pixel
    ///
    /// The 192 bytes per pixel are a pessimistic estimate of the whole working
    /// set of one rendered tile (about a dozen pooled RGB float buffers of 12
    /// bytes per pixel, the input, the read-back and the CPU side copies).
    static func deviceBudget() -> ExportDeviceBudget {
        #if canImport(Metal)
        if let device = MTLCreateSystemDefaultDevice() {
            return ExportDeviceBudget.standard(
                maxTextureDimension: ExportDeviceBudget.metalMaxTextureDimension,
                workingSetBytes: ExportDeviceBudget.workingSetBytes(
                    recommendedMaxWorkingSetSize: Int(clamping: device.recommendedMaxWorkingSetSize)
                )
            )
        }
        #endif
        return ExportDeviceBudget.standard(
            maxTextureDimension: ExportDeviceBudget.metalMaxTextureDimension,
            workingSetBytes: ExportDeviceBudget.minimumWorkingSetBytes
        )
    }

    /// Renders, frames and encodes the full-resolution export.
    ///
    /// - Parameters:
    ///   - photo: the decoded photo of the preview; its source bytes and its
    ///     source metadata are the ones of the export.
    ///   - request: the immutable snapshot of the look, the adjustments, the
    ///     border, the format and the orientation of the export.
    ///   - budget: the tile budget of the device.
    ///   - progress: the progress of the export; it is called from the
    ///     background thread of the export.
    ///   - cancellation: the cooperative cancellation of the export.
    static func render(
        photo: PreparedPhoto,
        request: ExportRequest,
        budget: ExportDeviceBudget,
        progress: @escaping @Sendable (ExportProgress) -> Void,
        cancellation: ExportCancellation
    ) throws -> ExportRenderResult {
        try cancellation.check()

        progress(ExportProgress(stage: .decoding, fractionCompleted: 0.02))
        // The export decode keeps every source pixel: the 1280 pixel cap of
        // the preview is deliberately not applied here.
        let full = try PhotoDecoder.decodeFullResolution(
            photo: photo,
            settings: request.inputSettings
        )
        try cancellation.check()

        progress(ExportProgress(stage: .planning, fractionCompleted: 0.06))
        let requestedParams = try request.pipelineParams()
        // The 1280 px decode is the canonical App metering frame. Re-decode it
        // when an export starts before the latest WB/input preview has finished.
        // Never meter a cropped tile or the differently resampled full decode.
        let meteringPhoto: PreparedPhoto
        if requestedParams.camera.autoExposure && photo.inputSettings != request.inputSettings {
            meteringPhoto = try PhotoDecoder.decode(
                data: photo.source.data,
                typeIdentifier: photo.source.typeIdentifier,
                filename: photo.source.filename,
                settings: request.inputSettings
            )
        } else {
            meteringPhoto = photo
        }
        let exposure = try AutoExposure.resolve(
            params: requestedParams, meteringImage: meteringPhoto.input
        )
        let params = exposure.params
        try cancellation.check()
        let plan = try ExportPlanner.plan(
            params: params,
            imageWidth: full.sourceSize.width,
            imageHeight: full.sourceSize.height,
            budget: budget
        )
        try cancellation.check()

        let backend = ExportBackend()
        var stitched = [UInt8](repeating: 0, count: plan.imageWidth * plan.imageHeight * 3)

        for (index, tile) in plan.tiles.enumerated() {
            try cancellation.check()
            let fraction = 0.08 + 0.72 * Double(index) / Double(max(1, plan.tiles.count))
            progress(
                ExportProgress(
                    stage: .rendering,
                    fractionCompleted: fraction,
                    completedTiles: index,
                    totalTiles: plan.tiles.count
                )
            )

            // The tile is a crop of the full resolution grade; the physical
            // size of a pixel is the one of the full frame, so the spatial
            // effects of the engine behave exactly as in a single pass.
            let sourceTile = try ExportImageBuffer.crop(full.input, to: tile.sourceRect)
            let tileParams = try ExportSpatialPolicy.parametersForTile(
                params: params,
                tileWidth: tile.sourceRect.width,
                tileHeight: tile.sourceRect.height,
                fullWidth: plan.imageWidth,
                fullHeight: plan.imageHeight
            )
            let rendered = try backend.render(exposure.apply(to: sourceTile), params: tileParams)
            try cancellation.check()

            // The interior of the tile is copied into the stitched frame; the
            // overlap is discarded, so the interiors cover the frame exactly.
            let encoded = try SRGBPixelBuffer(encodedSRGB: rendered)
            let interior = try ExportImageBuffer.crop(
                rgb: encoded.rgb,
                width: encoded.width,
                height: encoded.height,
                to: ExportPixelRect(
                    x: tile.cropX,
                    y: tile.cropY,
                    width: tile.outputRect.width,
                    height: tile.outputRect.height
                )
            )
            try ExportImageBuffer.stitch(
                rgb: interior,
                into: &stitched,
                width: plan.imageWidth,
                height: plan.imageHeight,
                at: tile.outputRect
            )
        }

        try cancellation.check()
        progress(
            ExportProgress(
                stage: .framing,
                fractionCompleted: 0.84,
                completedTiles: plan.tiles.count,
                totalTiles: plan.tiles.count
            )
        )
        let pixels = try SRGBPixelBuffer(width: plan.imageWidth, height: plan.imageHeight, rgb: stitched)
        let grade = try CGImagePixels.makeImage(from: pixels)
        // The border only adds margins: the picture itself is never cropped
        // and never resampled.
        let layout = try request.borderLayout(photoW: plan.imageWidth, photoH: plan.imageHeight)
        let framed = try FramedImageRenderer.renderFull(
            photo: grade,
            layout: layout,
            paint: request.paintOptions
        )

        try cancellation.check()
        progress(ExportProgress(stage: .encoding, fractionCompleted: 0.90))
        let data = try ExportImageEncoder.encode(
            image: framed,
            request: request,
            sourceProperties: full.source.properties
        )

        return ExportRenderResult(
            image: framed,
            data: data,
            tileCount: plan.tiles.count,
            backendName: backend.name
        )
    }
}
