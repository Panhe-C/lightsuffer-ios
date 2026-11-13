//
//  AutoExposure.swift
//  light suffer胶片 — iOS app
//
//  Image-dependent camera metering and the small preview used by the
//  upstream auto-exposure stage.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The automatic exposure meter of the camera.
///
/// Upstream references:
/// `spektrafilm.utils.autoexposure.measure_autoexposure_ev`,
/// `spektrafilm.runtime.services.resize.ResizingService.small_preview` and
/// `spektrafilm.runtime.stages.filming.FilmingStage.auto_exposure`.
///
/// Metering is deliberately separate from `CameraParams.exposureCompensationEV`.
/// The measured EV scales the camera RGB image before spectral upsampling; it
/// is not included in the print-balance mid-grey reference.
public enum AutoExposure {

    /// The long-edge limit of the metering preview.
    ///
    /// This is the default of `ResizingService.small_preview`, not the
    /// unrelated `settings.preview_max_size` (640 upstream).
    public static let previewMaxSize = 256

    /// The upstream mid-grey luminance used as the metering target.
    public static let midGrey = 0.184

    /// The metering methods understood by the upstream engine.
    public static let methods = [
        "average",
        "median",
        "center_weighted",
        "partial",
        "matrix",
        "multi_zone",
        "highlight_weighted",
    ]

    /// A whole-frame metering result, reusable across tiles and backends.
    /// The parameters have AE disabled so the scaled input is not metered twice.
    public struct Resolved: Sendable {
        public let ev: Double
        public let params: PipelineParams

        fileprivate init(ev: Double, params: PipelineParams) {
            self.ev = ev
            self.params = params
        }

        /// Scales RGB before CCTF decoding, not the already linear film exposure.
        public func apply(to image: RGBImage) -> RGBImage {
            guard ev != 0 else { return image }
            let scale = pow(2.0, ev)
            return RGBImage(
                width: image.width, height: image.height,
                data: image.data.map { $0 * scale }
            )
        }
    }

    /// Meters once on the supplied whole frame. A caller exporting tiles may
    /// supply its preview frame to keep the displayed and exported exposure equal.
    public static func resolve(
        params: PipelineParams,
        meteringImage: RGBImage
    ) throws -> Resolved {
        let image = try RGBImage.make(
            width: meteringImage.width, height: meteringImage.height,
            data: meteringImage.data
        )
        var resolvedParams = params
        resolvedParams.camera.autoExposure = false
        guard params.camera.autoExposure, image.pixelCount > 0 else {
            return Resolved(ev: 0, params: resolvedParams)
        }
        guard let colourspace = RGBColourspace.named(params.io.inputColorSpace) else {
            throw PipelineError.invalidInputs("the metering input colour space is not supported")
        }
        let ev = meteredEV(
            image: image, colourspace: colourspace,
            applyCCTFDecoding: params.io.inputCCTFDecoding,
            method: params.camera.autoExposureMethod
        )
        guard ev.isFinite, pow(2.0, ev).isFinite else {
            throw PipelineError.invalidInputs("auto exposure produced a non-finite RGB scale")
        }
        return Resolved(ev: ev, params: resolvedParams)
    }

    /// Builds the small preview used for metering.
    ///
    /// Images whose long edge is already at most `maxSize` are returned
    /// unchanged. Otherwise the output dimensions follow
    /// `skimage.transform.rescale` (`round(scale * inputSize)`, with a minimum
    /// of one), and samples use the centre-based nearest-neighbour mapping of
    /// `scipy.ndimage.zoom(..., order=0, grid_mode=True)`.
    ///
    /// - Parameters:
    ///   - image: the full-resolution camera image.
    ///   - maxSize: the maximum output long edge; 256 in the pipeline.
    public static func smallPreview(_ image: RGBImage, maxSize: Int = previewMaxSize) -> RGBImage {
        precondition(maxSize > 0, "the preview size must be positive")
        let longEdge = Swift.max(image.width, image.height)
        guard longEdge > maxSize else { return image }

        let scale = Double(maxSize) / Double(longEdge)
        let outputWidth = Swift.max(
            1, Int((Double(image.width) * scale).rounded(.toNearestOrEven))
        )
        let outputHeight = Swift.max(
            1, Int((Double(image.height) * scale).rounded(.toNearestOrEven))
        )
        var data = [Double](repeating: 0, count: outputWidth * outputHeight * 3)

        for y in 0..<outputHeight {
            // scipy's grid_mode=True coordinates map pixel centres, rather
            // than aligning the outer corners of the input and output.
            let sourceY = (Double(y) + 0.5) * Double(image.height) / Double(outputHeight) - 0.5
            let nearestY = Swift.min(
                image.height - 1, Swift.max(0, Int((sourceY + 0.5).rounded(.down)))
            )
            for x in 0..<outputWidth {
                let sourceX = (Double(x) + 0.5) * Double(image.width) / Double(outputWidth) - 0.5
                let nearestX = Swift.min(
                    image.width - 1, Swift.max(0, Int((sourceX + 0.5).rounded(.down)))
                )
                let source = (nearestY * image.width + nearestX) * 3
                let destination = (y * outputWidth + x) * 3
                data[destination] = image.data[source]
                data[destination + 1] = image.data[source + 1]
                data[destination + 2] = image.data[source + 2]
            }
        }
        return RGBImage(width: outputWidth, height: outputHeight, data: data)
    }

    /// Measures an EV on an already prepared image.
    ///
    /// This is the direct counterpart of upstream `measure_autoexposure_ev`;
    /// unlike ``meteredEV(image:colourspace:applyCCTFDecoding:method:)``, it
    /// does not resize its input. Unknown method names return 0 EV, and an
    /// infinite result (for example from an all-black image) also becomes 0.
    public static func measureAutoExposureEV(
        image: RGBImage,
        colourspace: RGBColourspace,
        applyCCTFDecoding: Bool,
        method: String = "center_weighted"
    ) -> Double {
        let luminance = luminanceY(
            image: image,
            colourspace: colourspace,
            applyCCTFDecoding: applyCCTFDecoding
        )
        let exposure: Double

        switch method {
        case "average":
            exposure = mean(luminance) / midGrey

        case "median":
            exposure = median(luminance) / midGrey

        case "center_weighted":
            let coordinates = normalizedCoordinates(width: image.width, height: image.height)
            var weights = [Double](repeating: 0, count: luminance.count)
            var weightTotal = 0.0
            let denominator = 2.0 * 0.2 * 0.2
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let index = y * image.width + x
                    let weight = exp(
                        -(coordinates.x[x] * coordinates.x[x]
                            + coordinates.y[y] * coordinates.y[y]) / denominator
                    )
                    weights[index] = weight
                    weightTotal += weight
                }
            }
            var weightedSum = 0.0
            for index in 0..<luminance.count {
                // Upstream normalises the mask before multiplying by Y.
                weightedSum += luminance[index] * (weights[index] / weightTotal)
            }
            exposure = weightedSum / midGrey

        case "partial":
            let coordinates = normalizedCoordinates(width: image.width, height: image.height)
            var total = 0.0
            var count = 0
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let radius = sqrt(
                        coordinates.x[x] * coordinates.x[x]
                            + coordinates.y[y] * coordinates.y[y]
                    )
                    if radius < 0.15 {
                        total += luminance[y * image.width + x]
                        count += 1
                    }
                }
            }
            exposure = (count == 0 ? mean(luminance) : total / Double(count)) / midGrey

        case "matrix":
            let cellHeight = image.height / 5
            let cellWidth = image.width / 5
            var zoneMeans: [Double] = []
            var zoneWeights: [Double] = []
            zoneMeans.reserveCapacity(25)
            zoneWeights.reserveCapacity(25)
            for row in 0..<5 {
                for column in 0..<5 {
                    var total = 0.0
                    var count = 0
                    if cellHeight > 0, cellWidth > 0 {
                        for y in (row * cellHeight)..<((row + 1) * cellHeight) {
                            for x in (column * cellWidth)..<((column + 1) * cellWidth) {
                                total += luminance[y * image.width + x]
                                count += 1
                            }
                        }
                    }
                    if count == 0 { continue }
                    zoneMeans.append(total / Double(count))
                    let dy = (Double(row) - 2.0) / 2.0
                    let dx = (Double(column) - 2.0) / 2.0
                    let distance = sqrt(dx * dx + dy * dy) / sqrt(2.0)
                    zoneWeights.append(0.5 * (1.0 + cos(Double.pi * distance)))
                }
            }
            let weightTotal = zoneWeights.reduce(0.0, +)
            var weightedSum = 0.0
            for index in 0..<zoneMeans.count {
                weightedSum += (zoneWeights[index] / weightTotal) * zoneMeans[index]
            }
            // With no non-empty cells upstream's empty dot product is zero.
            exposure = weightedSum / midGrey

        case "multi_zone":
            let coordinates = normalizedCoordinates(width: image.width, height: image.height)
            let bounds = [(0.0, 0.05), (0.05, 0.25), (0.25, 0.50)]
            let ringWeights = [0.50, 0.30, 0.20]
            var weightedSum = 0.0
            var weightTotal = 0.0
            for ring in 0..<3 {
                var total = 0.0
                var count = 0
                for y in 0..<image.height {
                    for x in 0..<image.width {
                        let radius = sqrt(
                            coordinates.x[x] * coordinates.x[x]
                                + coordinates.y[y] * coordinates.y[y]
                        )
                        if radius >= bounds[ring].0, radius < bounds[ring].1 {
                            total += luminance[y * image.width + x]
                            count += 1
                        }
                    }
                }
                if count > 0 {
                    weightedSum += ringWeights[ring] * total / Double(count)
                    weightTotal += ringWeights[ring]
                }
            }
            exposure = (weightTotal > 0 ? weightedSum / weightTotal : mean(luminance)) / midGrey

        case "highlight_weighted":
            var weightTotal = 0.0
            for value in luminance { weightTotal += value * value }
            let useFallback = weightTotal < 1e-12
            if useFallback { weightTotal = Double(luminance.count) }
            var weightedSum = 0.0
            for value in luminance {
                weightedSum += value * (useFallback ? 1.0 : value * value)
            }
            exposure = (weightedSum / weightTotal) / midGrey

        default:
            exposure = 1.0
        }

        let ev = -log2(exposure)
        return ev.isInfinite ? 0.0 : ev
    }

    /// Builds the 256-pixel preview and measures its exposure in stops.
    public static func meteredEV(
        image: RGBImage,
        colourspace: RGBColourspace,
        applyCCTFDecoding: Bool,
        method: String = "center_weighted"
    ) -> Double {
        measureAutoExposureEV(
            image: smallPreview(image),
            colourspace: colourspace,
            applyCCTFDecoding: applyCCTFDecoding,
            method: method
        )
    }

    /// Meters and scales the full-resolution camera RGB image.
    ///
    /// The returned EV is measured on the small preview, while the returned
    /// image has the dimensions of the input, exactly like upstream
    /// `FilmingStage.auto_exposure`.
    public static func apply(
        to image: RGBImage,
        colourspace: RGBColourspace,
        applyCCTFDecoding: Bool,
        method: String = "center_weighted"
    ) -> (image: RGBImage, ev: Double) {
        let ev = meteredEV(
            image: image,
            colourspace: colourspace,
            applyCCTFDecoding: applyCCTFDecoding,
            method: method
        )
        let scale = pow(2.0, ev)
        return (
            RGBImage(width: image.width, height: image.height, data: image.data.map { $0 * scale }),
            ev
        )
    }

    // MARK: - Luminance and statistics

    /// The Y plane of `colour.RGB_to_XYZ` with no explicit illuminant.
    private static func luminanceY(
        image: RGBImage,
        colourspace: RGBColourspace,
        applyCCTFDecoding: Bool
    ) -> [Double] {
        var luminance = [Double](repeating: 0, count: image.pixelCount)
        for index in 0..<image.pixelCount {
            let offset = index * 3
            let xyz = ColourScience.rgbToXYZ(
                rgb: [image.data[offset], image.data[offset + 1], image.data[offset + 2]],
                colourspace: colourspace,
                illuminant: colourspace.whitepoint,
                transform: .cat02,
                applyCCTFDecoding: applyCCTFDecoding
            )
            luminance[index] = xyz[1]
        }
        return luminance
    }

    /// Upstream `_normalized_coords`: the long edge spans [-0.5, 0.5].
    private static func normalizedCoordinates(width: Int, height: Int) -> (x: [Double], y: [Double]) {
        let longEdge = Double(Swift.max(width, height))
        let normalisedWidth = Double(width) / longEdge
        let normalisedHeight = Double(height) / longEdge
        let x = (0..<width).map {
            (Double($0) / Double(width) - 0.5) * normalisedWidth
        }
        let y = (0..<height).map {
            (Double($0) / Double(height) - 0.5) * normalisedHeight
        }
        return (x, y)
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0.0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        // NumPy averages the two central values for an even sample count.
        return (sorted[middle - 1] + sorted[middle]) / 2.0
    }
}
