//
//  FilmPlanEvaluator.swift
//  light suffer胶片 — iOS app
//
//  The pure Swift evaluator of the render plan: the per pixel chain of the
//  simulation, evaluated from the precomputed data of the plan.
//
//  This evaluator is the **specification of the Metal kernel**: the two
//  implement the very same computation, on the very same numbers (the plan
//  stores them in `Float32`). The evaluator is the reference the Metal
//  kernel is validated against on the machines that have a GPU.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

// MARK: - The taps

/// The taps of the plan evaluator.
public struct FilmPlanTaps: Equatable, Sendable {
    /// The log10 exposure of the negative.
    public var logEFilm: RGBImage
    /// The developed densities of the negative.
    public var cmyFilm: RGBImage
    /// The log10 exposure of the paper.
    public var logEPrint: RGBImage
    /// The developed densities of the print.
    public var cmyPrint: RGBImage
    /// The scanned and encoded print.
    public var rgbOut: RGBImage

    public init(
        logEFilm: RGBImage,
        cmyFilm: RGBImage,
        logEPrint: RGBImage,
        cmyPrint: RGBImage,
        rgbOut: RGBImage
    ) {
        self.logEFilm = logEFilm
        self.cmyFilm = cmyFilm
        self.logEPrint = logEPrint
        self.cmyPrint = cmyPrint
        self.rgbOut = rgbOut
    }
}

// MARK: - The evaluator

/// The per pixel evaluation of a ``FilmRenderPlan``.
///
/// The chain is the one of the upstream engine, without the spatial effects
/// (the halation, the diffusion filters, the lens blurs, the unsharp mask
/// and the spatial diffusion of the DIR couplers): those are spatial passes,
/// they are inserted between the per pixel stages of the GPU pipeline.
///
/// ```
/// rgb_in ──▶ raw ──▶ log_e_film ──▶ cmy_film ──▶ log_e_print ──▶ cmy_print ──▶ rgb_out
/// ```
public enum FilmPlanEvaluator {

    /// Evaluates the plan on an image.
    ///
    /// - Parameters:
    ///   - plan: the precomputed data of the render.
    ///   - rgbIn: the camera image, in the input colourspace of the plan.
    /// - Returns: the taps of the chain.
    /// - Throws: `PipelineError.invalidImageData` when the image does not
    ///   match its dimensions.
    public static func evaluate(
        plan: FilmRenderPlan,
        rgbIn: RGBImage
    ) throws -> FilmPlanTaps {
        guard rgbIn.data.count == rgbIn.width * rgbIn.height * 3 else {
            throw PipelineError.invalidImageData(
                "expected \(rgbIn.width * rgbIn.height * 3) values for a "
                    + "\(rgbIn.width)x\(rgbIn.height) image, got \(rgbIn.data.count)"
            )
        }
        let pixels = rgbIn.width * rgbIn.height

        // --- the filming stage ------------------------------------------
        var raw = spectralUpsample(plan: plan, rgb: rgbIn.data)
        for index in 0..<raw.count {
            raw[index] *= Double(plan.exposureScale)
        }
        if plan.boostActive {
            raw = boostHighlights(raw: raw, plan: plan)
        }
        var logEFilm = [Double](repeating: 0, count: pixels * 3)
        for index in 0..<logEFilm.count {
            logEFilm[index] = log10(Swift.max(raw[index] * Double(plan.filmingScale), 0.0) + 1e-10)
        }

        // --- the development of the negative ------------------------------
        var cmyFilm = [Double](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            for channel in 0..<3 {
                cmyFilm[pixel * 3 + channel] = plan.filmCurve.sample(
                    logEFilm[pixel * 3 + channel], channel: channel
                )
            }
        }
        if plan.couplersActive {
            var corrected = logEFilm
            for pixel in 0..<pixels {
                var silver = [Double](repeating: 0, count: 3)
                for channel in 0..<3 {
                    let density = cmyFilm[pixel * 3 + channel]
                    silver[channel] = plan.couplerPositive
                        ? Double(plan.densityMax[channel]) - density
                        : density
                }
                for receiver in 0..<3 {
                    var amount = 0.0
                    for donor in 0..<3 {
                        amount += silver[donor] * Double(plan.couplerMatrix[donor * 3 + receiver])
                    }
                    corrected[pixel * 3 + receiver] = logEFilm[pixel * 3 + receiver] - amount
                }
            }
            for pixel in 0..<pixels {
                for channel in 0..<3 {
                    cmyFilm[pixel * 3 + channel] = plan.filmCurveBeforeCouplers.sample(
                        corrected[pixel * 3 + channel], channel: channel
                    )
                }
            }
        }

        // --- the printing stage -------------------------------------------
        // The direct scan path (`io.scan_film`) skips the printing stage
        // entirely: the negative is scanned as it is.
        let wavelengths = plan.filmBaseDensity.count
        var logEPrint = [Double](repeating: 0, count: plan.scanFilm ? 0 : pixels * 3)
        var cmyPrint = [Double](repeating: 0, count: plan.scanFilm ? 0 : pixels * 3)
        var light = [Double](repeating: 0, count: wavelengths)
        if !plan.scanFilm {
            for pixel in 0..<pixels {
                for wavelength in 0..<wavelengths {
                    var density = Double(plan.filmBaseDensity[wavelength])
                    for channel in 0..<3 {
                        density += cmyFilm[pixel * 3 + channel]
                            * Double(plan.filmChannelDensity[wavelength * 3 + channel])
                    }
                    let value = pow(10.0, -density) * Double(plan.printIlluminant[wavelength])
                    light[wavelength] = value.isNaN ? 0 : value
                }
                for channel in 0..<3 {
                    var total = 0.0
                    for wavelength in 0..<wavelengths {
                        total += light[wavelength] * Double(plan.printSensitivity[wavelength * 3 + channel])
                    }
                    let rawPrint = total * Double(plan.exposureFactor) + Double(plan.preflash[channel])
                    let linear = (Swift.max(rawPrint, 0.0) + 1e-10)
                        * Double(plan.printExposure)
                        * Double(plan.printingExposureCorrection)
                    logEPrint[pixel * 3 + channel] = log10(Swift.max(linear, 0.0) + 1e-10)
                }
            }

            // --- the development of the paper ----------------------------------
            for pixel in 0..<pixels {
                for channel in 0..<3 {
                    cmyPrint[pixel * 3 + channel] = plan.printCurve.sample(
                        logEPrint[pixel * 3 + channel], channel: channel
                    )
                }
            }
        }

        // --- the scanning stage --------------------------------------------
        // The densities that are scanned: the densities of the paper of the
        // print and scan path, the densities of the negative itself of the
        // direct scan path.
        let scanned = plan.scanFilm ? cmyFilm : cmyPrint
        var xyz = [Double](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            for wavelength in 0..<wavelengths {
                var density = Double(plan.scanBaseDensity[wavelength])
                for channel in 0..<3 {
                    density += scanned[pixel * 3 + channel]
                        * Double(plan.scanChannelDensity[wavelength * 3 + channel])
                }
                let value = pow(10.0, -density) * Double(plan.scanIlluminant[wavelength])
                light[wavelength] = value.isNaN ? 0 : value
            }
            for component in 0..<3 {
                var total = 0.0
                for wavelength in 0..<wavelengths {
                    total += light[wavelength]
                        * Double(plan.colourMatchingFunctions[wavelength * 3 + component])
                }
                xyz[pixel * 3 + component] = total / Double(plan.scanNormalization)
            }
        }
        // The `log10` / `pow(10)` round trip of the upstream scanning stage.
        for index in 0..<xyz.count {
            xyz[index] = Swift.max(xyz[index], 0.0) + 1e-10
        }
        // The black / white correction of the scanned tristimulus values.
        if plan.colorReferenceSlope != 1 || plan.colorReferenceOffset != 0 {
            for pixel in 0..<pixels {
                let y = xyz[pixel * 3 + 1]
                let corrected = Swift.min(
                    Swift.max(Double(plan.colorReferenceSlope) * y + Double(plan.colorReferenceOffset), 0),
                    1
                )
                let scale = corrected / (y + 1e-10)
                for channel in 0..<3 {
                    xyz[pixel * 3 + channel] *= scale
                }
            }
        }

        // XYZ -> RGB (the row vector product of the reference fixtures).
        var rgb = [Double](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            for channel in 0..<3 {
                var total = 0.0
                for component in 0..<3 {
                    total += xyz[pixel * 3 + component]
                        * Double(plan.xyzToRGB[component * 3 + channel])
                }
                rgb[pixel * 3 + channel] = total
            }
        }

        // The output gamut compression.
        if let gamut = plan.gamutCompression {
            rgb = compressGamut(rgb, gamut: gamut)
        }

        // The output transfer function.
        for pixel in 0..<pixels {
            for channel in 0..<3 {
                var total = 0.0
                for component in 0..<3 {
                    total += Double(plan.srgbToSRGB[component * 3 + channel])
                        * rgb[pixel * 3 + component]
                }
                rgb[pixel * 3 + channel] = plan.outputEncoded
                    ? Colour.sRGBEncode(total)
                    : total
            }
        }

        return FilmPlanTaps(
            logEFilm: RGBImage(width: rgbIn.width, height: rgbIn.height, data: logEFilm),
            cmyFilm: RGBImage(width: rgbIn.width, height: rgbIn.height, data: cmyFilm),
            logEPrint: RGBImage(
                width: plan.scanFilm ? 0 : rgbIn.width,
                height: plan.scanFilm ? 0 : rgbIn.height,
                data: logEPrint
            ),
            cmyPrint: RGBImage(
                width: plan.scanFilm ? 0 : rgbIn.width,
                height: plan.scanFilm ? 0 : rgbIn.height,
                data: cmyPrint
            ),
            rgbOut: RGBImage(width: rgbIn.width, height: rgbIn.height, data: rgb)
        )
    }

    // MARK: - The spectral upsampling

    /// The raw sensor response of the negative, from the camera image.
    ///
    /// This is the hanatos 2025 upsampling of the upstream engine: the RGB
    /// triplet is turned into a chromaticity, the chromaticity is looked up in
    /// the tc table with the cubic kernel of the upstream, and the response
    /// is scaled by the luminance of the pixel.
    public static func spectralUpsample(plan: FilmRenderPlan, rgb: [Double]) -> [Double] {
        let pixels = rgb.count / 3
        var raw = [Double](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            var linear = [Double](repeating: 0, count: 3)
            for channel in 0..<3 {
                linear[channel] = decode(
                    rgb[pixel * 3 + channel], cctf: plan.inputCCTF
                )
            }
            var xyz = [Double](repeating: 0, count: 3)
            for row in 0..<3 {
                var total = 0.0
                for column in 0..<3 {
                    total += Double(plan.inputRGBToXYZ[row * 3 + column]) * linear[column]
                }
                xyz[row] = total
            }
            let b = xyz[0] + xyz[1] + xyz[2]
            let safeB = b.isNaN ? 0 : b
            let denominator = Swift.max(safeB, 1e-10)
            let x = xyz[0] / denominator
            let y = xyz[1] / denominator
            // The triangular chromaticity of the lookup table.
            let u = Swift.min(Swift.max((1.0 - x) * (1.0 - x), 0), 1)
            let v = Swift.min(Swift.max(y / Swift.max(1.0 - x, 1e-10), 0), 1)
            let response = tcLookup(plan: plan, u: u, v: v)
            for channel in 0..<3 {
                raw[pixel * 3 + channel] = response[channel] * safeB
            }
        }
        return raw
    }

    /// The decoding of an input value.
    private static func decode(_ value: Double, cctf: Int) -> Double {
        switch cctf {
        case 1:
            return Colour.sRGBDecode(value)
        case 2:
            return Colour.proPhotoDecode(value)
        default:
            return value
        }
    }

    /// The cubic lookup of the hanatos 2025 table.
    private static func tcLookup(plan: FilmRenderPlan, u: Double, v: Double) -> [Double] {
        let size = plan.tcLUTSize
        guard size > 1 else { return [0, 0, 0] }
        let (uBase, uFraction) = SpectralUpsampling.cubicCoordinateBaseFraction(
            u * Double(size - 1), length: size
        )
        let (vBase, vFraction) = SpectralUpsampling.cubicCoordinateBaseFraction(
            v * Double(size - 1), length: size
        )
        var weightsU = [Double](repeating: 0, count: 4)
        var weightsV = [Double](repeating: 0, count: 4)
        weightsU[0] = SpectralUpsampling.mitchellWeight(uFraction + 1)
        weightsU[1] = SpectralUpsampling.mitchellWeight(uFraction)
        weightsU[2] = SpectralUpsampling.mitchellWeight(uFraction - 1)
        weightsU[3] = SpectralUpsampling.mitchellWeight(uFraction - 2)
        weightsV[0] = SpectralUpsampling.mitchellWeight(vFraction + 1)
        weightsV[1] = SpectralUpsampling.mitchellWeight(vFraction)
        weightsV[2] = SpectralUpsampling.mitchellWeight(vFraction - 1)
        weightsV[3] = SpectralUpsampling.mitchellWeight(vFraction - 2)

        var out = [Double](repeating: 0, count: 3)
        var weightSum = 0.0
        for i in 0..<4 {
            let ui = SpectralUpsampling.reflectedIndex(uBase - 1 + i, length: size)
            for j in 0..<4 {
                let vj = SpectralUpsampling.reflectedIndex(vBase - 1 + j, length: size)
                let weight = weightsU[i] * weightsV[j]
                weightSum += weight
                for channel in 0..<3 {
                    out[channel] += weight * Double(plan.tcLUT[(ui * size + vj) * 3 + channel])
                }
            }
        }
        if weightSum != 0 {
            for channel in 0..<3 {
                out[channel] /= weightSum
            }
        }
        return out
    }

    // MARK: - The highlight boost

    /// The highlight boost of the negative.
    ///
    /// This is the boost of the upstream engine
    /// (`spektrafilm.utils.numba_boost_hightlights.boost_highlights`): the
    /// response is normalised by the maximum of the image, the boost curve is
    /// applied in the normalised space and the result is scaled back.
    public static func boostHighlights(raw: [Double], plan: FilmRenderPlan) -> [Double] {
        guard plan.boostEV != 0 else { return raw }
        var maxRaw = -Double.infinity
        for value in raw where !value.isNaN {
            maxRaw = Swift.max(maxRaw, value)
        }
        guard maxRaw != 0, !maxRaw.isInfinite else { return raw }
        let rawX0 = Swift.min(Swift.max(0.184 * pow(2.0, Double(plan.protectEV)), 0.0), maxRaw)
        guard rawX0 != maxRaw else { return raw }

        let a = pow(28.0, 1.0 - Double(plan.boostRange))
        let x0 = rawX0 / maxRaw
        let denominator = exp(a * (1.0 - x0)) - a * (1.0 - x0) - 1.0
        guard denominator > 0 else { return raw }
        let k = (pow(2.0, Double(plan.boostEV)) - 1.0) / denominator
        let inverseMaxRaw = 1.0 / maxRaw
        let boostScale = k * maxRaw

        var output = [Double](repeating: 0, count: raw.count)
        for index in 0..<raw.count {
            let value = raw[index]
            if value <= rawX0 {
                output[index] = value
            } else {
                let dx = (value - rawX0) * inverseMaxRaw
                output[index] = value + boostScale * (exp(a * dx) - a * dx - 1.0)
            }
        }
        return output
    }

    // MARK: - The output gamut compression

    /// The CAM16-UCS chroma reduction of the output values.
    ///
    /// This is the compression of the upstream engine
    /// (`spektrafilm.utils.gamut_compression.compress_rgb_cam16ucs_chroma`),
    /// evaluated from the precomputed table of the plan.
    public static func compressGamut(
        _ rgb: [Double], gamut: PlanGamutCompression
    ) -> [Double] {
        let pixels = rgb.count / 3
        var result = [Double](repeating: 0, count: pixels * 3)
        let whiteXYZ = gamut.whiteXYZ.map { Double($0) }
        for pixel in 0..<pixels {
            let values = Array(rgb[pixel * 3..<(pixel * 3 + 3)])
            // The sRGB values are already linear: the upstream applies the
            // CAT02 adaptation of the whitepoint of the colourspace onto
            // itself, which is the identity.
            let xyz = ColourScience.rgbToXYZ(
                rgb: values,
                colourspace: .sRGB,
                illuminant: RGBColourspace.sRGB.whitepoint,
                transform: .cat02,
                applyCCTFDecoding: false
            )
            var jab = CAM16.xyzToCAM16UCS(
                xyz: xyz,
                xyzWhite: whiteXYZ,
                LA: Double(gamut.la),
                Yb: Double(gamut.yb)
            )
            if let lightness = gamut.lightnessKnee {
                jab[0] = GamutCompression.compressLightness(
                    jab[0],
                    knee: lightness,
                    white: Double(gamut.whiteJp)
                )
            }
            let chroma = (jab[1] * jab[1] + jab[2] * jab[2]).squareRoot()
            let hue = atan2(jab[2], jab[1])
            let maximum = cMaxLookup(gamut: gamut, lightness: jab[0], hue: hue)
            let safeMaximum = Swift.max(maximum, 1e-9)
            let normalised = chroma / safeMaximum
            let compressed = GamutCompression.reinhardKnee(normalised, knee: gamut.knee)
            let newChroma = compressed * safeMaximum
            let newJab = [
                jab[0],
                newChroma * cos(hue),
                newChroma * sin(hue),
            ]
            let newXYZ = CAM16.cam16UCStoXYZ(
                jab: newJab,
                xyzWhite: whiteXYZ,
                LA: Double(gamut.la),
                Yb: Double(gamut.yb)
            )
            let newRGB = ColourScience.xyzToRGB(
                xyz: newXYZ,
                colourspace: .sRGB,
                illuminant: RGBColourspace.sRGB.whitepoint,
                transform: .cat02
            )
            for channel in 0..<3 {
                result[pixel * 3 + channel] = newRGB[channel]
            }
        }
        return result
    }

    /// The maximum in-gamut chroma at a given lightness and hue.
    ///
    /// This is the `_c_max_lookup` of the upstream engine, evaluated from the
    /// table of the plan.
    private static func cMaxLookup(
        gamut: PlanGamutCompression, lightness: Double, hue: Double
    ) -> Double {
        let count = gamut.cMaxHueCount
        guard count > 0, gamut.cMaxLightnessCount > 1 else { return 0 }
        let lightnessStart = Double(gamut.cMaxLightnessStart)
        let lightnessEnd = lightnessStart
            + Double(gamut.cMaxLightnessStep) * Double(gamut.cMaxLightnessCount - 1)
        let clampedLightness = Swift.min(Swift.max(lightness, lightnessStart), lightnessEnd)
        let hueStart = Double(gamut.cMaxHueStart)
        let hueStep = Double(gamut.cMaxHueStep)
        let hueIndex = (hue - hueStart) / hueStep
        let hueFloor = hueIndex.rounded(.down)
        let hueLow = positiveModulo(Int(hueFloor), count)
        let hueHigh = (hueLow + 1) % count
        let hueFraction = hueIndex - hueFloor

        let lightnessIndex = (clampedLightness - lightnessStart)
            / (lightnessEnd - lightnessStart)
            * Double(gamut.cMaxLightnessCount - 1)
        let lightnessFloor = lightnessIndex.rounded(.down)
        let lightnessLow = Swift.min(
            Swift.max(Int(lightnessFloor), 0), gamut.cMaxLightnessCount - 2
        )
        let lightnessHigh = lightnessLow + 1
        let lightnessFraction = lightnessIndex - Double(lightnessLow)

        let values = gamut.cMax
        let v00 = Double(values[lightnessLow * count + hueLow])
        let v01 = Double(values[lightnessLow * count + hueHigh])
        let v10 = Double(values[lightnessHigh * count + hueLow])
        let v11 = Double(values[lightnessHigh * count + hueHigh])
        return v00 * (1 - lightnessFraction) * (1 - hueFraction)
            + v01 * (1 - lightnessFraction) * hueFraction
            + v10 * lightnessFraction * (1 - hueFraction)
            + v11 * lightnessFraction * hueFraction
    }

    /// The positive modulo of an integer.
    private static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let result = value % modulus
        return result < 0 ? result + modulus : result
    }
}
