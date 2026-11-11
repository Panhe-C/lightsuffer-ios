//
//  FilmPlanEvaluatorFloat32.swift
//  light suffer胶片 — iOS app
//
//  The Float32 evaluation of the render plan: the **executable
//  specification of the Metal kernels**.
//
//  The evaluator computes the very same chain as the CPU reference
//  (``FilmPlanEvaluator``) and the very same chain as the Metal kernels of
//  `Sources/FilmPhysicsMetal/Shaders/FilmShaders.metal`, but in `Float32`
//  and in the very same order of operations: it is the arithmetic the GPU
//  does.
//
//  It is the reference the Metal kernels are validated against on the
//  machines that have a GPU, and the reference the tolerances of the GPU
//  path are derived from on Linux.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The `Float32` evaluation of a ``FilmRenderPlan``.
///
/// The chain is the one of the Metal kernels:
///
/// ```
/// rgb_in ──▶ raw ──▶ log_e_film ──▶ cmy_film ──▶ log_e_print ──▶ cmy_print ──▶ rgb_out
/// ```
///
/// The spatial effects (the halation, the diffusion filters, the lens
/// blurs, the unsharp mask and the spatial diffusion of the DIR couplers)
/// are **not** part of the evaluator: they are separate passes of the GPU
/// pipeline, and they are not part of the per pixel chain either.
public enum FilmPlanEvaluatorFloat32 {

    /// Evaluates the plan on an image, in `Float32`.
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
        let width = rgbIn.width
        let height = rgbIn.height
        let pixels = width * height

        // --- the spectral upsampling (the kernel `filmSpectralUpsample`) --
        var raw = [Float](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            let r = decode(Float(rgbIn.data[pixel * 3]), cctf: plan.inputCCTF)
            let g = decode(Float(rgbIn.data[pixel * 3 + 1]), cctf: plan.inputCCTF)
            let b = decode(Float(rgbIn.data[pixel * 3 + 2]), cctf: plan.inputCCTF)
            let matrix = plan.inputRGBToXYZ
            let x = matrix[0] * r + matrix[1] * g + matrix[2] * b
            let y = matrix[3] * r + matrix[4] * g + matrix[5] * b
            let z = matrix[6] * r + matrix[7] * g + matrix[8] * b
            var luminance = x + y + z
            if luminance.isNaN { luminance = 0 }
            let denominator = Swift.max(luminance, 1e-10)
            let chromaticityX = x / denominator
            let chromaticityY = y / denominator
            let u = Swift.min(Swift.max((1.0 - chromaticityX) * (1.0 - chromaticityX), 0), 1)
            let v = Swift.min(
                Swift.max(chromaticityY / Swift.max(1.0 - chromaticityX, 1e-10), 0), 1
            )
            let response = tcLookup(
                lut: plan.tcLUT, size: plan.tcLUTSize, u: u, v: v
            )
            raw[pixel * 3] = response.0 * luminance * plan.exposureScale
            raw[pixel * 3 + 1] = response.1 * luminance * plan.exposureScale
            raw[pixel * 3 + 2] = response.2 * luminance * plan.exposureScale
        }

        // --- the highlight boost (the kernel `filmBoostHighlights`) ------
        if plan.boostActive {
            raw = boostHighlights(raw: raw, plan: plan)
        }

        // --- the log exposure of the negative (`filmLinearToLog`) ---------
        var logEFilm = [Float](repeating: 0, count: pixels * 3)
        for index in 0..<logEFilm.count {
            let value = raw[index] * plan.filmingScale
            logEFilm[index] = log10(Swift.max(value, 0) + 1e-10)
        }

        // --- the development of the negative (`filmFilmDensity`) ----------
        var cmyFilm = [Float](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            for channel in 0..<3 {
                cmyFilm[pixel * 3 + channel] = sampleCurve(
                    curve: plan.filmCurve.values,
                    count: plan.filmCurve.count,
                    start: plan.filmCurve.start,
                    step: plan.filmCurve.step,
                    x: logEFilm[pixel * 3 + channel],
                    channel: channel
                )
            }
        }

        // --- the correction of the DIR couplers ---------------------------
        if plan.couplersActive {
            var correction = [Float](repeating: 0, count: pixels * 3)
            for pixel in 0..<pixels {
                var silver = [Float](repeating: 0, count: 3)
                for channel in 0..<3 {
                    let density = cmyFilm[pixel * 3 + channel]
                    silver[channel] = plan.couplerPositive
                        ? plan.densityMax[channel] - density
                        : density
                }
                for receiver in 0..<3 {
                    var amount: Float = 0
                    for donor in 0..<3 {
                        amount += silver[donor] * plan.couplerMatrix[donor * 3 + receiver]
                    }
                    correction[pixel * 3 + receiver] = amount
                }
            }
            for pixel in 0..<pixels {
                for channel in 0..<3 {
                    let exposure = logEFilm[pixel * 3 + channel] - correction[pixel * 3 + channel]
                    cmyFilm[pixel * 3 + channel] = sampleCurve(
                        curve: plan.filmCurveBeforeCouplers.values,
                        count: plan.filmCurveBeforeCouplers.count,
                        start: plan.filmCurveBeforeCouplers.start,
                        step: plan.filmCurveBeforeCouplers.step,
                        x: exposure,
                        channel: channel
                    )
                }
            }
        }

        // --- the printing stage (`filmPrintingExposure`) -------------------
        // The direct scan path (`io.scan_film`) skips the printing stage
        // entirely: the negative is scanned as it is.
        let wavelengths = plan.filmBaseDensity.count
        var logEPrint = [Float](repeating: 0, count: plan.scanFilm ? 0 : pixels * 3)
        var cmyPrint = [Float](repeating: 0, count: plan.scanFilm ? 0 : pixels * 3)
        if !plan.scanFilm {
            for pixel in 0..<pixels {
                let cr = cmyFilm[pixel * 3]
                let cg = cmyFilm[pixel * 3 + 1]
                let cb = cmyFilm[pixel * 3 + 2]
                var totals = [Float](repeating: 0, count: 3)
                for wavelength in 0..<wavelengths {
                    var density = plan.filmBaseDensity[wavelength]
                    density += cr * plan.filmChannelDensity[wavelength * 3]
                    density += cg * plan.filmChannelDensity[wavelength * 3 + 1]
                    density += cb * plan.filmChannelDensity[wavelength * 3 + 2]
                    var value = pow(10.0, -density) * plan.printIlluminant[wavelength]
                    if value.isNaN { value = 0 }
                    for channel in 0..<3 {
                        totals[channel] += value * plan.printSensitivity[wavelength * 3 + channel]
                    }
                }
                for channel in 0..<3 {
                    let rawPrint = totals[channel] * plan.exposureFactor + plan.preflash[channel]
                    let linear = Swift.max(rawPrint, 0) + 1e-10
                    let scaled = linear * plan.printExposure * plan.printingExposureCorrection
                    logEPrint[pixel * 3 + channel] = log10(Swift.max(scaled, 0) + 1e-10)
                }
            }

            // --- the development of the paper (`filmPrintDensity`) ------------
            for pixel in 0..<pixels {
                for channel in 0..<3 {
                    cmyPrint[pixel * 3 + channel] = sampleCurve(
                        curve: plan.printCurve.values,
                        count: plan.printCurve.count,
                        start: plan.printCurve.start,
                        step: plan.printCurve.step,
                        x: logEPrint[pixel * 3 + channel],
                        channel: channel
                    )
                }
            }
        }

        // --- the scanning stage (`filmScanXYZ`) ---------------------------
        // The densities that are scanned: the densities of the paper of the
        // print and scan path, the densities of the negative itself of the
        // direct scan path.
        let scanned = plan.scanFilm ? cmyFilm : cmyPrint
        var xyz = [Float](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            let cr = scanned[pixel * 3]
            let cg = scanned[pixel * 3 + 1]
            let cb = scanned[pixel * 3 + 2]
            var totals = [Float](repeating: 0, count: 3)
            for wavelength in 0..<wavelengths {
                var density = plan.scanBaseDensity[wavelength]
                density += cr * plan.scanChannelDensity[wavelength * 3]
                density += cg * plan.scanChannelDensity[wavelength * 3 + 1]
                density += cb * plan.scanChannelDensity[wavelength * 3 + 2]
                var value = pow(10.0, -density) * plan.scanIlluminant[wavelength]
                if value.isNaN { value = 0 }
                for component in 0..<3 {
                    totals[component] += value
                        * plan.colourMatchingFunctions[wavelength * 3 + component]
                }
            }
            for component in 0..<3 {
                xyz[pixel * 3 + component] = totals[component] / plan.scanNormalization
            }
        }
        for index in 0..<xyz.count {
            xyz[index] = Swift.max(xyz[index], 0) + 1e-10
        }
        // The black / white correction of the scanned tristimulus values.
        if plan.colorReferenceSlope != 1 || plan.colorReferenceOffset != 0 {
            for pixel in 0..<pixels {
                let y = xyz[pixel * 3 + 1]
                let corrected = Swift.min(
                    Swift.max(plan.colorReferenceSlope * y + plan.colorReferenceOffset, 0), 1
                )
                let scale = corrected / (y + 1e-10)
                for channel in 0..<3 {
                    xyz[pixel * 3 + channel] *= scale
                }
            }
        }

        // --- the conversion into RGB (`filmXYZToRGB`) ---------------------
        var rgb = [Float](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            let x = xyz[pixel * 3]
            let y = xyz[pixel * 3 + 1]
            let z = xyz[pixel * 3 + 2]
            let matrix = plan.xyzToRGB
            rgb[pixel * 3] = x * matrix[0] + y * matrix[3] + z * matrix[6]
            rgb[pixel * 3 + 1] = x * matrix[1] + y * matrix[4] + z * matrix[7]
            rgb[pixel * 3 + 2] = x * matrix[2] + y * matrix[5] + z * matrix[8]
        }

        // --- the output gamut compression (`filmGamutCompress`) ------------
        if let gamut = plan.gamutCompression {
            rgb = compressGamut(
                rgb,
                gamut: gamut,
                toXYZ: plan.gamutRGBToXYZ,
                fromXYZ: plan.gamutXYZToRGB
            )
        }

        // --- the output transfer function (`filmEncodeOutput`) -------------
        for pixel in 0..<pixels {
            let r = rgb[pixel * 3]
            let g = rgb[pixel * 3 + 1]
            let b = rgb[pixel * 3 + 2]
            let matrix = plan.srgbToSRGB
            let value0 = matrix[0] * r + matrix[1] * g + matrix[2] * b
            let value1 = matrix[3] * r + matrix[4] * g + matrix[5] * b
            let value2 = matrix[6] * r + matrix[7] * g + matrix[8] * b
            rgb[pixel * 3] = plan.outputEncoded ? sRGBEncode(value0) : value0
            rgb[pixel * 3 + 1] = plan.outputEncoded ? sRGBEncode(value1) : value1
            rgb[pixel * 3 + 2] = plan.outputEncoded ? sRGBEncode(value2) : value2
        }

        return FilmPlanTaps(
            logEFilm: RGBImage(
                width: width, height: height, data: logEFilm.map { Double($0) }
            ),
            cmyFilm: RGBImage(
                width: width, height: height, data: cmyFilm.map { Double($0) }
            ),
            logEPrint: RGBImage(
                width: plan.scanFilm ? 0 : width,
                height: plan.scanFilm ? 0 : height,
                data: logEPrint.map { Double($0) }
            ),
            cmyPrint: RGBImage(
                width: plan.scanFilm ? 0 : width,
                height: plan.scanFilm ? 0 : height,
                data: cmyPrint.map { Double($0) }
            ),
            rgbOut: RGBImage(
                width: width, height: height, data: rgb.map { Double($0) }
            )
        )
    }

    // MARK: - The helpers

    /// The decoding of an input value (0: none, 1: sRGB, 2: ProPhoto RGB).
    public static func decode(_ value: Float, cctf: Int) -> Float {
        switch cctf {
        case 1:
            if value <= 0.04045 {
                return value / 12.92
            }
            return pow((value + 0.055) / 1.055, 2.4)
        case 2:
            let threshold = Float(16.0 * pow(16.0, 1.8 / (1.0 - 1.8)))
            if value < threshold {
                return value / 16.0
            }
            let magnitude = pow(abs(value), 1.8)
            return value < 0 ? -magnitude : magnitude
        default:
            return value
        }
    }

    /// The sRGB encoding of a linear value.
    public static func sRGBEncode(_ value: Float) -> Float {
        if value <= 0.0031308 {
            return 12.92 * value
        }
        return 1.055 * pow(value, 1.0 / 2.4) - 0.055
    }

    /// The Mitchell-Netravali cubic kernel weight (B = C = 1/3).
    public static func mitchellWeight(_ t: Float) -> Float {
        let x = abs(t)
        let b: Float = 1.0 / 3.0
        let c: Float = 1.0 / 3.0
        if x < 1.0 {
            return (1.0 / 6.0) * (
                (12.0 - 9.0 * b - 6.0 * c) * x * x * x
                    + (-18.0 + 12.0 * b + 6.0 * c) * x * x
                    + (6.0 - 2.0 * b)
            )
        }
        if x < 2.0 {
            return (1.0 / 6.0) * (
                (-b - 6.0 * c) * x * x * x
                    + (6.0 * b + 30.0 * c) * x * x
                    + (-12.0 * b - 48.0 * c) * x
                    + (8.0 * b + 24.0 * c)
            )
        }
        return 0
    }

    /// The reflected index of the cubic interpolation (the upstream
    /// `safe_index`).
    public static func safeIndex(_ index: Int, length: Int) -> Int {
        if index < 0 { return -index }
        if index >= length { return 2 * (length - 1) - index }
        return index
    }

    /// The cubic lookup of the hanatos 2025 table.
    public static func tcLookup(
        lut: [Float], size: Int, u: Float, v: Float
    ) -> (Float, Float, Float) {
        guard size > 1 else { return (0, 0, 0) }
        let maxIndex = Float(size - 1)
        let cu = Swift.min(Swift.max(u, 0), 1) * maxIndex
        let cv = Swift.min(Swift.max(v, 0), 1) * maxIndex

        var uBase = 0
        var uFraction: Float = 0
        if cu >= maxIndex {
            uBase = size - 2
            uFraction = 1.0
        } else {
            uBase = Int(cu.rounded(.down))
            uFraction = cu - Float(uBase)
        }
        var vBase = 0
        var vFraction: Float = 0
        if cv >= maxIndex {
            vBase = size - 2
            vFraction = 1.0
        } else {
            vBase = Int(cv.rounded(.down))
            vFraction = cv - Float(vBase)
        }

        var weightsU = [Float](repeating: 0, count: 4)
        var weightsV = [Float](repeating: 0, count: 4)
        weightsU[0] = mitchellWeight(uFraction + 1.0)
        weightsU[1] = mitchellWeight(uFraction)
        weightsU[2] = mitchellWeight(uFraction - 1.0)
        weightsU[3] = mitchellWeight(uFraction - 2.0)
        weightsV[0] = mitchellWeight(vFraction + 1.0)
        weightsV[1] = mitchellWeight(vFraction)
        weightsV[2] = mitchellWeight(vFraction - 1.0)
        weightsV[3] = mitchellWeight(vFraction - 2.0)

        var r: Float = 0
        var g: Float = 0
        var b: Float = 0
        var weightSum: Float = 0
        for i in 0..<4 {
            let ui = safeIndex(uBase - 1 + i, length: size)
            for j in 0..<4 {
                let vj = safeIndex(vBase - 1 + j, length: size)
                let weight = weightsU[i] * weightsV[j]
                weightSum += weight
                let index = (ui * size + vj) * 3
                r += weight * lut[index]
                g += weight * lut[index + 1]
                b += weight * lut[index + 2]
            }
        }
        if weightSum != 0 {
            r /= weightSum
            g /= weightSum
            b /= weightSum
        }
        return (r, g, b)
    }

    /// The evaluation of a characteristic curve on its uniform log exposure
    /// grid.
    public static func sampleCurve(
        curve: [Float],
        count: Int,
        start: Float,
        step: Float,
        x: Float,
        channel: Int
    ) -> Float {
        guard count > 0 else { return 0 }
        if x.isNaN { return curve[channel * count] }
        if x <= start { return curve[channel * count] }
        let last = start + step * Float(count - 1)
        if x >= last { return curve[channel * count + count - 1] }
        let position = (x - start) / step
        var index = Int(position.rounded(.down))
        if index < 0 { index = 0 }
        if index > count - 2 { index = count - 2 }
        let fraction = position - Float(index)
        let low = curve[channel * count + index]
        let high = curve[channel * count + index + 1]
        return low + fraction * (high - low)
    }

    /// The highlight boost of the negative.
    ///
    /// The maximum of the field is computed first (the reduction
    /// `filmReduceMaxPartial` / `filmReduceMaxFinal` of the GPU).
    public static func boostHighlights(
        raw: [Float], plan: FilmRenderPlan
    ) -> [Float] {
        guard plan.boostEV != 0 else { return raw }
        var maxRaw = -Float.infinity
        for value in raw where !value.isNaN {
            maxRaw = Swift.max(maxRaw, value)
        }
        guard maxRaw != 0, maxRaw.isFinite else { return raw }
        let rawX0 = Swift.min(
            Swift.max(0.184 * pow(2.0, plan.protectEV), 0), maxRaw
        )
        guard rawX0 != maxRaw else { return raw }
        let a = pow(28.0, 1.0 - plan.boostRange)
        let x0 = rawX0 / maxRaw
        let denominator = exp(a * (1.0 - x0)) - a * (1.0 - x0) - 1.0
        guard denominator > 0 else { return raw }
        let k = (pow(2.0, plan.boostEV) - 1.0) / denominator
        let inverseMaxRaw = 1.0 / maxRaw
        let boostScale = k * maxRaw

        var output = [Float](repeating: 0, count: raw.count)
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

    // MARK: - The CAM16 colour appearance model

    /// The signed power `spow(x, p) = sign(x) · |x| ** p`.
    public static func spow(_ x: Float, _ p: Float) -> Float {
        let magnitude = pow(abs(x), p)
        return x < 0 ? -magnitude : magnitude
    }

    /// The luminance level adaptation factor `F_L`.
    public static func luminanceLevelAdaptationFactor(_ LA: Float) -> Float {
        let k = 1.0 / (5.0 * LA + 1.0)
        let k4 = pow(k, 4.0)
        return 0.2 * k4 * (5.0 * LA)
            + 0.1 * pow(1.0 - k4, 2.0) * spow(5.0 * LA, 1.0 / 3.0)
    }

    /// The forward post-adaptation non-linear response compression.
    public static func responseCompressionForward(_ rgb: (Float, Float, Float), _ FL: Float)
        -> (Float, Float, Float)
    {
        let cx = spow(FL * abs(rgb.0) / 100.0, 0.42)
        let cy = spow(FL * abs(rgb.1) / 100.0, 0.42)
        let cz = spow(FL * abs(rgb.2) / 100.0, 0.42)
        let rx = (400.0 * (rgb.0 < 0 ? -1.0 : 1.0) * cx) / (27.13 + cx) + 0.1
        let ry = (400.0 * (rgb.1 < 0 ? -1.0 : 1.0) * cy) / (27.13 + cy) + 0.1
        let rz = (400.0 * (rgb.2 < 0 ? -1.0 : 1.0) * cz) / (27.13 + cz) + 0.1
        return (rx, ry, rz)
    }

    /// The inverse post-adaptation non-linear response compression.
    public static func responseCompressionInverse(_ rgb: (Float, Float, Float), _ FL: Float)
        -> (Float, Float, Float)
    {
        let ax = abs(rgb.0 - 0.1)
        let ay = abs(rgb.1 - 0.1)
        let az = abs(rgb.2 - 0.1)
        let rx = (rgb.0 - 0.1 < 0 ? -1.0 : 1.0) * 100.0 / FL
            * spow((27.13 * ax) / (400.0 - ax), 1.0 / 0.42)
        let ry = (rgb.1 - 0.1 < 0 ? -1.0 : 1.0) * 100.0 / FL
            * spow((27.13 * ay) / (400.0 - ay), 1.0 / 0.42)
        let rz = (rgb.2 - 0.1 < 0 ? -1.0 : 1.0) * 100.0 / FL
            * spow((27.13 * az) / (400.0 - az), 1.0 / 0.42)
        return (rx, ry, rz)
    }

    /// The achromatic response.
    public static func achromaticResponse(
        _ rgb: (Float, Float, Float), _ Nbb: Float
    ) -> Float {
        (2.0 * rgb.0 + rgb.1 + (1.0 / 20.0) * rgb.2 - 0.305) * Nbb
    }

    /// The hue angle, in degrees.
    public static func hueAngle(_ a: Float, _ b: Float) -> Float {
        var angle = atan2(b, a) * (180.0 / Float.pi)
        angle = angle.truncatingRemainder(dividingBy: 360.0)
        if angle < 0 { angle += 360.0 }
        return angle
    }

    /// The eccentricity factor.
    public static func eccentricityFactor(_ h: Float) -> Float {
        0.25 * (cos(2.0 + h * Float.pi / 180.0) + 3.8)
    }

    /// The multiplication of the CAT16 cone response matrix with a vector.
    public static func cam16ConeResponse(_ xyz: (Float, Float, Float))
        -> (Float, Float, Float)
    {
        (
            0.401288 * xyz.0 + 0.650173 * xyz.1 - 0.051461 * xyz.2,
            -0.250268 * xyz.0 + 1.204414 * xyz.1 + 0.045854 * xyz.2,
            -0.002079 * xyz.0 + 0.048952 * xyz.1 + 0.953127 * xyz.2
        )
    }

    /// The multiplication of the inverse CAT16 cone response matrix with a
    /// vector.
    public static func cam16InverseConeResponse(_ rgb: (Float, Float, Float))
        -> (Float, Float, Float)
    {
        (
            1.86206786 * rgb.0 - 1.01125463 * rgb.1 + 0.14918678 * rgb.2,
            0.38752654 * rgb.0 + 0.62144744 * rgb.1 - 0.00897399 * rgb.2,
            -0.01584150 * rgb.0 - 0.03412294 * rgb.1 + 1.04996444 * rgb.2
        )
    }

    /// The CAM16 correlates of an XYZ triplet (the scale 100 domain).
    ///
    /// The returns are `J`, `C`, `M` (the colourfulness) and the hue angle
    /// `h` (in degrees).
    public static func cam16Forward(
        _ xyz: (Float, Float, Float),
        _ xyzWhite: (Float, Float, Float),
        _ LA: Float,
        _ Yb: Float
    ) -> (Float, Float, Float, Float) {
        let Yw = xyzWhite.1
        let rgbWhite = cam16ConeResponse(xyzWhite)
        let D = Swift.min(
            Swift.max(1.0 * (1.0 - (1.0 / 3.6) * exp((-LA - 42.0) / 92.0)), 0), 1
        )
        let n = Yb / Yw
        let FL = luminanceLevelAdaptationFactor(LA)
        let Nbb = 0.725 * pow(1.0 / n, 0.2)
        let Ncb = Nbb
        let z = 1.48 + sqrt(n)
        let dRGB = (
            D * Yw / rgbWhite.0 + 1.0 - D,
            D * Yw / rgbWhite.1 + 1.0 - D,
            D * Yw / rgbWhite.2 + 1.0 - D
        )
        let rgbWhiteCompressed = responseCompressionForward(
            (dRGB.0 * rgbWhite.0, dRGB.1 * rgbWhite.1, dRGB.2 * rgbWhite.2), FL
        )
        let aw = achromaticResponse(rgbWhiteCompressed, Nbb)
        let rgb = cam16ConeResponse(xyz)
        let rgbCompressed = responseCompressionForward(
            (dRGB.0 * rgb.0, dRGB.1 * rgb.1, dRGB.2 * rgb.2), FL
        )
        let a = rgbCompressed.0 - 12.0 * rgbCompressed.1 / 11.0 + rgbCompressed.2 / 11.0
        let b = (rgbCompressed.0 + rgbCompressed.1 - 2.0 * rgbCompressed.2) / 9.0
        let h = hueAngle(a, b)
        let et = eccentricityFactor(h)
        let A = achromaticResponse(rgbCompressed, Nbb)
        let J = 100.0 * spow(A / aw, 0.69 * z)
        let t = ((50000.0 / 13.0) * 1.0 * Ncb)
            * (et * sqrt(a * a + b * b)
                / (rgbCompressed.0 + rgbCompressed.1 + 21.0 * rgbCompressed.2 / 20.0))
        let C = spow(t, 0.9) * spow(J / 100.0, 0.5) * spow(1.64 - pow(0.29, n), 0.73)
        let M = C * spow(FL, 0.25)
        return (J, C, M, h)
    }

    /// The XYZ tristimulus values of a CAM16 specification (the scale 100
    /// domain).
    public static func cam16Inverse(
        _ J: Float,
        _ C: Float,
        _ h: Float,
        _ xyzWhite: (Float, Float, Float),
        _ LA: Float,
        _ Yb: Float
    ) -> (Float, Float, Float) {
        let Yw = xyzWhite.1
        let rgbWhite = cam16ConeResponse(xyzWhite)
        let D = Swift.min(
            Swift.max(1.0 * (1.0 - (1.0 / 3.6) * exp((-LA - 42.0) / 92.0)), 0), 1
        )
        let n = Yb / Yw
        let FL = luminanceLevelAdaptationFactor(LA)
        let Nbb = 0.725 * pow(1.0 / n, 0.2)
        let Ncb = Nbb
        let z = 1.48 + sqrt(n)
        let dRGB = (
            D * Yw / rgbWhite.0 + 1.0 - D,
            D * Yw / rgbWhite.1 + 1.0 - D,
            D * Yw / rgbWhite.2 + 1.0 - D
        )
        let rgbWhiteCompressed = responseCompressionForward(
            (dRGB.0 * rgbWhite.0, dRGB.1 * rgbWhite.1, dRGB.2 * rgbWhite.2), FL
        )
        let aw = achromaticResponse(rgbWhiteCompressed, Nbb)
        let JPrime: Float = Swift.max(J, 1e-6)
        let t: Float = spow(
            C / (sqrt(JPrime / 100.0) * spow(1.64 - pow(0.29, n), 0.73)), 1.0 / 0.9
        )
        let et: Float = eccentricityFactor(h)
        let A: Float = aw * spow(J / 100.0, 1.0 / (0.69 * z))
        let P1: Float = (50000.0 / 13.0) * 1.0 * Ncb * et / t
        let P2: Float = A / Nbb + 0.305
        let P3: Float = 21.0 / 20.0
        let hr = h * (Float.pi / 180.0)
        let sinHR = sin(hr)
        let cosHR = cos(hr)
        var a: Float = 0
        var b: Float = 0
        let twoP3: Float = 2.0 + P3
        let c460: Float = 460.0 / 1403.0
        let c220: Float = 220.0 / 1403.0
        let c27: Float = 27.0 / 1403.0
        let c6300: Float = 6300.0 / 1403.0
        let nValue: Float = P2 * twoP3 * c460
        if abs(sinHR) >= abs(cosHR) {
            let P4: Float = P1 / sinHR
            let ratio: Float = cosHR / sinHR
            let first: Float = P4 + twoP3 * c220 * ratio
            let second: Float = -c27 + P3 * c6300
            b = nValue / (first + second)
            a = b * ratio
        } else {
            let P5: Float = P1 / cosHR
            let ratio: Float = sinHR / cosHR
            let first: Float = P5 + twoP3 * c220
            let second: Float = (c27 - P3 * c6300) * ratio
            a = nValue / (first - second)
            b = a * ratio
        }
        if t == 0 {
            a = 0
            b = 0
        }
        let rgbA = (
            (460.0 * P2 + 451.0 * a + 288.0 * b) / 1403.0,
            (460.0 * P2 - 891.0 * a - 261.0 * b) / 1403.0,
            (460.0 * P2 - 220.0 * a - 6300.0 * b) / 1403.0
        )
        let rgbCompressed = responseCompressionInverse(rgbA, FL)
        let rgb = (
            rgbCompressed.0 / dRGB.0,
            rgbCompressed.1 / dRGB.1,
            rgbCompressed.2 / dRGB.2
        )
        return cam16InverseConeResponse(rgb)
    }

    /// The CAM16-UCS coordinates of an XYZ triplet (the scale 1 domain).
    public static func xyzToCAM16UCS(
        _ xyz: (Float, Float, Float),
        _ xyzWhite: (Float, Float, Float),
        _ LA: Float,
        _ Yb: Float
    ) -> (Float, Float, Float) {
        let specification = cam16Forward(
            (xyz.0 * 100.0, xyz.1 * 100.0, xyz.2 * 100.0),
            (xyzWhite.0 * 100.0, xyzWhite.1 * 100.0, xyzWhite.2 * 100.0),
            LA, Yb
        )
        let J = specification.0
        let M = specification.2
        let h = specification.3
        let c1: Float = 0.007
        let c2: Float = 0.0228
        let Jp = ((1.0 + 100.0 * c1) * J) / (1.0 + c1 * J)
        let Mp = (1.0 / c2) * log(1.0 + c2 * M)
        let hr = h * (Float.pi / 180.0)
        return (Jp, Mp * cos(hr), Mp * sin(hr))
    }

    /// The XYZ tristimulus values of a CAM16-UCS triplet (the scale 1
    /// domain).
    public static func cam16UCStoXYZ(
        _ jab: (Float, Float, Float),
        _ xyzWhite: (Float, Float, Float),
        _ LA: Float,
        _ Yb: Float
    ) -> (Float, Float, Float) {
        let c1: Float = 0.007
        let c2: Float = 0.0228
        let Jp = jab.0
        let Mp = sqrt(jab.1 * jab.1 + jab.2 * jab.2)
        let J = -Jp / (c1 * Jp - 1.0 - 100.0 * c1)
        let M = (exp(Mp * c2) - 1.0) / c2
        let h = atan2(jab.2, jab.1) * (180.0 / Float.pi)
        let FL = luminanceLevelAdaptationFactor(LA)
        let C = M / spow(FL, 0.25)
        let hue = h < 0 ? h + 360.0 : h
        let xyz = cam16Inverse(
            J, C, hue,
            (xyzWhite.0 * 100.0, xyzWhite.1 * 100.0, xyzWhite.2 * 100.0),
            LA, Yb
        )
        return (xyz.0 / 100.0, xyz.1 / 100.0, xyz.2 / 100.0)
    }

    // MARK: - The output gamut compression

    /// The CAM16-UCS chroma reduction of the output values.
    ///
    /// - Parameters:
    ///   - rgb: the linear RGB values, three interleaved values per pixel.
    ///   - gamut: the precomputed data of the compression.
    ///   - toXYZ: the linear sRGB to XYZ matrix, nine values, row major.
    ///   - fromXYZ: the XYZ to linear sRGB matrix, nine values, row major.
    /// - Returns: the compressed values.
    public static func compressGamut(
        _ rgb: [Float],
        gamut: PlanGamutCompression,
        toXYZ: [Float],
        fromXYZ: [Float]
    ) -> [Float] {
        let pixels = rgb.count / 3
        var result = [Float](repeating: 0, count: pixels * 3)
        let whiteXYZ = (
            gamut.whiteXYZ.count > 0 ? gamut.whiteXYZ[0] : 0,
            gamut.whiteXYZ.count > 1 ? gamut.whiteXYZ[1] : 0,
            gamut.whiteXYZ.count > 2 ? gamut.whiteXYZ[2] : 0
        )
        let toXYZ = toXYZ
        let fromXYZ = fromXYZ
        for pixel in 0..<pixels {
            let r = rgb[pixel * 3]
            let g = rgb[pixel * 3 + 1]
            let b = rgb[pixel * 3 + 2]
            let xyz = (
                toXYZ[0] * r + toXYZ[1] * g + toXYZ[2] * b,
                toXYZ[3] * r + toXYZ[4] * g + toXYZ[5] * b,
                toXYZ[6] * r + toXYZ[7] * g + toXYZ[8] * b
            )
            var jab = xyzToCAM16UCS(xyz, whiteXYZ, gamut.la, gamut.yb)
            if let lightness = gamut.lightnessKnee {
                let normalised = jab.0 / gamut.whiteJp
                jab.0 = reinhardKnee(
                    normalised,
                    threshold: Float(lightness.threshold),
                    limit: Float(lightness.limit),
                    power: Float(lightness.power)
                ) * gamut.whiteJp
            }
            let chroma = sqrt(jab.1 * jab.1 + jab.2 * jab.2)
            let hue = atan2(jab.2, jab.1)
            let maximum = cMaxLookup(
                gamut: gamut, lightness: jab.0, hue: hue
            )
            let safeMaximum = Swift.max(maximum, 1e-9)
            let normalised = chroma / safeMaximum
            let compressed = reinhardKnee(
                normalised,
                threshold: Float(gamut.knee.threshold),
                limit: Float(gamut.knee.limit),
                power: Float(gamut.knee.power)
            )
            let newChroma = compressed * safeMaximum
            let newJab = (
                jab.0,
                newChroma * cos(hue),
                newChroma * sin(hue)
            )
            let newXYZ = cam16UCStoXYZ(newJab, whiteXYZ, gamut.la, gamut.yb)
            result[pixel * 3] = fromXYZ[0] * newXYZ.0 + fromXYZ[1] * newXYZ.1
                + fromXYZ[2] * newXYZ.2
            result[pixel * 3 + 1] = fromXYZ[3] * newXYZ.0 + fromXYZ[4] * newXYZ.1
                + fromXYZ[5] * newXYZ.2
            result[pixel * 3 + 2] = fromXYZ[6] * newXYZ.0 + fromXYZ[7] * newXYZ.1
                + fromXYZ[8] * newXYZ.2
        }
        return result
    }

    /// The Reinhard knee of the gamut compression.
    public static func reinhardKnee(
        _ d: Float, threshold: Float, limit: Float, power: Float
    ) -> Float {
        if d <= threshold { return d }
        let scale = limit - threshold
        let x = (d - threshold) / scale
        let y = x / pow(1.0 + pow(x, power), 1.0 / power)
        return threshold + scale * y
    }

    /// The maximum in-gamut chroma at a given lightness and hue.
    public static func cMaxLookup(
        gamut: PlanGamutCompression, lightness: Float, hue: Float
    ) -> Float {
        let count = gamut.cMaxHueCount
        guard count > 0, gamut.cMaxLightnessCount > 1 else { return 0 }
        let lightnessStart = gamut.cMaxLightnessStart
        let lightnessEnd = lightnessStart
            + gamut.cMaxLightnessStep * Float(gamut.cMaxLightnessCount - 1)
        let clampedLightness = Swift.min(Swift.max(lightness, lightnessStart), lightnessEnd)
        let hueStart = gamut.cMaxHueStart
        let hueStep = gamut.cMaxHueStep
        let hueIndex = (hue - hueStart) / hueStep
        let hueFloor = hueIndex.rounded(.down)
        var hueLow = Int(hueFloor) % count
        if hueLow < 0 { hueLow += count }
        let hueHigh = (hueLow + 1) % count
        let hueFraction = hueIndex - hueFloor
        let lightnessIndex = (clampedLightness - lightnessStart)
            / (lightnessEnd - lightnessStart)
            * Float(gamut.cMaxLightnessCount - 1)
        let lightnessFloor = lightnessIndex.rounded(.down)
        let lightnessLow = Swift.min(
            Swift.max(Int(lightnessFloor), 0), gamut.cMaxLightnessCount - 2
        )
        let lightnessHigh = lightnessLow + 1
        let lightnessFraction = lightnessIndex - Float(lightnessLow)
        let values = gamut.cMax
        let v00 = values[lightnessLow * count + hueLow]
        let v01 = values[lightnessLow * count + hueHigh]
        let v10 = values[lightnessHigh * count + hueLow]
        let v11 = values[lightnessHigh * count + hueHigh]
        return v00 * (1 - lightnessFraction) * (1 - hueFraction)
            + v01 * (1 - lightnessFraction) * hueFraction
            + v10 * lightnessFraction * (1 - hueFraction)
            + v11 * lightnessFraction * hueFraction
    }
}
