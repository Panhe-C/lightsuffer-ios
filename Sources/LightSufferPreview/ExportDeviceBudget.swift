//
//  ExportDeviceBudget.swift
//  The tile budget of the full-resolution export.
//
//  The budget is platform neutral: the app fills it from the Metal device
//  (the dimension of a 2D texture and the recommended maximum working set),
//  the tests fill it with the numbers they want to exercise.
//

import Foundation

/// The limits of one tile of the tiled export.
public struct ExportDeviceBudget: Equatable, Sendable {
    /// The longest side of a tile, in pixels.
    public let maxTileSize: Int

    /// The largest number of pixels of a tile.
    public let maxTilePixels: Int

    public init(maxTileSize: Int, maxTilePixels: Int) {
        self.maxTileSize = max(1, maxTileSize)
        self.maxTilePixels = max(1, maxTilePixels)
    }

    /// The conservative working set of one rendered tile, in bytes per pixel.
    ///
    /// The GPU render keeps about a dozen pooled RGB float buffers alive
    /// (12 bytes per pixel each), plus the input, the read-back of the output
    /// and the CPU side copies of the same data.  192 bytes per pixel is a
    /// deliberately pessimistic estimate of the whole working set of a tile.
    public static let bytesPerPixel = 192

    /// The share of the recommended working set of the device one tile may
    /// use.  The rest of the budget belongs to the app (the decoded photo and
    /// the stitched result).
    public static let workingSetFraction = 0.25

    /// The bounds of the working set of one tile.
    public static let minimumWorkingSetBytes = 64 * 1024 * 1024
    public static let maximumWorkingSetBytes = 512 * 1024 * 1024

    /// The dimension of a 2D texture of the Metal feature set.
    ///
    /// Every device that runs iOS 17 guarantees 16384 pixels on the longest
    /// side of a 2D texture; the exporter never asks for more.
    public static let metalMaxTextureDimension = 16_384

    /// The working set one tile may use, derived from the recommended maximum
    /// working set size of the device.
    public static func workingSetBytes(recommendedMaxWorkingSetSize: Int) -> Int {
        let scaled = Int((Double(recommendedMaxWorkingSetSize) * workingSetFraction).rounded())
        return min(max(scaled, minimumWorkingSetBytes), maximumWorkingSetBytes)
    }

    /// The budget of a device.
    ///
    /// - Parameters:
    ///   - maxTextureDimension: the longest side of a 2D texture of the
    ///     device (never more than the Metal feature-set limit).
    ///   - workingSetBytes: the working set one tile may use.
    public static func standard(
        maxTextureDimension: Int,
        workingSetBytes: Int
    ) -> ExportDeviceBudget {
        let clampedWorkingSet = min(
            max(workingSetBytes, minimumWorkingSetBytes),
            maximumWorkingSetBytes
        )
        return ExportDeviceBudget(
            maxTileSize: min(max(1, maxTextureDimension), metalMaxTextureDimension),
            maxTilePixels: max(1, clampedWorkingSet / bytesPerPixel)
        )
    }
}
