//
//  Glare.swift
//  light suffer胶片 — iOS app
//
//  The glare of the print: the veiling glare of the enlarger / of the
//  photographic paper, added to the tristimulus values of the scan.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

// MARK: - The parameters

/// The parameters of the glare of the print.
///
/// Upstream reference: `spektrafilm.runtime.params_schema.GlareParams`.
public struct GlareParams: Equatable, Sendable {
    /// Whether the glare is applied at all.
    public var active: Bool
    /// The amount of the glare, in percent.
    public var percent: Double
    /// The roughness of the glare, i.e. the relative standard deviation of
    /// its distribution.
    public var roughness: Double
    /// The sigma of the blur of the glare, in pixels.
    public var blur: Double

    public init(
        active: Bool = true,
        percent: Double = 0.03,
        roughness: Double = 0.7,
        blur: Double = 0.5
    ) {
        self.active = active
        self.percent = percent
        self.roughness = roughness
        self.blur = blur
    }
}

// MARK: - The model

/// The glare of the print.
///
/// Upstream reference: `spektrafilm.model.glare`.
///
/// The model adds a random, spatially correlated veiling glare to the
/// tristimulus values of the scan: a lognormal field (the mean is the
/// percentage of the glare, its standard deviation the roughness times the
/// percentage), blurred by the roughness of the paper, and scaled by the
/// tristimulus values of the illuminant of the scanner.
///
/// The upstream draws the field from the **unseeded** global NumPy random
/// state, so the upstream itself is not reproducible; the port draws it from
/// its own seeded generator.
public enum Glare {

    /// The random amount of the glare, one value per pixel.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.glare.compute_random_glare_amount`.
    ///
    /// - Parameters:
    ///   - amount: the amount of the glare, in percent.
    ///   - roughness: the roughness of the glare.
    ///   - blur: the sigma of the blur of the glare, in pixels.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    ///   - seed: the seed of the random number generator.
    /// - Returns: the amount of the glare, one value per pixel.
    public static func randomAmount(
        amount: Double,
        roughness: Double,
        blur: Double,
        width: Int,
        height: Int,
        seed: UInt64
    ) -> [Double] {
        let pixels = Swift.max(width * height, 0)
        var generator = RandomGenerator(seed: seed)
        var field = [Double](repeating: 0, count: pixels)
        for index in 0..<pixels {
            field[index] = generator.lognormalFromMeanStd(
                mean: amount, std: roughness * amount
            )
        }
        if blur > 0 {
            field = SpatialEffects.filterPlane(
                field, width: width, height: height, sigma: blur
            )
        }
        for index in 0..<pixels { field[index] /= 100.0 }
        return field
    }

    /// Adds the glare to the tristimulus values of the scan.
    ///
    /// Upstream reference: `spektrafilm.model.glare.add_glare`.
    ///
    /// - Parameters:
    ///   - xyz: the tristimulus values of the scan, three interleaved values
    ///     per pixel.
    ///   - illuminantXYZ: the tristimulus values of the illuminant of the
    ///     scanner.
    ///   - glare: the parameters of the glare.
    ///   - width: the width of the image, in pixels.
    ///   - height: the height of the image, in pixels.
    ///   - seed: the seed of the random number generator.
    /// - Returns: the tristimulus values with the glare.
    public static func apply(
        xyz: [Double],
        illuminantXYZ: [Double],
        glare: GlareParams?,
        width: Int,
        height: Int,
        seed: UInt64
    ) -> [Double] {
        guard let glare, glare.active, glare.percent > 0 else { return xyz }
        let pixels = xyz.count / 3
        guard pixels > 0 else { return xyz }
        guard width > 0, height > 0, width * height == pixels else {
            // The size of the image does not match the number of pixels.
            return xyz
        }
        let amount = randomAmount(
            amount: glare.percent,
            roughness: glare.roughness,
            blur: glare.blur,
            width: width,
            height: height,
            seed: StochasticSeed.glare(seed: seed)
        )
        var output = xyz
        for pixel in 0..<pixels {
            let value = amount[pixel]
            for component in 0..<3 {
                output[pixel * 3 + component] += value * illuminantXYZ[component]
            }
        }
        return output
    }

    /// The tristimulus values of the illuminant of the scanner.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.scanning.ScanningStage._density_to_rgb`
    /// (`contract("k,kl->l", scan_illuminant, STANDARD_OBSERVER_CMFS[:]) /
    /// normalization`).
    ///
    /// - Parameters:
    ///   - scanIlluminant: the illuminant of the scanner, one value per
    ///     wavelength.
    ///   - colourMatchingFunctions: the CIE 1931 2° CMFs, `[wavelength][XYZ]`.
    ///   - normalization: the normalisation of the illuminant.
    /// - Returns: the tristimulus values of the illuminant.
    public static func illuminantXYZ(
        scanIlluminant: [Double],
        colourMatchingFunctions: [[Double]],
        normalization: Double
    ) -> [Double] {
        let wavelengths = Swift.min(scanIlluminant.count, colourMatchingFunctions.count)
        var xyz = [Double](repeating: 0, count: 3)
        for component in 0..<3 {
            var total = 0.0
            for wavelength in 0..<wavelengths {
                total += scanIlluminant[wavelength] * colourMatchingFunctions[wavelength][component]
            }
            xyz[component] = total / normalization
        }
        return xyz
    }
}
