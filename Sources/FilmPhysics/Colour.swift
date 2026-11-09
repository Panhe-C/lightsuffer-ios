//
//  Colour.swift
//  light suffer胶片 — iOS app
//
//  Colour utilities: the sRGB transfer function, the CIELAB conversion and
//  the CIEDE2000 colour difference.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// A colour in the CIELAB colourspace.
public struct LabColour: Equatable, Sendable {
    /// The lightness.
    public var l: Double
    /// The green / red axis (a).
    public var a: Double
    /// The blue / yellow axis (b).
    public var b: Double

    public init(l: Double, a: Double, b: Double) {
        self.l = l
        self.a = a
        self.b = b
    }
}

/// Colour space conversions and colour difference metrics.
public enum Colour {

    // MARK: - sRGB

    /// The linear sRGB to CIE XYZ (D65) matrix.
    ///
    /// The primaries and the white point of the sRGB colourspace as defined
    /// by IEC 61966-2-1, with the same rounding as the `colour-science`
    /// library the upstream engine uses.
    public static let sRGBToXYZMatrix: [[Double]] = [
        [0.4124, 0.3576, 0.1805],
        [0.2126, 0.7152, 0.0722],
        [0.0193, 0.1192, 0.9505],
    ]

    /// The CIE XYZ (D65) to linear sRGB matrix.
    public static let XYZToSRGBMatrix: [[Double]] = [
        [3.2406, -1.5372, -0.4986],
        [-0.9689, 1.8758, 0.0415],
        [0.0557, -0.204, 1.057],
    ]

    /// The D65 white point of the sRGB colourspace.
    public static let sRGBWhitePoint: [Double] = [0.9504559270516716, 1.0, 1.0890577507598784]

    /// The sRGB electro-optical transfer function (the decoding of an encoded
    /// sRGB value into a linear one).
    ///
    /// Upstream reference: `colour.models.eotf_sRGB`, which the upstream
    /// pipeline uses through `colour.RGB_to_RGB`.
    ///
    /// ```
    /// linear = value / 12.92          for value <= 0.04045
    /// linear = ((value + 0.055) / 1.055) ** 2.4   otherwise
    /// ```
    public static func sRGBDecode(_ value: Double) -> Double {
        if value <= 0.04045 {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    /// The inverse electro-optical transfer function of sRGB (the encoding of
    /// a linear sRGB value).
    ///
    /// Upstream reference: `colour.models.eotf_inverse_sRGB`, which the
    /// upstream pipeline uses through `colour.RGB_to_RGB`.
    ///
    /// ```
    /// encoded = 12.92 · linear                      for linear <= 0.0031308
    /// encoded = 1.055 · linear ** (1 / 2.4) - 0.055   otherwise
    /// ```
    ///
    /// Negative values keep their sign, exactly like the upstream
    /// `numpy.where` implementation.
    public static func sRGBEncode(_ value: Double) -> Double {
        if value <= 0.0031308 {
            return 12.92 * value
        }
        return 1.055 * pow(value, 1.0 / 2.4) - 0.055
    }

    // MARK: - ProPhoto RGB

    /// The ProPhoto RGB electro-optical transfer function.
    ///
    /// Upstream reference: `colour.models.cctf_decoding_ProPhotoRGB`
    /// (the ROMM RGB transfer function).
    ///
    /// ```
    /// linear = value / 16          for value < 16 · E_t
    /// linear = value ** 1.8        otherwise
    /// ```
    ///
    /// with `E_t = 16 ** (1.8 / (1 - 1.8))`.
    public static func proPhotoDecode(_ value: Double) -> Double {
        let threshold = 16 * pow(16.0, 1.8 / (1.0 - 1.8))
        if value < threshold {
            return value / 16.0
        }
        // `spow` keeps the sign of negative values.
        let magnitude = pow(abs(value), 1.8)
        return value < 0 ? -magnitude : magnitude
    }

    /// The inverse electro-optical transfer function of ProPhoto RGB.
    ///
    /// Upstream reference: `colour.models.cctf_encoding_ProPhotoRGB`.
    ///
    /// ```
    /// encoded = value · 16          for value < E_t
    /// encoded = value ** (1 / 1.8)  otherwise
    /// ```
    public static func proPhotoEncode(_ value: Double) -> Double {
        let threshold = pow(16.0, 1.8 / (1.0 - 1.8))
        if value < threshold {
            return value * 16.0
        }
        let magnitude = pow(abs(value), 1.0 / 1.8)
        return value < 0 ? -magnitude : magnitude
    }

    /// Converts an encoded sRGB triplet into CIELAB (D65).
    ///
    /// - Parameter rgb: the encoded sRGB values (R, G, B).
    /// - Returns: the CIELAB colour.
    public static func sRGBToLab(_ rgb: [Double]) -> LabColour {
        let linear = rgb.map(sRGBDecode)
        let xyz = multiply(matrix: sRGBToXYZMatrix, vector: linear)
        return xyzToLab(xyz)
    }

    // MARK: - CIELAB

    /// Converts CIE XYZ into CIELAB, using the D65 white point of sRGB.
    ///
    /// - Parameter xyz: the tristimulus values (X, Y, Z).
    /// - Returns: the CIELAB colour.
    public static func xyzToLab(_ xyz: [Double]) -> LabColour {
        let epsilon = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        let white = sRGBWhitePoint

        func f(_ t: Double) -> Double {
            if t > epsilon {
                return pow(t, 1.0 / 3.0)
            }
            return (kappa * t + 16.0) / 116.0
        }

        let fx = f(xyz[0] / white[0])
        let fy = f(xyz[1] / white[1])
        let fz = f(xyz[2] / white[2])
        return LabColour(l: 116.0 * fy - 16.0, a: 500.0 * (fx - fy), b: 200.0 * (fy - fz))
    }

    // MARK: - CIEDE2000

    /// The CIEDE2000 colour difference between two CIELAB colours.
    ///
    /// Implements the formula of Sharma, Wu and Dalal (2005), "The CIEDE2000
    /// Color-Difference Formula: Implementation Notes, Supplementary Test
    /// Data, and Mathematical Observations", with the reference conditions
    /// `kL = kC = kH = 1`.
    ///
    /// - Parameters:
    ///   - lab1: the first colour.
    ///   - lab2: the second colour.
    /// - Returns: the colour difference ΔE₀₀.
    public static func deltaE2000(_ lab1: LabColour, _ lab2: LabColour) -> Double {
        let c1 = (lab1.a * lab1.a + lab1.b * lab1.b).squareRoot()
        let c2 = (lab2.a * lab2.a + lab2.b * lab2.b).squareRoot()
        let cBar = (c1 + c2) / 2.0
        let cBar7 = pow(cBar, 7.0)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + 6103515625.0)).squareRoot())  // 25 ** 7

        let a1Prime = (1 + g) * lab1.a
        let a2Prime = (1 + g) * lab2.a
        let c1Prime = (a1Prime * a1Prime + lab1.b * lab1.b).squareRoot()
        let c2Prime = (a2Prime * a2Prime + lab2.b * lab2.b).squareRoot()
        let h1Prime = hueAngle(b: lab1.b, aPrime: a1Prime)
        let h2Prime = hueAngle(b: lab2.b, aPrime: a2Prime)

        let deltaLPrime = lab2.l - lab1.l
        let deltaCPrime = c2Prime - c1Prime

        var deltaHueSmall = 0.0
        if c1Prime * c2Prime != 0 {
            deltaHueSmall = h2Prime - h1Prime
            if deltaHueSmall > 180 {
                deltaHueSmall -= 360
            } else if deltaHueSmall < -180 {
                deltaHueSmall += 360
            }
        }
        let deltaHPrime = 2 * (c1Prime * c2Prime).squareRoot() * sin(deltaHueSmall * .pi / 360.0)

        let lBarPrime = (lab1.l + lab2.l) / 2.0
        let cBarPrime = (c1Prime + c2Prime) / 2.0

        var hBarPrime: Double
        if c1Prime * c2Prime == 0 {
            hBarPrime = h1Prime + h2Prime
        } else {
            let hueSum = h1Prime + h2Prime
            let hueDifference = abs(h1Prime - h2Prime)
            if hueDifference <= 180 {
                hBarPrime = hueSum / 2.0
            } else if hueSum < 360 {
                hBarPrime = (hueSum + 360) / 2.0
            } else {
                hBarPrime = (hueSum - 360) / 2.0
            }
        }

        let t = 1
            - 0.17 * cos((hBarPrime - 30) * .pi / 180.0)
            + 0.24 * cos((2 * hBarPrime) * .pi / 180.0)
            + 0.32 * cos((3 * hBarPrime + 6) * .pi / 180.0)
            - 0.20 * cos((4 * hBarPrime - 63) * .pi / 180.0)

        let deltaTheta = 30 * exp(-pow((hBarPrime - 275) / 25, 2))
        let rC = 2 * (cBarPrime * cBarPrime * cBarPrime * cBarPrime * cBarPrime * cBarPrime * cBarPrime
            / (cBarPrime * cBarPrime * cBarPrime * cBarPrime * cBarPrime * cBarPrime * cBarPrime + 6103515625.0)).squareRoot()
        let rT = -sin(2 * deltaTheta * .pi / 180.0) * rC

        let lBarPrimeMinus50Squared = (lBarPrime - 50) * (lBarPrime - 50)
        let sL = 1 + (0.015 * lBarPrimeMinus50Squared) / (20 + lBarPrimeMinus50Squared).squareRoot()
        let sC = 1 + 0.045 * cBarPrime
        let sH = 1 + 0.015 * cBarPrime * t

        let termL = deltaLPrime / sL
        let termC = deltaCPrime / sC
        let termH = deltaHPrime / sH
        return (termL * termL + termC * termC + termH * termH + rT * termC * termH).squareRoot()
    }

    /// The hue angle of a CIELAB colour, in degrees.
    private static func hueAngle(b: Double, aPrime: Double) -> Double {
        if b == 0 && aPrime == 0 { return 0 }
        var angle = atan2(b, aPrime) * 180.0 / .pi
        if angle < 0 { angle += 360 }
        return angle
    }

    // MARK: - Helpers

    /// Multiplies a 3x3 matrix with a 3 element vector.
    public static func multiply(matrix: [[Double]], vector: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: 3)
        for row in 0..<3 {
            var total = 0.0
            for column in 0..<3 {
                total += matrix[row][column] * vector[column]
            }
            result[row] = total
        }
        return result
    }
}
