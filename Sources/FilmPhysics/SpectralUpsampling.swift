//
//  SpectralUpsampling.swift
//  light suffer胶片 — iOS app
//
//  The hanatos 2025 spectral upsampling: the RGB → spectrum → raw sensor
//  response conversion of the camera stage.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

// MARK: - Adaptation parameters

/// The hanatos 2025 sensitivity adaptation parameters of a film.
///
/// Upstream reference:
/// `spektrafilm.profiles.io.Hanatos2025SensitivityAdaptation` and
/// `spektrafilm.profiles.io.Profile.hanatos2025_adaptation`.
public struct Hanatos2025Adaptation: Equatable, Sendable {
    /// The parameters of the spectral band pass window (4 for `erf4`,
    /// 8 for `logiflex8`).
    public var windowParams: [Double]
    /// The model of the spectral band pass window (`"erf4"` or `"logiflex8"`).
    public var windowModel: String
    /// The parameters of the log exposure correction surface (3 × 15).
    public var surfaceParams: [[Double]]
    /// The model of the log exposure correction surface (`"poly4"` or
    /// `"poly4_warp_xy"`).
    public var surfaceModel: String
    /// The sigma (in nm) of the Gaussian blur applied to the spectra.
    public var spectralGaussianBlur: Double
    /// The reference illuminant of the adaptation (`"D55"` for the shipped
    /// stocks).
    public var referenceIlluminant: String
    /// Whether the band pass window is applied.
    public var applyWindow: Bool
    /// Whether the log exposure correction surface is applied.
    public var applySurface: Bool

    public init(
        windowParams: [Double] = [],
        windowModel: String = "erf4",
        surfaceParams: [[Double]] = [],
        surfaceModel: String = "poly4",
        spectralGaussianBlur: Double = 0,
        referenceIlluminant: String = "D55",
        applyWindow: Bool = true,
        applySurface: Bool = false
    ) {
        self.windowParams = windowParams
        self.windowModel = windowModel
        self.surfaceParams = surfaceParams
        self.surfaceModel = surfaceModel
        self.spectralGaussianBlur = spectralGaussianBlur
        self.referenceIlluminant = referenceIlluminant
        self.applyWindow = applyWindow
        self.applySurface = applySurface
    }
}

// MARK: - The tc lookup table

/// The hanatos 2025 tc lookup table.
///
/// The table maps a chromaticity (in the "tc" grid coordinates of the
/// hanatos 2025 irradiance table) to the raw sensor response of the three
/// channels, for a given film sensitivity.
///
/// Upstream reference: `spektrafilm.utils.spectral_upsampling.compute_hanatos2025_tc_lut`.
public struct HanatosTCLUT: Equatable, Sendable {

    /// The size of the (square) grid.
    public let size: Int
    /// The table values, `size * size * 3`, indexed by
    /// `(i * size + j) * 3 + channel`.
    public let values: [Double]

    public init(size: Int, values: [Double]) {
        self.size = size
        self.values = values
    }

    /// The value of a grid cell.
    public subscript(i: Int, j: Int, channel: Int) -> Double {
        values[(i * size + j) * 3 + channel]
    }
}

// MARK: - Spectral upsampling

/// The hanatos 2025 spectral upsampling.
public enum SpectralUpsampling {

    /// The maximum correction of the hanatos 2025 log exposure surface, in
    /// stops.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.spectral_upsampling._HANATOS2025_MAX_CORRECTION_STOPS`.
    public static let maxCorrectionStops = 2.0

    // MARK: - Coordinate transforms

    /// Converts a CIE `xy` chromaticity into the lookup coordinates of the
    /// hanatos 2025 table.
    ///
    /// Upstream reference: `spektrafilm.utils.spectral_upsampling._tri2quad`.
    ///
    /// ```
    /// u = (1 - x)²
    /// v = y / max(1 - x, 1e-10)
    /// ```
    ///
    /// The upstream function is named after the *output* space: it takes the
    /// CIE `xy` values and returns the coordinates of the square (quad)
    /// lookup grid.
    public static func xyToTC(_ xy: Chromaticity) -> (u: Double, v: Double) {
        let u = (1.0 - xy.x) * (1.0 - xy.x)
        let v = xy.y / Swift.max(1.0 - xy.x, 1e-10)
        return (Swift.min(Swift.max(u, 0), 1), Swift.min(Swift.max(v, 0), 1))
    }

    /// Converts the lookup coordinates of the hanatos 2025 table into a CIE
    /// `xy` chromaticity.
    ///
    /// Upstream reference: `spektrafilm.utils.spectral_upsampling._quad2tri`.
    ///
    /// ```
    /// x = 1 - sqrt(u)
    /// y = v · sqrt(u)
    /// ```
    public static func tcToXY(_ tc: (u: Double, v: Double)) -> Chromaticity {
        let root = max(tc.u, 0).squareRoot()
        return Chromaticity(x: 1.0 - root, y: tc.v * root)
    }

    // MARK: - The RGB → (tc, b) conversion

    /// Converts an RGB triplet into the lookup coordinates of the hanatos
    /// 2025 table and the luminance scale factor `b`.
    ///
    /// Upstream reference: `spektrafilm.utils.spectral_upsampling._rgb_to_tc_b`.
    ///
    /// ```
    /// xyz = RGB_to_XYZ(rgb, colourspace, illuminant, CAT16)
    /// b   = X + Y + Z
    /// xy  = (X, Y) / max(b, 1e-10)
    /// tc  = ((1 - x)², y / (1 - x))
    /// ```
    ///
    /// - Parameters:
    ///   - rgb: the RGB values of the pixel (encoded when
    ///     `applyCCTFDecoding` is true).
    ///   - colourspace: the colourspace of the values.
    ///   - applyCCTFDecoding: whether the values are encoded.
    ///   - referenceIlluminant: the chromaticity of the reference illuminant
    ///     of the film (the chromatic adaptation target).
    public static func rgbToTCB(
        rgb: [Double],
        colourspace: RGBColourspace,
        applyCCTFDecoding: Bool,
        referenceIlluminant: Chromaticity
    ) -> (tc: (u: Double, v: Double), b: Double) {
        let xyz = ColourScience.rgbToXYZ(
            rgb: rgb,
            colourspace: colourspace,
            illuminant: referenceIlluminant,
            transform: .cat16,
            applyCCTFDecoding: applyCCTFDecoding
        )
        let b = xyz[0] + xyz[1] + xyz[2]
        let denominator = Swift.max(b, 1e-10)
        let xy = Chromaticity(x: xyz[0] / denominator, y: xyz[1] / denominator)
        return (xyToTC(xy), Numerics.nanToNum(b))
    }

    // MARK: - The band pass window

    /// The spectral band pass window of the hanatos 2025 adaptation.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.spectral_upsampling.eval_spectral_bandpass_window`.
    ///
    /// - Parameters:
    ///   - params: the parameters of the window.
    ///   - model: `"erf4"` (the 4 parameter error function window) or
    ///     `"logiflex8"` (the 8 parameter log-iflex window).
    ///   - wavelengths: the spectral sampling.
    /// - Returns: the window, `[wavelength][channel]`.
    public static func spectralBandpassWindow(
        params: [Double],
        model: String = "erf4",
        wavelengths: [Double]
    ) -> [[Double]] {
        switch model {
        case "logiflex8":
            return logiflex8Window(params: params, wavelengths: wavelengths)
        case "erf4":
            return erf4Window(params: params, wavelengths: wavelengths)
        default:
            return []
        }
    }

    /// The 4 parameter error function band pass window.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.spectral_upsampling.eval_erf4_spectral_bandpass`.
    ///
    /// ```
    /// edge_uv = 0.5 · (1 + erf((λ - c_uv) / (σ_uv √2)))
    /// edge_ir = 0.5 · (1 - erf((λ - c_ir) / (σ_ir √2)))
    /// window  = edge_uv · edge_ir          (the three channels share it)
    /// ```
    private static func erf4Window(params: [Double], wavelengths: [Double]) -> [[Double]] {
        guard params.count >= 4 else { return [] }
        let cUV = params[0], sigmaUV = params[1]
        let cIR = params[2], sigmaIR = params[3]
        let sqrt2 = 1.4142135623730951
        return wavelengths.map { wavelength in
            let edgeUV = 0.5 * (1.0 + Numerics.erf((wavelength - cUV) / (sigmaUV * sqrt2)))
            let edgeIR = 0.5 * (1.0 - Numerics.erf((wavelength - cIR) / (sigmaIR * sqrt2)))
            let common = edgeUV * edgeIR
            return [common, common, common]
        }
    }

    /// The 8 parameter log-iflex band pass window.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.spectral_upsampling.eval_logiflex8_spectral_bandpass`
    /// and `locked_logistic_rising`.
    private static func logiflex8Window(params: [Double], wavelengths: [Double]) -> [[Double]] {
        guard params.count >= 8 else { return [] }
        let cUVBase = params[0], sigmaUV = params[1]
        let cIRBase = params[2], sigmaIR = params[3]
        let cUVB = params[4], cIRR = params[5]
        let nuUV = params[6], nuIR = params[7]
        let cuv = [cUVBase, cUVBase, cUVB]
        let cir = [cIRR, cIRBase, cIRBase]
        return wavelengths.map { wavelength in
            (0..<3).map { channel in
                let edgeUV = lockedLogisticRising(
                    wavelength, mu: cuv[channel], sigma: sigmaUV, nu: nuUV
                )
                let edgeIR = 1.0 - lockedLogisticRising(
                    wavelength, mu: cir[channel], sigma: sigmaIR, nu: nuIR
                )
                return edgeUV * edgeIR
            }
        }
    }

    /// The rising flex-and-sigma-locked logistic function.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.spectral_upsampling.locked_logistic_rising`.
    private static func lockedLogisticRising(
        _ x: Double, mu: Double, sigma: Double, nu: Double
    ) -> Double {
        let nu = Swift.max(nu, 1e-5)
        let slope = 1.0 / (sigma * 2.5066282746310002)  // sqrt(2 pi)
        let k = (2.0 * nu * slope) / (1.0 - pow(2.0, -nu))
        let exponent = Swift.min(Swift.max(-k * (x - mu), -500.0), 500.0)
        let nuLog2 = nu * log(2.0)
        let logQ = nuLog2 > 50.0
            ? nuLog2 + log1p(-exp(-nuLog2))
            : log(expm1(nuLog2))
        // logaddexp(0, log_q + exponent)
        let first = 0.0
        let second = logQ + exponent
        let logDenominator = Swift.max(first, second) + log1p(exp(-abs(first - second)))
        return exp(-(1.0 / nu) * logDenominator)
    }

    // MARK: - The log exposure correction surface

    /// The log exposure correction surface of the hanatos 2025 adaptation.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.spectral_upsampling.eval_log_exposure_correction_surface`.
    ///
    /// - Parameters:
    ///   - params: the parameters of the surface (3 × 15).
    ///   - illuminant: the chromaticity of the reference illuminant.
    ///   - model: `"poly4"` or `"poly4_warp_xy"`.
    ///   - size: the size of the grid.
    /// - Returns: the correction, in stops, `[i][j][channel]`.
    public static func logExposureCorrectionSurface(
        params: [[Double]],
        illuminant: Chromaticity,
        model: String = "poly4",
        size: Int = Resources.tcGridSize
    ) -> [[Double]] {
        var surface = [[Double]](repeating: [Double](repeating: 0, count: 3), count: size * size)
        let tcCenter = xyToTC(illuminant)
        for index in 0..<size {
            for jndex in 0..<size {
                let u = Double(index) / Double(size - 1)
                let v = Double(jndex) / Double(size - 1)
                var xy = tcToXY((u: u, v: v))
                if model == "poly4_warp_xy" {
                    xy = radialMobiusWarp(xy, center: illuminant, alpha: params[0].last ?? 0)
                }
                let warped = xyToTC(xy)
                for channel in 0..<3 {
                    let channelParams = params[min(channel, params.count - 1)]
                    let raw = poly2dDegree4(
                        (u: warped.u, v: warped.v),
                        params: channelParams,
                        center: tcCenter
                    )
                    surface[index * size + jndex][channel] = hanikaSigmoid(raw, maxCorrectionStops)
                }
            }
        }
        return surface
    }

    /// The radial Möbius warp of the chromaticity.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.spectral_upsampling._radial_mobius_warp_xy`.
    public static func radialMobiusWarp(
        _ xy: Chromaticity, center: Chromaticity, alpha: Double
    ) -> Chromaticity {
        let dx = xy.x - center.x
        let dy = xy.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let scale = 1.0 / (1.0 + alpha * distance)
        return Chromaticity(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    /// The degree 4 polynomial of the log exposure correction surface.
    ///
    /// Upstream reference: `spektrafilm.utils.spectral_upsampling.poly2d_deg4`.
    public static func poly2dDegree4(
        _ tc: (u: Double, v: Double),
        params: [Double],
        center: (u: Double, v: Double)
    ) -> Double {
        guard params.count >= 15 else { return 0 }
        let x = tc.u - center.u
        let y = tc.v - center.v
        let x2 = x * x, y2 = y * y
        let x3 = x2 * x, y3 = y2 * y
        let c1 = params[1], c2 = params[2], c3 = params[3], c4 = params[4], c5 = params[5]
        let c6 = params[6], c7 = params[7], c8 = params[8], c9 = params[9]
        let c10 = params[10], c11 = params[11], c12 = params[12], c13 = params[13]
        let c14 = params[14]
        return c1 * x + c2 * y + c3 * x2 + c4 * y2 + c5 * x * y
            + c6 * x3 + c7 * y3 + c8 * (x2 * y) + c9 * (x * y2)
            + c10 * (x2 * x2) + c11 * (y2 * y2) + c12 * (x3 * y) + c13 * (x2 * y2)
            + c14 * (x * y3)
    }

    /// The algebraic sigmoid of Jakob & Hanika (2019).
    ///
    /// Upstream reference: `spektrafilm.utils.spectral_upsampling.hanika_sigmoid`.
    public static func hanikaSigmoid(_ z: Double, _ maxValue: Double) -> Double {
        z / (1.0 + (z / maxValue) * (z / maxValue)).squareRoot()
    }

    // MARK: - The tc lookup table

    /// Computes the tc lookup table of a film.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.spectral_upsampling.compute_hanatos2025_tc_lut`.
    ///
    /// ```
    /// raw_lut[i, j, m] = Σ_l spectra[i, j, l] · sensitivity[l, m] · window[l, m]
    /// raw_lut         *= 2 ** surface
    /// raw_lut          = remap_tc_lut_for_compression(raw_lut, reference_xy, spec)
    /// ```
    ///
    /// - Parameters:
    ///   - sensitivity: the spectral sensitivity of the film, `[wavelength][channel]`.
    ///   - adaptation: the hanatos 2025 adaptation of the film.
    ///   - gamutCompress: the input gamut compression baked into the table.
    ///   - spectra: the hanatos 2025 irradiance spectra table.
    ///   - illuminant: the reference illuminant spectrum of the adaptation.
    ///   - wavelengths: the spectral sampling.
    /// - Returns: the lookup table.
    public static func computeHanatos2025TCLUT(
        sensitivity: [[Double]],
        adaptation: Hanatos2025Adaptation,
        gamutCompress: InputGamutCompressSpec? = nil,
        spectra: [Float],
        illuminant: [Double],
        wavelengths: [Double]
    ) -> HanatosTCLUT {
        let size = Resources.tcGridSize
        let channelCount = sensitivity.first?.count ?? 3
        var values = [Double](repeating: 0, count: size * size * channelCount)

        // The band pass window, normalised so that it preserves the white
        // balance of the film.
        var window: [[Double]]? = nil
        if adaptation.applyWindow {
            let raw = spectralBandpassWindow(
                params: adaptation.windowParams,
                model: adaptation.windowModel,
                wavelengths: wavelengths
            )
            if raw.count == wavelengths.count {
                // normalization[m] = Σ_l s[l][m] · ill[l] · w[l][m]
                //                 / Σ_l s[l][m] · ill[l]
                var numerator = [Double](repeating: 0, count: channelCount)
                var denominator = [Double](repeating: 0, count: channelCount)
                for wavelength in 0..<wavelengths.count {
                    let illuminantValue = illuminant[wavelength]
                    for channel in 0..<channelCount {
                        let sensitivityValue = sensitivity[wavelength][channel]
                        numerator[channel] += sensitivityValue * illuminantValue
                            * raw[wavelength][channel]
                        denominator[channel] += sensitivityValue * illuminantValue
                    }
                }
                var normalized = [[Double]](
                    repeating: [Double](repeating: 0, count: channelCount),
                    count: wavelengths.count
                )
                for wavelength in 0..<wavelengths.count {
                    for channel in 0..<channelCount {
                        let scale = denominator[channel] != 0
                            ? numerator[channel] / denominator[channel]
                            : 1.0
                        normalized[wavelength][channel] = raw[wavelength][channel] / scale
                    }
                }
                window = normalized
            }
        }

        // The spectral sum.
        let spectralCount = sensitivity.count
        for wavelength in 0..<spectralCount {
            guard wavelength < wavelengths.count else { break }
            for index in 0..<(size * size) {
                let base = index * channelCount
                let spectralValue = Double(spectra[index * spectralCount + wavelength])
                for channel in 0..<channelCount {
                    var weight = sensitivity[wavelength][channel]
                    if let window {
                        weight *= window[wavelength][channel]
                    }
                    values[base + channel] += spectralValue * weight
                }
            }
        }

        // The log exposure correction surface.
        if adaptation.applySurface, !adaptation.surfaceParams.isEmpty {
            let referenceXY = Illuminants.chromaticity(
                of: adaptation.referenceIlluminant,
                illuminants: Illuminants.cached(),
                colourMatchingFunctions: Illuminants.cachedColourMatchingFunctions()
            )
            let surface = logExposureCorrectionSurface(
                params: adaptation.surfaceParams,
                illuminant: referenceXY,
                model: adaptation.surfaceModel,
                size: size
            )
            for index in 0..<(size * size) {
                for channel in 0..<channelCount {
                    values[index * channelCount + channel] *= pow(2.0, surface[index][channel])
                }
            }
        }

        var lut = HanatosTCLUT(size: size, values: values)

        // The input gamut compression is baked into the table.
        if let gamutCompress, gamutCompress.active {
            let referenceXY = Illuminants.chromaticity(
                of: adaptation.referenceIlluminant,
                illuminants: Illuminants.cached(),
                colourMatchingFunctions: Illuminants.cachedColourMatchingFunctions()
            )
            lut = GamutCompression.remapTCLUTForCompression(
                lut: lut,
                referenceIlluminantXY: referenceXY,
                spec: gamutCompress
            )
        }
        return lut
    }

    // MARK: - The lookup

    /// The Mitchell–Netravali cubic kernel weight.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.fast_interp_lut.mitchell_weight` (`B = C = 1/3`).
    public static func mitchellWeight(_ t: Double) -> Double {
        let x = abs(t)
        let b = 1.0 / 3.0
        let c = 1.0 / 3.0
        if x < 1 {
            return (1.0 / 6.0) * (
                (12 - 9 * b - 6 * c) * x * x * x + (-18 + 12 * b + 6 * c) * x * x + (6 - 2 * b)
            )
        }
        if x < 2 {
            return (1.0 / 6.0) * (
                (-b - 6 * c) * x * x * x + (6 * b + 30 * c) * x * x + (-12 * b - 48 * c) * x
                    + (8 * b + 24 * c)
            )
        }
        return 0
    }

    /// Reflects an index into the valid range, the way the upstream kernel
    /// does.
    ///
    /// Upstream reference: `spektrafilm.utils.fast_interp_lut.safe_index`.
    public static func reflectedIndex(_ index: Int, length: Int) -> Int {
        if index < 0 { return -index }
        if index >= length { return 2 * (length - 1) - index }
        return index
    }

    /// Maps a clamped coordinate onto a cubic interpolation cell.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.fast_interp_lut.cubic_coordinate_base_fraction`.
    public static func cubicCoordinateBaseFraction(_ coordinate: Double, length: Int) -> (Int, Double) {
        let clamped = Swift.min(Swift.max(coordinate, 0), Double(length - 1))
        if clamped >= Double(length - 1) {
            return (length - 2, 1.0)
        }
        let base = Int(clamped.rounded(.down))
        return (base, clamped - Double(base))
    }

    /// Looks a point up in the tc table with the upstream cubic kernel.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.fast_interp_lut._cubic_interp_lut_at_2d`.
    ///
    /// - Parameters:
    ///   - lut: the lookup table.
    ///   - u: the first lookup coordinate, in the [0, 1] range.
    ///   - v: the second lookup coordinate, in the [0, 1] range.
    /// - Returns: the three raw responses.
    public static func lookup(lut: HanatosTCLUT, u: Double, v: Double) -> [Double] {
        let size = lut.size
        let channelCount = 3
        let (uBase, uFraction) = cubicCoordinateBaseFraction(u * Double(size - 1), length: size)
        let (vBase, vFraction) = cubicCoordinateBaseFraction(v * Double(size - 1), length: size)

        var weightsU = [Double](repeating: 0, count: 4)
        var weightsV = [Double](repeating: 0, count: 4)
        weightsU[0] = mitchellWeight(uFraction + 1)
        weightsU[1] = mitchellWeight(uFraction)
        weightsU[2] = mitchellWeight(uFraction - 1)
        weightsU[3] = mitchellWeight(uFraction - 2)
        weightsV[0] = mitchellWeight(vFraction + 1)
        weightsV[1] = mitchellWeight(vFraction)
        weightsV[2] = mitchellWeight(vFraction - 1)
        weightsV[3] = mitchellWeight(vFraction - 2)

        var out = [Double](repeating: 0, count: channelCount)
        var weightSum = 0.0
        for i in 0..<4 {
            let ui = reflectedIndex(uBase - 1 + i, length: size)
            for j in 0..<4 {
                let vj = reflectedIndex(vBase - 1 + j, length: size)
                let weight = weightsU[i] * weightsV[j]
                weightSum += weight
                for channel in 0..<channelCount {
                    out[channel] += weight * lut[ui, vj, channel]
                }
            }
        }
        if weightSum != 0 {
            for channel in 0..<channelCount {
                out[channel] /= weightSum
            }
        }
        return out
    }

    /// Converts an RGB image into the raw sensor response of the film.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.spectral_upsampling.rgb_to_raw_hanatos2025`.
    ///
    /// - Parameters:
    ///   - rgb: the RGB values of the pixels, three interleaved values per pixel.
    ///   - lut: the tc lookup table of the film.
    ///   - colourspace: the colourspace of the values.
    ///   - applyCCTFDecoding: whether the values are encoded.
    ///   - referenceIlluminant: the chromaticity of the reference illuminant.
    /// - Returns: the raw responses, three interleaved values per pixel.
    public static func rgbToRaw(
        rgb: [Double],
        lut: HanatosTCLUT,
        colourspace: RGBColourspace,
        applyCCTFDecoding: Bool,
        referenceIlluminant: Chromaticity
    ) -> [Double] {
        let pixels = rgb.count / 3
        var raw = [Double](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            let values = Array(rgb[pixel * 3..<(pixel * 3 + 3)])
            let result = rgbToTCB(
                rgb: values,
                colourspace: colourspace,
                applyCCTFDecoding: applyCCTFDecoding,
                referenceIlluminant: referenceIlluminant
            )
            let response = lookup(lut: lut, u: result.tc.u, v: result.tc.v)
            for channel in 0..<3 {
                raw[pixel * 3 + channel] = response[channel] * result.b
            }
        }
        return raw
    }
}
