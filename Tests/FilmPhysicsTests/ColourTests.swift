//
//  ColourTests.swift
//  light suffer胶片 — iOS app
//
//  Tests of the colour utilities: the sRGB transfer function, the CIELAB
//  conversion and the CIEDE2000 colour difference.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class ColourTests: XCTestCase {

    // MARK: - Sharma test data
    //
    // The published test pairs of
    //   Sharma, G., Wu, W., & Dalal, E. N. (2005). The CIEDE2000 Color-Difference
    //   Formula: Implementation Notes, Supplementary Test Data, and Mathematical
    //   Observations. Color Research & Application, 30(1), 21-30.
    // The pair that the reference implementation leaves out (the ambiguous hue
    // difference of the blue quadrant) is not part of the data set either.

    /// The first colour of every Sharma test pair.
    private static let lab1: [[Double]] = [
        [50.0000, 2.6772, -79.7751],
        [50.0000, 3.1571, -77.2803],
        [50.0000, 2.8361, -74.0200],
        [50.0000, -1.3802, -84.2814],
        [50.0000, -1.1848, -84.8006],
        [50.0000, -0.9009, -85.5211],
        [50.0000, 0.0000, 0.0000],
        [50.0000, -1.0000, 2.0000],
        [50.0000, 2.4900, -0.0010],
        [50.0000, 2.4900, -0.0010],
        [50.0000, 2.4900, -0.0010],
        [50.0000, 2.4900, -0.0010],
        [50.0000, -0.0010, 2.4900],
        [50.0000, -0.0010, 2.4900],
        [50.0000, 2.5000, 0.0000],
        [50.0000, 2.5000, 0.0000],
        [50.0000, 2.5000, 0.0000],
        [50.0000, 2.5000, 0.0000],
        [50.0000, 2.5000, 0.0000],
        [50.0000, 2.5000, 0.0000],
        [50.0000, 2.5000, 0.0000],
        [50.0000, 2.5000, 0.0000],
        [50.0000, 2.5000, 0.0000],
        [60.2574, -34.0099, 36.2677],
        [63.0109, -31.0961, -5.8663],
        [61.2901, 3.7196, -5.3901],
        [35.0831, -44.1164, 3.7933],
        [22.7233, 20.0904, -46.6940],
        [36.4612, 47.8580, 18.3852],
        [90.8027, -2.0831, 1.4410],
        [90.9257, -0.5406, -0.9208],
        [6.7747, -0.2908, -2.4247],
        [2.0776, 0.0795, -1.1350],
    ]

    /// The second colour of every Sharma test pair.
    private static let lab2: [[Double]] = [
        [50.0000, 0.0000, -82.7485],
        [50.0000, 0.0000, -82.7485],
        [50.0000, 0.0000, -82.7485],
        [50.0000, 0.0000, -82.7485],
        [50.0000, 0.0000, -82.7485],
        [50.0000, 0.0000, -82.7485],
        [50.0000, -1.0000, 2.0000],
        [50.0000, 0.0000, 0.0000],
        [50.0000, -2.4900, 0.0009],
        [50.0000, -2.4900, 0.0010],
        [50.0000, -2.4900, 0.0011],
        [50.0000, -2.4900, 0.0012],
        [50.0000, 0.0009, -2.4900],
        [50.0000, 0.0011, -2.4900],
        [50.0000, 0.0000, -2.5000],
        [73.0000, 25.0000, -18.0000],
        [61.0000, -5.0000, 29.0000],
        [56.0000, -27.0000, -3.0000],
        [58.0000, 24.0000, 15.0000],
        [50.0000, 3.1736, 0.5854],
        [50.0000, 3.2972, 0.0000],
        [50.0000, 1.8634, 0.5757],
        [50.0000, 3.2592, 0.3350],
        [60.4626, -34.1751, 39.4387],
        [62.8187, -29.7946, -4.0864],
        [61.4292, 2.2480, -4.9620],
        [35.0232, -40.0716, 1.5901],
        [23.0331, 14.9730, -42.5619],
        [36.2715, 50.5065, 21.2231],
        [91.1528, -1.6435, 0.0447],
        [88.6381, -0.8985, -0.7239],
        [5.8714, -0.0985, -2.2286],
        [0.9033, -0.0636, -0.5514],
    ]

    /// The expected colour difference of every Sharma test pair.
    private static let expected: [Double] = [
        2.0425,
        2.8615,
        3.4412,
        1.0000,
        1.0000,
        1.0000,
        2.3669,
        2.3669,
        7.1792,
        7.1792,
        7.2195,
        7.2195,
        4.8045,
        4.7461,
        4.3065,
        27.1492,
        22.8977,
        31.9030,
        19.4535,
        1.0000,
        1.0000,
        1.0000,
        1.0000,
        1.2644,
        1.2630,
        1.8731,
        1.8645,
        2.0373,
        1.4146,
        1.4441,
        1.5381,
        0.6377,
        0.9082,
    ]

    // MARK: - sRGB

    /// The sRGB transfer function round trips.
    func testSRGBTransferFunctionRoundTrips() {
        for value in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(Colour.sRGBEncode(Colour.sRGBDecode(value)), value, accuracy: 1e-12)
        }
    }

    /// The sRGB transfer function matches the reference values of IEC 61966-2-1.
    func testSRGBTransferFunctionValues() {
        XCTAssertEqual(Colour.sRGBEncode(0.0), 0.0, accuracy: 1e-15)
        XCTAssertEqual(Colour.sRGBEncode(1.0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(Colour.sRGBDecode(0.5), 0.21404114048223255, accuracy: 1e-12)
        XCTAssertEqual(Colour.sRGBEncode(0.21404114048223255), 0.5, accuracy: 1e-12)
        // The linear segment of the transfer function.
        XCTAssertEqual(Colour.sRGBEncode(0.0031308), 0.040449936, accuracy: 1e-9)
    }

    /// The sRGB to XYZ matrix is the inverse of the XYZ to sRGB matrix.
    func testSRGBMatricesAreInverse() throws {
        let common = try JSONValue.load(named: "slice1_common")
        let colour = try XCTUnwrap(common["color"])
        let reference = try XCTUnwrap(colour["srgb_xyz_to_rgb_matrix"]?.doubleRows)
        for row in 0..<3 {
            for column in 0..<3 {
                let value = Colour.XYZToSRGBMatrix[row][column]
                XCTAssertEqual(value, reference[row][column], accuracy: 1e-9)
            }
        }
        let product = Colour.multiply(matrix: Colour.sRGBToXYZMatrix, vector: [0.3, 0.4, 0.5])
        let roundTrip = Colour.multiply(matrix: reference, vector: product)
        XCTAssertEqual(roundTrip[0], 0.3, accuracy: 1e-4)
        XCTAssertEqual(roundTrip[1], 0.4, accuracy: 1e-4)
        XCTAssertEqual(roundTrip[2], 0.5, accuracy: 1e-4)
    }

    // MARK: - CIELAB

    /// The CIELAB conversion of the sRGB white point.
    ///
    /// The reference values are the ones of the `colour-science` library the
    /// upstream engine uses.
    func testLabOfTheWhitePoint() {
        let lab = Colour.sRGBToLab([1, 1, 1])
        XCTAssertEqual(lab.l, 100, accuracy: 1e-9)
        XCTAssertEqual(lab.a, 0.00772826771, accuracy: 1e-6)
        XCTAssertEqual(lab.b, 0.00353527507, accuracy: 1e-6)
    }

    /// The CIELAB conversion of the sRGB black point is neutral and dark.
    func testLabOfTheBlackPoint() {
        let lab = Colour.sRGBToLab([0, 0, 0])
        XCTAssertEqual(lab.l, 0, accuracy: 1e-12)
        XCTAssertEqual(lab.a, 0, accuracy: 1e-9)
        XCTAssertEqual(lab.b, 0, accuracy: 1e-9)
    }

    /// A few reference CIELAB values of the sRGB primaries.
    func testLabOfThePrimaryColours() {
        let red = Colour.sRGBToLab([1, 0, 0])
        XCTAssertEqual(red.l, 53.23288179, accuracy: 1e-6)
        XCTAssertEqual(red.a, 80.11117774, accuracy: 1e-6)
        XCTAssertEqual(red.b, 67.22370367, accuracy: 1e-6)

        let green = Colour.sRGBToLab([0, 1, 0])
        XCTAssertEqual(green.l, 87.73703347, accuracy: 1e-6)
        XCTAssertEqual(green.a, -86.18285500, accuracy: 1e-6)
        XCTAssertEqual(green.b, 83.18783466, accuracy: 1e-6)

        let blue = Colour.sRGBToLab([0, 0, 1])
        XCTAssertEqual(blue.l, 32.30258667, accuracy: 1e-6)
        XCTAssertEqual(blue.a, 79.19808023, accuracy: 1e-6)
        XCTAssertEqual(blue.b, -107.85035570, accuracy: 1e-6)
    }

    // MARK: - CIEDE2000

    /// The CIEDE2000 implementation reproduces the published test pairs.
    func testCIEDE2000SharmaTestData() {
        XCTAssertEqual(Self.lab1.count, Self.lab2.count)
        XCTAssertEqual(Self.lab1.count, Self.expected.count)
        for index in 0..<Self.lab1.count {
            let lab1 = LabColour(l: Self.lab1[index][0], a: Self.lab1[index][1], b: Self.lab1[index][2])
            let lab2 = LabColour(l: Self.lab2[index][0], a: Self.lab2[index][1], b: Self.lab2[index][2])
            let deltaE = Colour.deltaE2000(lab1, lab2)
            XCTAssertEqual(
                deltaE, Self.expected[index], accuracy: 1e-4,
                "Sharma test pair \(index) failed"
            )
        }
    }

    /// Identical colours have no colour difference.
    func testCIEDE2000OfIdenticalColours() {
        let lab = LabColour(l: 42.5, a: -13.25, b: 7.75)
        XCTAssertEqual(Colour.deltaE2000(lab, lab), 0, accuracy: 1e-12)
    }
}
