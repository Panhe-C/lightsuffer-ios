//
//  ColourScience.swift
//  light suffer胶片 — iOS app
//
//  The colour-science primitives the upstream engine relies on: the
//  chromatic adaptation transforms (CAT02 / CAT16 / Bradford), the RGB
//  colourspaces (sRGB, ProPhoto RGB) and the RGB ↔ XYZ conversions.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

// MARK: - Chromaticity

/// A CIE 1931 `xy` chromaticity.
public struct Chromaticity: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// The chromaticity as an array.
    public var array: [Double] { [x, y] }
}

// MARK: - Matrix helpers

/// Small helpers for the 3×3 colour matrices.
public enum Matrix {

    /// Multiplies a 3×3 matrix with a 3 element vector.
    public static func multiply(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
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

    /// Multiplies two 3×3 matrices.
    public static func multiply(_ lhs: [[Double]], _ rhs: [[Double]]) -> [[Double]] {
        var result = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for row in 0..<3 {
            for column in 0..<3 {
                var total = 0.0
                for index in 0..<3 {
                    total += lhs[row][index] * rhs[index][column]
                }
                result[row][column] = total
            }
        }
        return result
    }

    /// The inverse of a 3×3 matrix.
    public static func inverse(_ matrix: [[Double]]) -> [[Double]]? {
        let a = matrix[0][0], b = matrix[0][1], c = matrix[0][2]
        let d = matrix[1][0], e = matrix[1][1], f = matrix[1][2]
        let g = matrix[2][0], h = matrix[2][1], i = matrix[2][2]
        let determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard determinant != 0, determinant.isFinite else { return nil }
        let inverseDeterminant = 1.0 / determinant
        return [
            [
                (e * i - f * h) * inverseDeterminant,
                (c * h - b * i) * inverseDeterminant,
                (b * f - c * e) * inverseDeterminant,
            ],
            [
                (f * g - d * i) * inverseDeterminant,
                (a * i - c * g) * inverseDeterminant,
                (c * d - a * f) * inverseDeterminant,
            ],
            [
                (d * h - e * g) * inverseDeterminant,
                (b * g - a * h) * inverseDeterminant,
                (a * e - b * d) * inverseDeterminant,
            ],
        ]
    }
}

// MARK: - Chromatic adaptation

/// The chromatic adaptation transforms (cone response domains).
///
/// Upstream reference: `colour.adaptation.CHROMATIC_ADAPTATION_TRANSFORMS`
/// (`CAT_CAT02`, `CAT_CAT16`, `CAT_BRADFORD`).
public enum ChromaticAdaptationTransform: String, CaseIterable, Sendable {
    case cat02
    case cat16
    case bradford

    /// The cone response matrix of the transform.
    public var matrix: [[Double]] {
        switch self {
        case .cat02:
            return [
                [0.7328, 0.4296, -0.1624],
                [-0.7036, 1.6975, 0.0061],
                [0.0030, 0.0136, 0.9834],
            ]
        case .cat16:
            return [
                [0.401288, 0.650173, -0.051461],
                [-0.250268, 1.204414, 0.045854],
                [-0.002079, 0.048952, 0.953127],
            ]
        case .bradford:
            return [
                [0.8951, 0.2664, -0.1614],
                [-0.7502, 1.7135, 0.0367],
                [0.0389, -0.0685, 1.0296],
            ]
        }
    }

    /// The chromatic adaptation matrix from a source whitepoint to a
    /// destination whitepoint.
    ///
    /// Upstream reference:
    /// `colour.adaptation.matrix_chromatic_adaptation_VonKries`.
    ///
    /// ```
    /// RGB_w  = M · XYZ_w
    /// D      = RGB_wr / RGB_w
    /// M_CAT  = M⁻¹ · diag(D) · M
    /// ```
    ///
    /// - Parameters:
    ///   - sourceWhite: the XYZ tristimulus values of the test whitepoint.
    ///   - destinationWhite: the XYZ tristimulus values of the reference whitepoint.
    public func matrix(from sourceWhite: [Double], to destinationWhite: [Double]) -> [[Double]] {
        let coneMatrix = matrix
        let sourceCone = Matrix.multiply(coneMatrix, sourceWhite)
        let destinationCone = Matrix.multiply(coneMatrix, destinationWhite)
        var diagonal = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for index in 0..<3 {
            diagonal[index][index] = destinationCone[index] / sourceCone[index]
        }
        guard let inverse = Matrix.inverse(coneMatrix) else { return coneMatrix }
        return Matrix.multiply(Matrix.multiply(inverse, diagonal), coneMatrix)
    }
}

// MARK: - Colourspaces

/// An RGB colourspace, described the way `colour-science` describes it.
///
/// Upstream reference: `colour.models.RGB_Colourspace` and the
/// `colour.models.RGB_COLOURSPACES` registry.
public struct RGBColourspace: Sendable {

    /// The name of the colourspace.
    public let name: String
    /// The chromaticities of the red, green and blue primaries.
    public let primaries: [Chromaticity]
    /// The chromaticity of the whitepoint.
    public let whitepoint: Chromaticity
    /// The RGB → XYZ matrix of the colourspace.
    ///
    /// `colour-science` ships *rounded* matrices for the standard
    /// colourspaces (the ProPhoto RGB matrix is the one of the
    /// specification, the sRGB matrix the rounded IEC 61966-2-1 one).  The
    /// port reproduces them verbatim so that the results are identical to the
    /// upstream engine; ``normalisedPrimaryMatrix(primaries:whitepoint:)``
    /// derives the same matrix from the primaries and the whitepoint.
    public let matrixRGBToXYZ: [[Double]]
    /// The XYZ → RGB matrix of the colourspace.
    ///
    /// `colour-science` ships this matrix explicitly too; it is *not* the
    /// exact inverse of ``matrixRGBToXYZ`` (the rounded matrices differ by
    /// about 1e-5, which is visible in the near-null components of the
    /// conversion).
    public let matrixXYZToRGB: [[Double]]

    public init(
        name: String,
        primaries: [Chromaticity],
        whitepoint: Chromaticity,
        matrixRGBToXYZ: [[Double]],
        matrixXYZToRGB: [[Double]]? = nil
    ) {
        self.name = name
        self.primaries = primaries
        self.whitepoint = whitepoint
        self.matrixRGBToXYZ = matrixRGBToXYZ
        self.matrixXYZToRGB = matrixXYZToRGB ?? (Matrix.inverse(matrixRGBToXYZ) ?? matrixRGBToXYZ)
    }

    /// The XYZ → RGB matrix of the colourspace.
    public var xyzToRGBMatrix: [[Double]] { matrixXYZToRGB }

    /// The XYZ tristimulus values of the whitepoint (at `Y = 1`).
    public var whitepointXYZ: [Double] {
        ColourScience.xyToXYZ(whitepoint)
    }

    /// The normalised primary matrix of a colourspace.
    ///
    /// Upstream reference: `colour.models.normalised_primary_matrix`.
    ///
    /// - Parameters:
    ///   - primaries: the chromaticities of the red, green and blue primaries.
    ///   - whitepoint: the chromaticity of the whitepoint.
    public static func normalisedPrimaryMatrix(
        primaries: [Chromaticity],
        whitepoint: Chromaticity
    ) -> [[Double]] {
        // The primaries as (X, Y, Z) columns with Y = 1.
        var primaryMatrix = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for index in 0..<3 {
            let primary = primaries[index]
            primaryMatrix[index][0] = primary.x / primary.y
            primaryMatrix[index][1] = 1.0
            primaryMatrix[index][2] = (1.0 - primary.x - primary.y) / primary.y
        }
        let white = ColourScience.xyToXYZ(whitepoint)
        guard let inverse = Matrix.inverse(primaryMatrix) else { return primaryMatrix }
        let coefficients = Matrix.multiply(inverse, white)
        var result = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for row in 0..<3 {
            for column in 0..<3 {
                result[row][column] = primaryMatrix[row][column] * coefficients[column]
            }
        }
        return result
    }

    /// The sRGB colourspace.
    ///
    /// Upstream reference: `colour.models.RGB_COLOURSPACES["sRGB"]`.
    public static let sRGB = RGBColourspace(
        name: "sRGB",
        primaries: [
            Chromaticity(x: 0.64, y: 0.33),
            Chromaticity(x: 0.3, y: 0.6),
            Chromaticity(x: 0.15, y: 0.06),
        ],
        whitepoint: Chromaticity(x: 0.3127, y: 0.329),
        matrixRGBToXYZ: [
            [0.4124, 0.3576, 0.1805],
            [0.2126, 0.7152, 0.0722],
            [0.0193, 0.1192, 0.9505],
        ],
        matrixXYZToRGB: [
            [3.2406, -1.5372, -0.4986],
            [-0.9689, 1.8758, 0.0415],
            [0.0557, -0.204, 1.057],
        ]
    )

    /// The ProPhoto RGB colourspace.
    ///
    /// Upstream reference: `colour.models.RGB_COLOURSPACES["ProPhoto RGB"]`.
    public static let proPhotoRGB = RGBColourspace(
        name: "ProPhoto RGB",
        primaries: [
            Chromaticity(x: 0.7347, y: 0.2653),
            Chromaticity(x: 0.1596, y: 0.8404),
            Chromaticity(x: 0.0366, y: 0.0001),
        ],
        whitepoint: Chromaticity(x: 0.3457, y: 0.3585),
        matrixRGBToXYZ: [
            [0.7977, 0.1352, 0.0313],
            [0.2880, 0.7119, 0.0001],
            [0.0, 0.0, 0.8249],
        ],
        matrixXYZToRGB: [
            [1.346, -0.2556, -0.0511],
            [-0.5446, 1.5082, 0.0205],
            [0.0, 0.0, 1.2123],
        ]
    )

    /// Looks a colourspace up by name.
    ///
    /// Only the colourspaces the upstream pipeline uses are supported.
    public static func named(_ name: String) -> RGBColourspace? {
        switch name {
        case "sRGB": return .sRGB
        case "ProPhoto RGB": return .proPhotoRGB
        default: return nil
        }
    }

    /// Decodes an encoded value into a linear one (the colour component
    /// transfer function of the colourspace).
    ///
    /// Upstream reference: `colour.models.RGB_Colourspace.cctf_decoding`.
    public func decode(_ value: Double) -> Double {
        switch name {
        case "sRGB": return Colour.sRGBDecode(value)
        case "ProPhoto RGB": return Colour.proPhotoDecode(value)
        default: return value
        }
    }

    /// Encodes a linear value (the colour component transfer function of the
    /// colourspace).
    ///
    /// Upstream reference: `colour.models.RGB_Colourspace.cctf_encoding`.
    public func encode(_ value: Double) -> Double {
        switch name {
        case "sRGB": return Colour.sRGBEncode(value)
        case "ProPhoto RGB": return Colour.proPhotoEncode(value)
        default: return value
        }
    }
}

// MARK: - Conversions

/// The RGB ↔ XYZ conversions of `colour-science`.
public enum ColourScience {

    /// Converts an `xy` chromaticity into XYZ tristimulus values at `Y = 1`.
    ///
    /// Upstream reference: `colour.models.xy_to_XYZ`.
    public static func xyToXYZ(_ xy: Chromaticity) -> [Double] {
        let y = max(xy.y, 1e-12)
        return [xy.x / y, 1.0, (1.0 - xy.x - xy.y) / y]
    }

    /// Converts XYZ tristimulus values into an `xy` chromaticity.
    ///
    /// Upstream reference: `colour.models.XYZ_to_xy`.
    public static func xyzToXY(_ xyz: [Double]) -> Chromaticity {
        let total = xyz[0] + xyz[1] + xyz[2]
        let denominator = Swift.max(total, 1e-12)
        return Chromaticity(x: xyz[0] / denominator, y: xyz[1] / denominator)
    }

    /// Converts RGB values into XYZ tristimulus values.
    ///
    /// Upstream reference: `colour.models.RGB_to_XYZ`.
    ///
    /// The chromatic adaptation is applied **after** the RGB → XYZ matrix
    /// and adapts the whitepoint of the colourspace to the requested
    /// illuminant, exactly like the upstream engine does:
    ///
    /// ```
    /// XYZ = M_CAT(colourspace white → illuminant) · (M_RGB→XYZ · RGB)
    /// ```
    ///
    /// - Parameters:
    ///   - rgb: the RGB values (encoded when `applyCCTFDecoding` is true).
    ///   - colourspace: the colourspace of the values.
    ///   - illuminant: the chromaticity of the target illuminant.
    ///   - transform: the chromatic adaptation transform.
    ///   - applyCCTFDecoding: whether the values are encoded.
    public static func rgbToXYZ(
        rgb: [Double],
        colourspace: RGBColourspace,
        illuminant: Chromaticity,
        transform: ChromaticAdaptationTransform = .cat02,
        applyCCTFDecoding: Bool = false
    ) -> [Double] {
        var linear = rgb
        if applyCCTFDecoding {
            linear = rgb.map { colourspace.decode($0) }
        }
        let xyz = Matrix.multiply(colourspace.matrixRGBToXYZ, linear)
        let adaptation = transform.matrix(
            from: colourspace.whitepointXYZ,
            to: xyToXYZ(illuminant)
        )
        return Matrix.multiply(adaptation, xyz)
    }

    /// Converts XYZ tristimulus values into RGB values.
    ///
    /// Upstream reference: `colour.models.XYZ_to_RGB`.
    ///
    /// The chromatic adaptation is applied **to the input** and adapts the
    /// requested illuminant to the whitepoint of the colourspace:
    ///
    /// ```
    /// RGB = M_XYZ→RGB · M_CAT(illuminant → colourspace white) · XYZ
    /// ```
    ///
    /// - Parameters:
    ///   - xyz: the XYZ tristimulus values.
    ///   - colourspace: the target colourspace.
    ///   - illuminant: the chromaticity of the illuminant of the XYZ values.
    ///   - transform: the chromatic adaptation transform.
    public static func xyzToRGB(
        xyz: [Double],
        colourspace: RGBColourspace,
        illuminant: Chromaticity,
        transform: ChromaticAdaptationTransform = .cat02
    ) -> [Double] {
        let adaptation = transform.matrix(
            from: xyToXYZ(illuminant),
            to: colourspace.whitepointXYZ
        )
        return Matrix.multiply(colourspace.matrixXYZToRGB, Matrix.multiply(adaptation, xyz))
    }

    /// The matrix converting RGB values of one colourspace into RGB values
    /// of another one.
    ///
    /// Upstream reference: `colour.models.matrix_RGB_to_RGB`.
    public static func matrixRGBToRGB(
        from input: RGBColourspace,
        to output: RGBColourspace,
        transform: ChromaticAdaptationTransform = .cat02
    ) -> [[Double]] {
        let adaptation = transform.matrix(
            from: input.whitepointXYZ,
            to: output.whitepointXYZ
        )
        return Matrix.multiply(
            output.matrixXYZToRGB,
            Matrix.multiply(adaptation, input.matrixRGBToXYZ)
        )
    }
}
