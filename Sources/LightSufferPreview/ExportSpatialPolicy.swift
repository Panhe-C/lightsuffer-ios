//
//  ExportSpatialPolicy.swift
//  Conservative spatial-effect radii and tile physical-scale preservation.
//

import FilmPhysics
import Foundation

public enum ExportSpatialPolicyError: LocalizedError, Equatable {
    case invalidDimensions
    case radiusOverflow

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "The export tile dimensions must be positive."
        case .radiusOverflow:
            return "The spatial-effect radius is too large to tile this export safely."
        }
    }
}

public enum ExportSpatialPolicy {
    /// FIR Gaussians use the engine's three-sigma radius. Its recursive
    /// Young–van Vliet Gaussians have an infinite formal impulse response, so
    /// export uses a conservative eight-sigma apron for those tails. Diffusion
    /// exponentials use the engine's eight-decay-constant (99.95%) budget.
    public static let recursiveGaussianSigmas = 8.0
    public static let exponentialDecayConstants = 8.0

    /// A conservative sum of the radii of successive spatial passes. Radii of
    /// parallel components (for example halation's core and tail) use a maximum.
    public static func requiredOverlap(
        params: PipelineParams,
        width: Int,
        height: Int
    ) throws -> Int {
        guard width > 0, height > 0 else { throw ExportSpatialPolicyError.invalidDimensions }
        let pixelSizeUM = Halation.pixelSizeUM(
            filmFormatMM: params.camera.filmFormatMM,
            width: width,
            height: height
        )
        guard pixelSizeUM > 0, pixelSizeUM.isFinite else { return 0 }

        var radii: [Int] = []

        if params.camera.diffusionFilter.active {
            radii.append(diffusionRadius(params.camera.diffusionFilter, pixelSizeUM: pixelSizeUM))
        }
        if params.camera.lensBlurUM > 0 {
            radii.append(gaussianRadius(params.camera.lensBlurUM / pixelSizeUM))
        }

        let halation = params.filmRender.halation
        if halation.active {
            var scatter = 0
            if halation.scatterAmount > 0 {
                let core = halation.scatterCoreUM.map {
                    $0 * halation.scatterSpatialScale / pixelSizeUM
                }.max() ?? 0
                let tail = halation.scatterTailUM.map {
                    $0 * halation.scatterSpatialScale / pixelSizeUM
                }.max() ?? 0
                scatter = max(gaussianRadius(core), exponentialRadius(tail))
            }
            radii.append(scatter)

            let strengths = halation.halationStrength.map { $0 * halation.halationAmount }
            if halation.halationNBounces > 0, strengths.contains(where: { $0 > 0 }) {
                let first = halation.halationFirstSigmaUM.map {
                    $0 * halation.halationSpatialScale / pixelSizeUM
                }.max() ?? 0
                let lastBounce = first * sqrt(Double(halation.halationNBounces))
                radii.append(gaussianRadius(lastBounce))
            }
        }

        let couplers = params.filmRender.dirCouplers
        if couplers.active, couplers.diffusionSizeUM > 0 {
            let core = gaussianRadius(couplers.diffusionSizeUM / pixelSizeUM)
            let tail = exponentialRadius(couplers.diffusionTailUM / pixelSizeUM)
            radii.append(max(core, tail))
        }

        let grain = params.filmRender.grain
        if grain.active {
            if grain.sublayersActive {
                let grainPlan = FilmGrainPlan.build(
                    grain: grain,
                    film: params.film,
                    pixelSizeUM: pixelSizeUM
                )
                let dyeCloudSigma = grainPlan.blurSigma.map(Double.init).max() ?? 0
                radii.append(gaussianRadius(dyeCloudSigma))
                if grainPlan.microStructureSigma > 0.05 {
                    radii.append(gaussianRadius(Double(grainPlan.microStructureBlur)))
                }
            }
            radii.append(gaussianRadius(grain.blur))
        }

        if params.enlarger.diffusionFilter.active, !params.io.scanFilm {
            radii.append(diffusionRadius(params.enlarger.diffusionFilter, pixelSizeUM: pixelSizeUM))
        }

        let glare = params.printRender.glare
        if glare.active, glare.percent > 0 {
            radii.append(gaussianRadius(glare.blur))
        }
        if params.scanner.lensBlur > 0 {
            radii.append(gaussianRadius(params.scanner.lensBlur))
        }
        if params.scanner.unsharpMaskAmount > 0 {
            radii.append(gaussianRadius(params.scanner.unsharpMaskSigma))
        }

        var total = 0
        for radius in radii {
            let next = total.addingReportingOverflow(radius)
            guard !next.overflow else { throw ExportSpatialPolicyError.radiusOverflow }
            total = next.partialValue
        }
        return total
    }

    /// The engine derives physical pixel size from the dimensions passed to a
    /// whole-image render. Scale only the tile's film-format extent so that the
    /// resulting pixel size is identical to the full-frame render. No engine
    /// source, kernel, sampler or numerical gate is changed.
    public static func parametersForTile(
        params: PipelineParams,
        tileWidth: Int,
        tileHeight: Int,
        fullWidth: Int,
        fullHeight: Int
    ) throws -> PipelineParams {
        guard tileWidth > 0, tileHeight > 0, fullWidth > 0, fullHeight > 0 else {
            throw ExportSpatialPolicyError.invalidDimensions
        }
        var result = params
        result.camera.filmFormatMM = params.camera.filmFormatMM
            * Double(max(tileWidth, tileHeight)) / Double(max(fullWidth, fullHeight))
        return result
    }

    public static func gaussianRadius(_ sigma: Double) -> Int {
        guard sigma.isFinite, sigma > 0 else { return 0 }
        if sigma < SpatialEffects.smallSigmaMax {
            return safeInteger(3.0 * sigma + 0.5, rounding: .down)
        }
        return safeInteger(recursiveGaussianSigmas * sigma, rounding: .up)
    }

    public static func exponentialRadius(_ decay: Double) -> Int {
        guard decay.isFinite, decay > 0 else { return 0 }
        return safeInteger(exponentialDecayConstants * decay, rounding: .up)
    }

    private static func diffusionRadius(
        _ params: DiffusionFilterParams,
        pixelSizeUM: Double
    ) -> Int {
        guard params.strength > 0, params.spatialScale > 0,
              DiffusionFilter.families[params.filterFamily] != nil else { return 0 }
        let decay = DiffusionFilter.bloomMaxLambdaUM(
            params.filterFamily,
            params: params
        ) * params.spatialScale / pixelSizeUM
        return safeInteger(max(5, exponentialDecayConstants * decay), rounding: .up)
    }

    private static func safeInteger(_ value: Double, rounding: FloatingPointRoundingRule) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        if value >= Double(Int.max) { return Int.max }
        return max(0, Int(value.rounded(rounding)))
    }
}
