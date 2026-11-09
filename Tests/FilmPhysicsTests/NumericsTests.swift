//
//  NumericsTests.swift
//  light suffer胶片 — iOS app
//
//  Tests of the numeric helpers: the interpolation semantics of the upstream
//  engine, the geometric mean and the normal distribution.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class NumericsTests: XCTestCase {

    // MARK: - Interpolation

    /// The interpolation clamps the values outside of the axis, exactly like
    /// `numpy.interp`.
    func testInterpolationClampsOutsideTheAxis() {
        let axis = [0.0, 1.0, 2.0]
        let values = [10.0, 20.0, 30.0]
        XCTAssertEqual(Numerics.interpolate(x: -5, axis: axis, values: values), 10.0)
        XCTAssertEqual(Numerics.interpolate(x: 0, axis: axis, values: values), 10.0)
        XCTAssertEqual(Numerics.interpolate(x: 5, axis: axis, values: values), 30.0)
        XCTAssertEqual(Numerics.interpolate(x: 2, axis: axis, values: values), 30.0)
    }

    /// The interpolation returns the value of the knot it lands on.
    func testInterpolationIsExactOnTheKnots() {
        let axis = [0.0, 1.0, 2.0]
        let values = [10.0, 20.0, 30.0]
        XCTAssertEqual(Numerics.interpolate(x: 1.0, axis: axis, values: values), 20.0)
        XCTAssertEqual(Numerics.interpolate(x: 0.5, axis: axis, values: values), 15.0)
        XCTAssertEqual(Numerics.interpolate(x: 1.25, axis: axis, values: values), 22.5)
    }

    /// The interpolation of a `NaN` is a `NaN`.
    func testInterpolationOfNaN() {
        XCTAssertTrue(Numerics.interpolate(x: .nan, axis: [0, 1], values: [0, 1]).isNaN)
    }

    /// The density curve interpolation clamps like the upstream kernel does.
    func testDensityCurveInterpolationClamps() {
        let logExposure = [-1.0, 0.0, 1.0]
        let curves = [[0.0, 1.0, 2.0], [1.0, 2.0, 3.0], [2.0, 3.0, 4.0]]
        let below = DensityCurves.interpolateExposureToDensity(
            logExposureRGB: [-10, -10, -10], densityCurves: curves, logExposure: logExposure
        )
        XCTAssertEqual(below, [0.0, 1.0, 2.0])
        let above = DensityCurves.interpolateExposureToDensity(
            logExposureRGB: [10, 10, 10], densityCurves: curves, logExposure: logExposure
        )
        XCTAssertEqual(above, [2.0, 3.0, 4.0])
        let middle = DensityCurves.interpolateExposureToDensity(
            logExposureRGB: [-0.5, 0.5, 0.25], densityCurves: curves, logExposure: logExposure
        )
        XCTAssertEqual(middle[0], 0.5, accuracy: 1e-12)
        XCTAssertEqual(middle[1], 2.5, accuracy: 1e-12)
        XCTAssertEqual(middle[2], 3.25, accuracy: 1e-12)
    }

    /// The gamma factor moves the axis of the density curve interpolation.
    func testDensityCurveInterpolationWithGammaFactor() {
        let logExposure = [0.0, 1.0]
        let curves = [[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]]
        let plain = DensityCurves.interpolateExposureToDensity(
            logExposureRGB: [0.25, 0.25, 0.25], densityCurves: curves, logExposure: logExposure
        )
        XCTAssertEqual(plain[0], 0.25, accuracy: 1e-12)
        let gamma = DensityCurves.interpolateExposureToDensity(
            logExposureRGB: [0.25, 0.25, 0.25],
            densityCurves: curves,
            logExposure: logExposure,
            gammaFactor: [2.0, 2.0, 2.0]
        )
        // The axis is log_exposure / gamma, so 0.25 maps to 0.5 of the curve.
        XCTAssertEqual(gamma[0], 0.5, accuracy: 1e-12)
    }

    // MARK: - Statistics

    /// The geometric mean matches the upstream definition.
    func testGeometricMean() {
        XCTAssertEqual(Numerics.geometricMean([1, 1, 1]), 1, accuracy: 1e-15)
        XCTAssertEqual(Numerics.geometricMean([1, 4]), 2, accuracy: 1e-15)
        XCTAssertEqual(Numerics.geometricMean([0.8357499]), 0.8357499, accuracy: 1e-15)
    }

    /// The `NaN` aware statistics match the `numpy` behaviour.
    func testNanAwareStatistics() {
        XCTAssertEqual(Numerics.nanMin([3, .nan, 1]), 1)
        XCTAssertEqual(Numerics.nanMax([3, .nan, 1]), 3)
        XCTAssertEqual(Numerics.nanMean([3, .nan, 1]), 2)
        XCTAssertEqual(Numerics.nanToNum(.nan), 0)
        XCTAssertEqual(Numerics.nanToNum(.infinity), Double.greatestFiniteMagnitude)
        XCTAssertEqual(Numerics.nanToNum(-3.5), -3.5)
    }

    // MARK: - Normal distribution

    /// The normal distribution function matches the reference values.
    func testNormalCDF() {
        let reference: [(Double, Double)] = [
            (-10, 7.61985302416047e-24),
            (-6, 9.865876450376946e-10),
            (-3, 0.0013498980316300933),
            (-1, 0.15865525393145707),
            (-0.5, 0.3085375387259869),
            (0, 0.5),
            (0.5, 0.6914624612740131),
            (1, 0.8413447460685429),
            (3, 0.9986501019683699),
            (6, 0.9999999990134123),
            (10, 1.0),
        ]
        for (z, expected) in reference {
            XCTAssertEqual(Numerics.normalCDF(z), expected, accuracy: 1e-14, "at z = \(z)")
        }
    }

    /// The error function matches the reference values.
    func testErrorFunction() {
        XCTAssertEqual(Numerics.erf(0), 0, accuracy: 1e-16)
        XCTAssertEqual(Numerics.erf(0.5), 0.5204998778130465, accuracy: 1e-14)
        XCTAssertEqual(Numerics.erf(1), 0.8427007929497149, accuracy: 1e-14)
        XCTAssertEqual(Numerics.erf(2), 0.9953222650189527, accuracy: 1e-14)
        XCTAssertEqual(Numerics.erf(-1), -0.8427007929497149, accuracy: 1e-14)
        XCTAssertEqual(Numerics.erfc(1), 0.15729920705028513, accuracy: 1e-14)
        XCTAssertEqual(Numerics.erfc(-1), 1.8427007929497148, accuracy: 1e-14)
    }
}
