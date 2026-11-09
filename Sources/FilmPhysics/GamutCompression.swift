//
//  GamutCompression.swift
//  light suffer胶片 — iOS app
//
//  The input gamut compression (baked into the hanatos 2025 lookup table)
//  and the output gamut compression (applied to the scanned print).
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

// MARK: - Specifications

/// The parameters of the Reinhard knee.
///
/// Upstream reference: the `knee` tuples of
/// `spektrafilm.utils.gamut_compression.InputGamutCompressSpec` and
/// `spektrafilm.utils.gamut_compression.OutputGamutCompressSpec`.
public struct ReinhardKnee: Equatable, Sendable {
    /// The threshold below which the knee is the identity.
    public var threshold: Double
    /// The asymptote of the knee.
    public var limit: Double
    /// The power of the knee.
    public var power: Double

    public init(threshold: Double = 0.0, limit: Double = 1.0, power: Double = 6.0) {
        self.threshold = threshold
        self.limit = limit
        self.power = power
    }
}

/// The configuration of the input gamut compression.
///
/// Upstream reference:
/// `spektrafilm.utils.gamut_compression.InputGamutCompressSpec`.
public struct InputGamutCompressSpec: Equatable, Sendable {
    /// Whether the compression is applied.
    public var active: Bool
    /// The algorithm (`"xy"` or `"oklch"`).
    public var algorithm: String
    /// The parameters of the Reinhard knee.
    public var knee: ReinhardKnee

    public init(
        active: Bool = true,
        algorithm: String = "xy",
        knee: ReinhardKnee = ReinhardKnee()
    ) {
        self.active = active
        self.algorithm = algorithm
        self.knee = knee
    }
}

/// The configuration of the output gamut compression.
///
/// Upstream reference:
/// `spektrafilm.utils.gamut_compression.OutputGamutCompressSpec`.
public struct OutputGamutCompressSpec: Equatable, Sendable {
    /// The algorithm (`"off"`, `"cam16ucs"`, …).
    public var algorithm: String
    /// The parameters of the chroma Reinhard knee.
    public var knee: ReinhardKnee
    /// The parameters of the one-sided lightness Reinhard knee (`nil` disables it).
    public var lightnessCompression: ReinhardKnee?

    public init(
        algorithm: String = "cam16ucs",
        knee: ReinhardKnee = ReinhardKnee(),
        lightnessCompression: ReinhardKnee? = ReinhardKnee(threshold: 0.7, limit: 1.0, power: 2.2)
    ) {
        self.algorithm = algorithm
        self.knee = knee
        self.lightnessCompression = lightnessCompression
    }

    /// Whether the compression is applied.
    public var active: Bool { algorithm != "off" }
}

// MARK: - The gamut compression

/// The input and output gamut compression.
public enum GamutCompression {

    // MARK: - The spectral locus

    /// The closed polygon of the CIE 1931 2° visible spectral locus.
    ///
    /// Upstream reference: `spektrafilm.utils.gamut_compression.spectral_locus_xy`.
    ///
    /// The locus is sampled at 5 nm steps from 380 to 700 nm and the first
    /// vertex is repeated at the end so that the polygon is closed.
    public static func spectralLocusXY(
        colourMatchingFunctions: [[Double]]
    ) -> [Chromaticity] {
        var locus: [Chromaticity] = []
        var wavelength = 380
        while wavelength <= 700 {
            let index = (wavelength - 380) / 5
            guard index >= 0, index < colourMatchingFunctions.count else { break }
            let cmf = colourMatchingFunctions[index]
            let total = cmf[0] + cmf[1] + cmf[2]
            let denominator = Swift.max(total, 1e-12)
            locus.append(Chromaticity(x: cmf[0] / denominator, y: cmf[1] / denominator))
            wavelength += 5
        }
        if let first = locus.first {
            locus.append(first)
        }
        return locus
    }

    /// The cached spectral locus of the bundled colour matching functions.
    public static func cachedSpectralLocusXY() -> [Chromaticity] {
        cachedLocusStorage.locus
    }

    private static let cachedLocusStorage = LocusStorage()

    private final class LocusStorage {
        let locus: [Chromaticity]

        init() {
            locus = GamutCompression.spectralLocusXY(
                colourMatchingFunctions: Illuminants.cachedColourMatchingFunctions()
            )
        }
    }

    // MARK: - The Reinhard knee

    /// The Reinhard knee on a normalised distance.
    ///
    /// Upstream reference: `spektrafilm.utils.gamut_compression.reinhard_knee`.
    ///
    /// ```
    /// x = (d - threshold) / (limit - threshold)
    /// y = x / (1 + x ** power) ** (1 / power)
    /// d' = threshold + (limit - threshold) · y
    /// ```
    public static func reinhardKnee(_ d: Double, knee: ReinhardKnee) -> Double {
        guard d > knee.threshold else { return d }
        let scale = knee.limit - knee.threshold
        let x = (d - knee.threshold) / scale
        let y = x / pow(1.0 + pow(x, knee.power), 1.0 / knee.power)
        return knee.threshold + scale * y
    }

    // MARK: - The radial chromaticity compression

    /// The distance from the origin along a unit direction to the first
    /// intersection with a closed polygon.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.gamut_compression._ray_polygon_distance`.
    public static func rayPolygonDistance(
        origin: Chromaticity,
        direction: (x: Double, y: Double),
        polygon: [Chromaticity]
    ) -> Double {
        var minimum = Double.infinity
        for index in 0..<(polygon.count - 1) {
            let a = polygon[index]
            let b = polygon[index + 1]
            let ex = b.x - a.x
            let ey = b.y - a.y
            let dx = direction.x
            let dy = direction.y
            let denominator = dx * ey - dy * ex
            guard abs(denominator) > 1e-12 else { continue }
            let ox = origin.x - a.x
            let oy = origin.y - a.y
            let t = (-ox * ey + oy * ex) / denominator
            let s = (-ox * dy + oy * dx) / denominator
            if t > 1e-9, s >= 0, s <= 1, t < minimum {
                minimum = t
            }
        }
        return minimum
    }

    /// The radial compression of a chromaticity toward the spectral locus.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.gamut_compression.compress_xy_radial`.
    ///
    /// - Parameters:
    ///   - xy: the chromaticity to compress.
    ///   - white: the achromatic axis of the compression.
    ///   - knee: the parameters of the Reinhard knee.
    ///   - locus: the polygon of the spectral locus.
    public static func compressXYRadial(
        _ xy: Chromaticity,
        white: Chromaticity,
        knee: ReinhardKnee,
        locus: [Chromaticity]
    ) -> Chromaticity {
        let dx = xy.x - white.x
        let dy = xy.y - white.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < 1e-9 { return xy }
        let safeDistance = Swift.max(distance, 1e-12)
        let direction = (x: dx / safeDistance, y: dy / safeDistance)
        let boundary = rayPolygonDistance(origin: white, direction: direction, polygon: locus)
        let normalised = distance / Swift.max(boundary, 1e-12)
        let compressed = reinhardKnee(normalised, knee: knee)
        let scale = compressed * boundary
        return Chromaticity(x: white.x + direction.x * scale, y: white.y + direction.y * scale)
    }

    /// The compression of a chromaticity, as configured by the specification.
    ///
    /// Upstream reference: `spektrafilm.utils.gamut_compression.compress_xy`.
    public static func compressXY(
        _ xy: Chromaticity,
        white: Chromaticity,
        spec: InputGamutCompressSpec,
        locus: [Chromaticity]
    ) -> Chromaticity {
        guard spec.active else { return xy }
        switch spec.algorithm {
        case "xy":
            return compressXYRadial(xy, white: white, knee: spec.knee, locus: locus)
        default:
            return xy
        }
    }

    // MARK: - Baking the compression into the tc lookup table

    /// Bakes the input gamut compression into the hanatos 2025 lookup table.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.gamut_compression.remap_tc_lut_for_compression`.
    ///
    /// ```
    /// new_lut[xy] = old_lut[compress(xy)]
    /// ```
    ///
    /// - Parameters:
    ///   - lut: the lookup table.
    ///   - referenceIlluminantXY: the achromatic axis of the compression.
    ///   - spec: the compression configuration.
    ///   - locus: the polygon of the spectral locus.
    public static func remapTCLUTForCompression(
        lut: HanatosTCLUT,
        referenceIlluminantXY: Chromaticity,
        spec: InputGamutCompressSpec,
        locus: [Chromaticity]? = nil
    ) -> HanatosTCLUT {
        guard spec.active else { return lut }
        let polygon = locus ?? cachedSpectralLocusXY()
        let size = lut.size
        var values = [Double](repeating: 0, count: lut.values.count)

        for i in 0..<size {
            for j in 0..<size {
                let u = Double(i) / Double(size - 1)
                let v = Double(j) / Double(size - 1)
                let xy = SpectralUpsampling.tcToXY((u: u, v: v))
                let compressed = compressXY(xy, white: referenceIlluminantXY, spec: spec, locus: polygon)
                let tc = SpectralUpsampling.xyToTC(compressed)
                let coordinateI = tc.u * Double(size - 1)
                let coordinateJ = tc.v * Double(size - 1)
                for channel in 0..<3 {
                    values[(i * size + j) * 3 + channel] = bilinearSample(
                        lut: lut.values,
                        size: size,
                        channel: channel,
                        i: coordinateI,
                        j: coordinateJ
                    )
                }
            }
        }
        return HanatosTCLUT(size: size, values: values)
    }

    /// The bilinear sampling of a lookup table, with the nearest boundary
    /// behaviour of `scipy.ndimage.map_coordinates`.
    private static func bilinearSample(
        lut: [Double], size: Int, channel: Int, i: Double, j: Double
    ) -> Double {
        let clampedI = Swift.min(Swift.max(i, 0), Double(size - 1))
        let clampedJ = Swift.min(Swift.max(j, 0), Double(size - 1))
        let i0 = Int(clampedI.rounded(.down))
        let j0 = Int(clampedJ.rounded(.down))
        let i1 = Swift.min(i0 + 1, size - 1)
        let j1 = Swift.min(j0 + 1, size - 1)
        let ti = clampedI - Double(i0)
        let tj = clampedJ - Double(j0)
        let v00 = lut[(i0 * size + j0) * 3 + channel]
        let v01 = lut[(i0 * size + j1) * 3 + channel]
        let v10 = lut[(i1 * size + j0) * 3 + channel]
        let v11 = lut[(i1 * size + j1) * 3 + channel]
        return (1.0 - ti) * (1.0 - tj) * v00 + (1.0 - ti) * tj * v01
            + ti * (1.0 - tj) * v10 + ti * tj * v11
    }

    // MARK: - The output compression

    /// The viewing conditions of the output gamut compression.
    ///
    /// Upstream reference: the `_CAM16UCS_L_A` and `_CAM16UCS_Y_B`
    /// constants of `spektrafilm.utils.gamut_compression`.
    public static let cam16UCSViewingConditions = (LA: 64.0, Yb: 20.0)

    /// Compresses the output RGB values into the gamut of the output
    /// colourspace.
    ///
    /// Upstream reference: `spektrafilm.utils.gamut_compression.compress_rgb`.
    ///
    /// - Parameters:
    ///   - rgb: the linear RGB values, three interleaved values per pixel.
    ///   - spec: the compression configuration.
    ///   - outputColourSpace: the colourspace of the values.
    /// - Returns: the compressed RGB values.
    public static func compressRGB(
        _ rgb: [Double],
        spec: OutputGamutCompressSpec,
        outputColourSpace: RGBColourspace = .sRGB
    ) -> [Double] {
        guard spec.active else { return rgb }
        switch spec.algorithm {
        case "cam16ucs":
            return compressRGBCAM16UCSChroma(
                rgb, spec: spec, outputColourSpace: outputColourSpace
            )
        default:
            return rgb
        }
    }

    /// The CAM16-UCS chroma reduction of the output RGB values.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.gamut_compression.compress_rgb_cam16ucs_chroma`.
    public static func compressRGBCAM16UCSChroma(
        _ rgb: [Double],
        spec: OutputGamutCompressSpec,
        outputColourSpace: RGBColourspace = .sRGB
    ) -> [Double] {
        let white = outputColourSpace.whitepoint
        let xyzWhite = ColourScience.xyToXYZ(white)
        let table = CAM16UCSCMaxTable.shared(for: outputColourSpace)

        let pixels = rgb.count / 3
        var result = [Double](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            let values = Array(rgb[pixel * 3..<(pixel * 3 + 3)])
            let xyz = ColourScience.rgbToXYZ(
                rgb: values,
                colourspace: outputColourSpace,
                illuminant: white,
                transform: .cat02,
                applyCCTFDecoding: false
            )
            var jab = CAM16.xyzToCAM16UCS(
                xyz: xyz,
                xyzWhite: xyzWhite,
                LA: cam16UCSViewingConditions.LA,
                Yb: cam16UCSViewingConditions.Yb
            )
            if let lightness = spec.lightnessCompression {
                let whiteJp = table.whiteJp
                jab[0] = compressLightness(jab[0], knee: lightness, white: whiteJp)
            }
            let chroma = (jab[1] * jab[1] + jab[2] * jab[2]).squareRoot()
            let hue = atan2(jab[2], jab[1])
            let maximum = table.lookup(Jp: jab[0], hue: hue)
            let safeMaximum = Swift.max(maximum, 1e-9)
            let normalised = chroma / safeMaximum
            let compressed = reinhardKnee(normalised, knee: spec.knee)
            let newChroma = compressed * safeMaximum
            let newJab = [
                jab[0],
                newChroma * cos(hue),
                newChroma * sin(hue),
            ]
            let newXYZ = CAM16.cam16UCStoXYZ(
                jab: newJab,
                xyzWhite: xyzWhite,
                LA: cam16UCSViewingConditions.LA,
                Yb: cam16UCSViewingConditions.Yb
            )
            let newRGB = ColourScience.xyzToRGB(
                xyz: newXYZ,
                colourspace: outputColourSpace,
                illuminant: white,
                transform: .cat02
            )
            for channel in 0..<3 {
                result[pixel * 3 + channel] = newRGB[channel]
            }
        }
        return result
    }

    /// The one-sided soft compression of a perceptual lightness.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.gamut_compression._compress_lightness`.
    public static func compressLightness(
        _ lightness: Double, knee: ReinhardKnee, white: Double
    ) -> Double {
        let normalised = lightness / white
        return reinhardKnee(normalised, knee: knee) * white
    }
}

// MARK: - The CAM16-UCS chroma table

/// The maximum in-gamut chroma of the CAM16-UCS colourspace, as a function
/// of the perceptual lightness and of the hue.
///
/// Upstream reference:
/// `spektrafilm.utils.gamut_compression._build_polar_perceptual_c_max_table`
/// and `spektrafilm.utils.gamut_compression._c_max_lookup`.
public final class CAM16UCSCMaxTable: @unchecked Sendable {

    /// The number of lightness samples of the table.
    public static let lightnessCount = 64
    /// The number of hue samples of the table.
    public static let hueCount = 720
    /// The number of bisection steps used to build the table.
    public static let bisectionSteps = 18

    /// The table of the maximum chroma, `[lightness][hue]`.
    public let values: [Double]
    /// The lightness axis of the table.
    public let lightnessGrid: [Double]
    /// The hue axis of the table.
    public let hueGrid: [Double]
    /// The CAM16-UCS lightness of the whitepoint of the output colourspace.
    public let whiteJp: Double

    /// The cached tables, keyed by the name of the output colourspace.
    private static var cache: [String: CAM16UCSCMaxTable] = [:]
    private static let cacheLock = NSLock()

    /// The table of an output colourspace (built once).
    public static func shared(for colourspace: RGBColourspace) -> CAM16UCSCMaxTable {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let table = cache[colourspace.name] { return table }
        let table = CAM16UCSCMaxTable(colourspace: colourspace)
        cache[colourspace.name] = table
        return table
    }

    /// Builds the table of an output colourspace.
    public init(colourspace: RGBColourspace) {
        let white = colourspace.whitepoint
        let xyzWhite = ColourScience.xyToXYZ(white)
        let LA = GamutCompression.cam16UCSViewingConditions.LA
        let Yb = GamutCompression.cam16UCSViewingConditions.Yb

        // The grids follow the `numpy.linspace` construction of the upstream
        // table, so that the bisection lands on the same cells.
        let lightnessStep = (110.0 - 1.0) / Double(CAM16UCSCMaxTable.lightnessCount - 1)
        let lightnessGrid = (0..<CAM16UCSCMaxTable.lightnessCount).map {
            1.0 + Double($0) * lightnessStep
        }
        let hueStep = 2.0 * Double.pi / Double(CAM16UCSCMaxTable.hueCount)
        let hueGrid = (0..<CAM16UCSCMaxTable.hueCount).map {
            -Double.pi + Double($0) * hueStep
        }

        var lower = [Double](repeating: 0, count: CAM16UCSCMaxTable.lightnessCount * CAM16UCSCMaxTable.hueCount)
        var upper = [Double](repeating: 150.0, count: lower.count)

        for _ in 0..<CAM16UCSCMaxTable.bisectionSteps {
            for lightnessIndex in 0..<CAM16UCSCMaxTable.lightnessCount {
                let lightness = lightnessGrid[lightnessIndex]
                for hueIndex in 0..<CAM16UCSCMaxTable.hueCount {
                    let index = lightnessIndex * CAM16UCSCMaxTable.hueCount + hueIndex
                    let mid = (lower[index] + upper[index]) * 0.5
                    let hue = hueGrid[hueIndex]
                    let xyz = CAM16.cam16UCStoXYZ(
                        jab: [lightness, mid * cos(hue), mid * sin(hue)],
                        xyzWhite: xyzWhite,
                        LA: LA,
                        Yb: Yb
                    )
                    let rgb = ColourScience.xyzToRGB(
                        xyz: xyz,
                        colourspace: colourspace,
                        illuminant: white,
                        transform: .cat02
                    )
                    let inGamut = rgb.allSatisfy { $0 >= -1e-6 && $0 <= 1.0 + 1e-6 }
                    if inGamut {
                        lower[index] = mid
                    } else {
                        upper[index] = mid
                    }
                }
            }
        }

        self.values = lower
        self.lightnessGrid = lightnessGrid
        self.hueGrid = hueGrid
        self.whiteJp = CAM16.xyzToCAM16UCS(
            xyz: xyzWhite,
            xyzWhite: xyzWhite,
            LA: LA,
            Yb: Yb
        )[0]
    }

    /// The maximum in-gamut chroma at a given lightness and hue.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.gamut_compression._c_max_lookup`.
    public func lookup(Jp: Double, hue: Double) -> Double {
        let lightness = Swift.min(Swift.max(Jp, lightnessGrid[0]), lightnessGrid[lightnessGrid.count - 1])
        let hueStep = hueGrid[1] - hueGrid[0]
        let hueIndex = (hue - hueGrid[0]) / hueStep
        let hueFloor = hueIndex.rounded(.down)
        let hueLow = positiveModulo(Int(hueFloor), hueGrid.count)
        let hueHigh = (hueLow + 1) % hueGrid.count
        let hueFraction = hueIndex - hueFloor

        let lightnessIndex = (lightness - lightnessGrid[0])
            / (lightnessGrid[lightnessGrid.count - 1] - lightnessGrid[0])
            * Double(lightnessGrid.count - 1)
        let lightnessFloor = lightnessIndex.rounded(.down)
        let lightnessLow = Swift.min(Swift.max(Int(lightnessFloor), 0), lightnessGrid.count - 2)
        let lightnessHigh = lightnessLow + 1
        let lightnessFraction = lightnessIndex - Double(lightnessLow)

        let v00 = values[lightnessLow * hueGrid.count + hueLow]
        let v01 = values[lightnessLow * hueGrid.count + hueHigh]
        let v10 = values[lightnessHigh * hueGrid.count + hueLow]
        let v11 = values[lightnessHigh * hueGrid.count + hueHigh]
        return v00 * (1 - lightnessFraction) * (1 - hueFraction)
            + v01 * (1 - lightnessFraction) * hueFraction
            + v10 * lightnessFraction * (1 - hueFraction)
            + v11 * lightnessFraction * hueFraction
    }

    /// The positive modulo of an integer.
    private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let result = value % modulus
        return result < 0 ? result + modulus : result
    }
}
