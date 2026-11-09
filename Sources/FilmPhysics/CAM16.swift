//
//  CAM16.swift
//  light suffer胶片 — iOS app
//
//  The CAM16 colour appearance model and the CAM16-UCS colourspace, the
//  space the output gamut compression of the upstream engine works in.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The viewing conditions of the CAM16 colour appearance model.
///
/// Upstream reference: `colour.appearance.VIEWING_CONDITIONS_CAM16`.
public struct CAM16ViewingConditions: Equatable, Sendable {
    /// The maximum degree of adaptation `F`.
    public var F: Double
    /// The exponential non-linearity `c`.
    public var c: Double
    /// The chromatic induction factor `N_c`.
    public var Nc: Double

    public init(F: Double = 1.0, c: Double = 0.69, Nc: Double = 1.0) {
        self.F = F
        self.c = c
        self.Nc = Nc
    }

    /// The *Average* surround.
    public static let average = CAM16ViewingConditions(F: 1.0, c: 0.69, Nc: 1.0)
}

/// The correlates of the CAM16 colour appearance model.
public struct CAM16Specification: Equatable, Sendable {
    public var J: Double
    public var C: Double
    public var h: Double
    public var s: Double
    public var Q: Double
    public var M: Double

    public init(J: Double, C: Double, h: Double, s: Double, Q: Double, M: Double) {
        self.J = J
        self.C = C
        self.h = h
        self.s = s
        self.Q = Q
        self.M = M
    }
}

/// The CAM16 colour appearance model and the CAM16-UCS colourspace.
///
/// Upstream reference: `colour.appearance.XYZ_to_CAM16`,
/// `colour.appearance.CAM16_to_XYZ`, `colour.models.XYZ_to_CAM16UCS` and
/// `colour.models.CAM16UCS_to_XYZ`.
///
/// The model is defined on the *scale 100* domain (the tristimulus values
/// are multiplied by 100), exactly like the upstream library does; the
/// `…UCS` entry points take and return scale 1 values.
public enum CAM16 {

    /// The CAT16 cone response matrix.
    public static let matrix16 = ChromaticAdaptationTransform.cat16.matrix

    /// The inverse of the CAT16 cone response matrix.
    public static let matrix16Inverse: [[Double]] =
        Matrix.inverse(ChromaticAdaptationTransform.cat16.matrix)
        ?? ChromaticAdaptationTransform.cat16.matrix

    /// The Luo et al. (2006) fitting coefficients of the CAM16-UCS colourspace.
    ///
    /// Upstream reference: `colour.models.COEFFICIENTS_UCS_LUO2006["CAM02-UCS"]`.
    public static let ucsCoefficients = (K_L: 1.00, c1: 0.007, c2: 0.0228)

    // MARK: - Helpers

    /// The signed power `spow(x, p) = sign(x) · |x| ** p`.
    private static func spow(_ x: Double, _ p: Double) -> Double {
        let magnitude = pow(abs(x), p)
        return x < 0 ? -magnitude : magnitude
    }

    /// The luminance level adaptation factor `F_L`.
    ///
    /// Upstream reference: `colour.appearance.hunt.luminance_level_adaptation_factor`.
    public static func luminanceLevelAdaptationFactor(_ LA: Double) -> Double {
        let k = 1.0 / (5.0 * LA + 1.0)
        let k4 = pow(k, 4.0)
        return 0.2 * k4 * (5.0 * LA) + 0.1 * pow(1.0 - k4, 2.0) * spow(5.0 * LA, 1.0 / 3.0)
    }

    /// The viewing condition dependent parameters.
    ///
    /// Upstream reference:
    /// `colour.appearance.ciecam02.viewing_conditions_dependent_parameters`.
    private static func viewingConditionParameters(
        Yb: Double, Yw: Double, LA: Double
    ) -> (n: Double, FL: Double, Nbb: Double, Ncb: Double, z: Double) {
        let n = Yb / Yw
        let FL = luminanceLevelAdaptationFactor(LA)
        let Nbb = 0.725 * pow(1.0 / n, 0.2)
        let Ncb = Nbb
        let z = 1.48 + n.squareRoot()
        return (n, FL, Nbb, Ncb, z)
    }

    /// The forward post-adaptation non-linear response compression.
    ///
    /// Upstream reference:
    /// `colour.appearance.ciecam02.post_adaptation_non_linear_response_compression_forward`.
    private static func responseCompressionForward(_ RGB: [Double], FL: Double) -> [Double] {
        RGB.map { value in
            let compressed = spow(FL * abs(value) / 100.0, 0.42)
            return (400.0 * (value < 0 ? -1.0 : 1.0) * compressed) / (27.13 + compressed) + 0.1
        }
    }

    /// The inverse post-adaptation non-linear response compression.
    ///
    /// Upstream reference:
    /// `colour.appearance.ciecam02.post_adaptation_non_linear_response_compression_inverse`.
    private static func responseCompressionInverse(_ RGB: [Double], FL: Double) -> [Double] {
        RGB.map { value in
            let sign = value - 0.1 < 0 ? -1.0 : 1.0
            return sign * 100.0 / FL * spow(
                (27.13 * abs(value - 0.1)) / (400.0 - abs(value - 0.1)),
                1.0 / 0.42
            )
        }
    }

    /// The achromatic response.
    ///
    /// Upstream reference: `colour.appearance.ciecam02.achromatic_response_forward`.
    private static func achromaticResponse(_ RGB: [Double], Nbb: Double) -> Double {
        (2.0 * RGB[0] + RGB[1] + (1.0 / 20.0) * RGB[2] - 0.305) * Nbb
    }

    /// The hue angle, in degrees.
    ///
    /// Upstream reference: `colour.appearance.ciecam02.hue_angle`.
    private static func hueAngle(a: Double, b: Double) -> Double {
        // `numpy.degrees` multiplies by the constant 180 / pi, the port does
        // the same so that the hue matches the upstream engine bit for bit.
        let angle = atan2(b, a) * (180.0 / .pi)
        var result = angle.truncatingRemainder(dividingBy: 360.0)
        if result < 0 { result += 360.0 }
        return result
    }

    /// The eccentricity factor.
    ///
    /// Upstream reference: `colour.appearance.ciecam02.eccentricity_factor`.
    private static func eccentricityFactor(_ h: Double) -> Double {
        0.25 * (cos(2.0 + h * .pi / 180.0) + 3.8)
    }

    /// The temporary magnitude quantity.
    ///
    /// Upstream reference:
    /// `colour.appearance.ciecam02.temporary_magnitude_quantity_forward`.
    private static func temporaryMagnitude(
        Nc: Double, Ncb: Double, et: Double, a: Double, b: Double, RGBa: [Double]
    ) -> Double {
        ((50000.0 / 13.0) * Nc * Ncb) * (
            et * (a * a + b * b).squareRoot() / (RGBa[0] + RGBa[1] + 21.0 * RGBa[2] / 20.0)
        )
    }

    // MARK: - The colour appearance model

    /// The CAM16 correlates of an XYZ triplet.
    ///
    /// Upstream reference: `colour.appearance.XYZ_to_CAM16`.
    ///
    /// The tristimulus values are on the *scale 100* domain.
    ///
    /// - Parameters:
    ///   - xyz: the XYZ tristimulus values (scale 100).
    ///   - xyzWhite: the XYZ tristimulus values of the reference white (scale 100).
    ///   - viewingConditions: the viewing conditions.
    ///   - LA: the adapting field luminance, in cd/m².
    ///   - Yb: the luminance factor of the background.
    public static func xyzToCAM16(
        xyz: [Double],
        xyzWhite: [Double],
        viewingConditions: CAM16ViewingConditions = .average,
        LA: Double,
        Yb: Double
    ) -> CAM16Specification {
        let Yw = xyzWhite[1]
        let rgbWhite = Matrix.multiply(matrix16, xyzWhite)

        // The degree of adaptation.
        let D = Swift.min(
            Swift.max(
                viewingConditions.F * (1.0 - (1.0 / 3.6) * exp((-LA - 42.0) / 92.0)),
                0.0
            ),
            1.0
        )

        let (n, FL, Nbb, Ncb, z) = viewingConditionParameters(Yb: Yb, Yw: Yw, LA: LA)
        let dRGB = (0..<3).map { D * Yw / rgbWhite[$0] + 1.0 - D }
        let rgbWhiteCompressed = responseCompressionForward(
            zip(dRGB, rgbWhite).map { $0 * $1 }, FL: FL
        )
        let aw = achromaticResponse(rgbWhiteCompressed, Nbb: Nbb)

        let rgb = Matrix.multiply(matrix16, xyz)
        let rgbCompressed = responseCompressionForward(
            zip(dRGB, rgb).map { $0 * $1 }, FL: FL
        )

        let a = rgbCompressed[0] - 12.0 * rgbCompressed[1] / 11.0 + rgbCompressed[2] / 11.0
        let b = (rgbCompressed[0] + rgbCompressed[1] - 2.0 * rgbCompressed[2]) / 9.0
        let h = hueAngle(a: a, b: b)
        let et = eccentricityFactor(h)
        let A = achromaticResponse(rgbCompressed, Nbb: Nbb)

        let J = 100.0 * spow(A / aw, viewingConditions.c * z)
        let Q = (4.0 / viewingConditions.c) * (J / 100.0).squareRoot() * (aw + 4.0)
            * spow(FL, 0.25)
        let t = temporaryMagnitude(
            Nc: viewingConditions.Nc, Ncb: Ncb, et: et, a: a, b: b, RGBa: rgbCompressed
        )
        let C = spow(t, 0.9) * spow(J / 100.0, 0.5) * spow(1.64 - pow(0.29, n), 0.73)
        let M = C * spow(FL, 0.25)
        let s = 100.0 * spow(M / Q, 0.5)

        return CAM16Specification(J: J, C: C, h: h, s: s, Q: Q, M: M)
    }

    /// The XYZ tristimulus values of a CAM16 specification.
    ///
    /// Upstream reference: `colour.appearance.CAM16_to_XYZ`.
    ///
    /// The tristimulus values are on the *scale 100* domain.
    public static func cam16ToXYZ(
        specification: CAM16Specification,
        xyzWhite: [Double],
        viewingConditions: CAM16ViewingConditions = .average,
        LA: Double,
        Yb: Double
    ) -> [Double] {
        let Yw = xyzWhite[1]
        let rgbWhite = Matrix.multiply(matrix16, xyzWhite)
        let D = Swift.min(
            Swift.max(
                viewingConditions.F * (1.0 - (1.0 / 3.6) * exp((-LA - 42.0) / 92.0)),
                0.0
            ),
            1.0
        )
        let (n, FL, Nbb, Ncb, z) = viewingConditionParameters(Yb: Yb, Yw: Yw, LA: LA)
        let dRGB = (0..<3).map { D * Yw / rgbWhite[$0] + 1.0 - D }
        let rgbWhiteCompressed = responseCompressionForward(
            zip(dRGB, rgbWhite).map { $0 * $1 }, FL: FL
        )
        let aw = achromaticResponse(rgbWhiteCompressed, Nbb: Nbb)

        let C = specification.C
        let J = specification.J
        let h = specification.h

        // The temporary magnitude quantity.
        let JPrime = Swift.max(J, 1e-6)
        let t = spow(
            C / ((JPrime / 100.0).squareRoot() * spow(1.64 - pow(0.29, n), 0.73)),
            1.0 / 0.9
        )
        let et = eccentricityFactor(h)
        let A = aw * spow(J / 100.0, 1.0 / (viewingConditions.c * z))

        // P₁ … P₃.
        let P1 = (50000.0 / 13.0) * viewingConditions.Nc * Ncb * et / t
        let P2 = A / Nbb + 0.305
        let P3 = 21.0 / 20.0

        // The opponent colour dimensions.
        let hr = h * (.pi / 180.0)
        let sinHR = sin(hr)
        let cosHR = cos(hr)
        var a = 0.0
        var b = 0.0
        if abs(sinHR) >= abs(cosHR) {
            let P4 = P1 / sinHR
            let nValue = P2 * (2.0 + P3) * (460.0 / 1403.0)
            b = nValue / (
                P4 + (2.0 + P3) * (220.0 / 1403.0) * (cosHR / sinHR)
                    - (27.0 / 1403.0) + P3 * (6300.0 / 1403.0)
            )
            a = b * (cosHR / sinHR)
        } else {
            let P5 = P1 / cosHR
            let nValue = P2 * (2.0 + P3) * (460.0 / 1403.0)
            a = nValue / (
                P5 + (2.0 + P3) * (220.0 / 1403.0)
                    - ((27.0 / 1403.0) - P3 * (6300.0 / 1403.0)) * (sinHR / cosHR)
            )
            b = a * (sinHR / cosHR)
        }
        if t == 0 {
            a = 0
            b = 0
        }

        // The post-adaptation non-linear response compression matrix.
        let rgbA = Matrix.multiply(
            [
                [460.0, 451.0, 288.0],
                [460.0, -891.0, -261.0],
                [460.0, -220.0, -6300.0],
            ],
            [P2, a, b]
        ).map { $0 / 1403.0 }

        let rgbCompressed = responseCompressionInverse(rgbA, FL: FL)
        let rgb = (0..<3).map { rgbCompressed[$0] / dRGB[$0] }
        return Matrix.multiply(matrix16Inverse, rgb)
    }

    // MARK: - The CAM16-UCS colourspace

    /// The CAM16-UCS coordinates of an XYZ triplet.
    ///
    /// Upstream reference: `colour.models.XYZ_to_CAM16UCS`.
    ///
    /// - Parameters:
    ///   - xyz: the XYZ tristimulus values (scale 1).
    ///   - xyzWhite: the XYZ tristimulus values of the reference white (scale 1).
    ///   - LA: the adapting field luminance, in cd/m².
    ///   - Yb: the luminance factor of the background.
    /// - Returns: the `(Jp, ap, bp)` coordinates.
    public static func xyzToCAM16UCS(
        xyz: [Double],
        xyzWhite: [Double],
        LA: Double,
        Yb: Double
    ) -> [Double] {
        let specification = xyzToCAM16(
            xyz: xyz.map { $0 * 100.0 },
            xyzWhite: xyzWhite.map { $0 * 100.0 },
            LA: LA,
            Yb: Yb
        )
        let Jp = ((1.0 + 100.0 * ucsCoefficients.c1) * specification.J)
            / (1.0 + ucsCoefficients.c1 * specification.J)
        let Mp = (1.0 / ucsCoefficients.c2) * log1p(ucsCoefficients.c2 * specification.M)
        let h = specification.h * .pi / 180.0
        return [Jp, Mp * cos(h), Mp * sin(h)]
    }

    /// The XYZ tristimulus values of a CAM16-UCS triplet.
    ///
    /// Upstream reference: `colour.models.CAM16UCS_to_XYZ`.
    ///
    /// - Parameters:
    ///   - jab: the `(Jp, ap, bp)` coordinates.
    ///   - xyzWhite: the XYZ tristimulus values of the reference white (scale 1).
    ///   - LA: the adapting field luminance, in cd/m².
    ///   - Yb: the luminance factor of the background.
    /// - Returns: the XYZ tristimulus values (scale 1).
    public static func cam16UCStoXYZ(
        jab: [Double],
        xyzWhite: [Double],
        LA: Double,
        Yb: Double
    ) -> [Double] {
        let Jp = jab[0]
        let Mp = (jab[1] * jab[1] + jab[2] * jab[2]).squareRoot()
        let J = -Jp / (ucsCoefficients.c1 * Jp - 1.0 - 100.0 * ucsCoefficients.c1)
        let M = expm1(Mp * ucsCoefficients.c2) / ucsCoefficients.c2
        let h = atan2(jab[2], jab[1]) * 180.0 / .pi
        // The chroma correlate is derived from the colourfulness when it is
        // not given (the upstream inverse does the same).
        let FL = luminanceLevelAdaptationFactor(LA)
        let C = M / spow(FL, 0.25)
        let specification = CAM16Specification(
            J: J, C: C, h: h < 0 ? h + 360 : h, s: 0, Q: 0, M: M
        )
        let xyz = cam16ToXYZ(
            specification: specification,
            xyzWhite: xyzWhite.map { $0 * 100.0 },
            LA: LA,
            Yb: Yb
        )
        return xyz.map { $0 / 100.0 }
    }
}
