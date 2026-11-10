//
//  StatisticsSupportTests.swift
//  light suffer胶片 — iOS app
//
//  The numerics of the statistical gate of the slice 6.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class StatisticsSupportTests: XCTestCase {

    /// The cumulative distribution function of the Student t distribution
    /// matches the published quantiles.
    func testTheStudentTCumulativeDistributionFunction() {
        // The 97.5 % quantile of the Student t with 11 degrees of freedom
        // is 2.200985 (the table of the t distribution).
        XCTAssertEqual(studentTCDF(2.200985, degreesOfFreedom: 11), 0.975, accuracy: 1e-6)
        XCTAssertEqual(studentTCDF(-2.200985, degreesOfFreedom: 11), 0.025, accuracy: 1e-6)
        XCTAssertEqual(studentTCDF(0, degreesOfFreedom: 11), 0.5, accuracy: 1e-12)
        // A large value: the tail of the Student t is much heavier than the
        // one of the normal distribution.
        XCTAssertGreaterThan(studentTCDF(4.378, degreesOfFreedom: 11), 0.999)
    }

    /// The quantile of the Student t distribution inverts the cumulative
    /// distribution function.
    func testTheStudentTQuantile() {
        for degreesOfFreedom in [1, 5, 11, 30] {
            for probability in [0.001, 0.025, 0.5, 0.975, 0.999] {
                let quantile = studentTQuantile(
                    probability, degreesOfFreedom: degreesOfFreedom
                )
                XCTAssertEqual(
                    studentTCDF(quantile, degreesOfFreedom: degreesOfFreedom),
                    probability,
                    accuracy: 1e-9,
                    "\(degreesOfFreedom) degrees of freedom, \(probability)"
                )
            }
        }
    }

    /// The critical value of the gate is the Bonferroni corrected quantile
    /// of the Student t distribution.
    ///
    /// The family of the slice 6 holds 836 comparisons, the upstream mean
    /// averages 12 realisations: the critical value is the quantile of the
    /// Student t with 11 degrees of freedom at the level
    /// `1 - 0.01 / (2 · 836)`, corrected for the population standard
    /// deviation the fixture stores.
    func testTheCriticalValueOfTheGate() {
        let gate = StatisticalGate(
            comparisons: 836, upstreamSeeds: 12, portSeeds: 8
        )
        XCTAssertEqual(gate.k, 7.83609, accuracy: 1e-4)
        // The quantile itself, without the correction of the standard
        // deviation: 7.502577.
        XCTAssertEqual(
            studentTQuantile(1 - 0.01 / (2 * 836), degreesOfFreedom: 11),
            7.502577,
            accuracy: 1e-4
        )
    }

    /// The floor of the comparison is the resolution of the stored values,
    /// and it only applies when the spread of the upstream is below it.
    func testTheResolutionFloor() {
        // The upstream spread is resolved by the fixture: no floor.
        XCTAssertEqual(
            StatisticalGate.resolutionFloor(
                port: 0.0004, upstreamMean: 0.0004, upstreamStd: 0.0002
            ),
            0
        )
        // The upstream spread is the floating point noise of the upstream
        // computation: the floor is the resolution of the stored values
        // (half of the last significant digit of a value of magnitude one).
        XCTAssertEqual(
            StatisticalGate.resolutionFloor(
                port: 1 - 4.5e-10, upstreamMean: 1, upstreamStd: 6.2e-10
            ),
            5e-7,
            accuracy: 1e-12
        )
    }

    /// The number of comparisons of the family of the slice 6 is the one the
    /// gate is calibrated with.
    func testTheSizeOfTheFamily() throws {
        let fixture = try slice6Fixture()
        XCTAssertEqual(try slice6FamilySize(fixture), 836)
    }
}
