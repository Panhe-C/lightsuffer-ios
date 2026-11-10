//
//  ProfileLoaderTests.swift
//  light suffer胶片 — iOS app
//
//  Tests of the profile loader: the data the Swift port loads from the
//  bundled JSON has to be the data the upstream engine digested.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class ProfileLoaderTests: XCTestCase {

    /// The relative tolerance of the comparison with the reference fixtures.
    ///
    /// The fixtures store the values with seven significant digits, so the
    /// rounding alone is worth about 1e-7 relative.
    private let tolerance = 1e-6

    /// The relative difference of two values.
    private func relativeDifference(_ lhs: Double, _ rhs: Double) -> Double {
        if lhs.isNaN && rhs.isNaN { return 0 }
        let scale = Swift.max(1, Swift.max(abs(lhs), abs(rhs)))
        return abs(lhs - rhs) / scale
    }

    /// The maximum relative difference between two arrays.
    private func maxRelativeDifference(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count else { return .infinity }
        var maximum = 0.0
        for index in 0..<lhs.count {
            maximum = Swift.max(maximum, relativeDifference(lhs[index], rhs[index]))
        }
        return maximum
    }

    // MARK: - Helpers

    /// Compares an array of the profile with the reference fixture.
    private func assertMatches(
        _ values: [Double],
        _ reference: JSONValue?,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expected = try XCTUnwrap(reference?.flatDoubles, "\(label): missing reference")
        XCTAssertEqual(values.count, expected.count, "\(label): wrong length", file: file, line: line)
        let difference = maxRelativeDifference(values, expected)
        XCTAssertLessThanOrEqual(
            difference, tolerance, "\(label): max relative difference \(difference)", file: file, line: line
        )
    }

    /// Compares an array of the profile with an already extracted reference.
    private func assertMatches(
        _ values: [Double],
        _ reference: [Double]?,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expected = try XCTUnwrap(reference, "\(label): missing reference")
        XCTAssertEqual(values.count, expected.count, "\(label): wrong length", file: file, line: line)
        let difference = maxRelativeDifference(values, expected)
        XCTAssertLessThanOrEqual(
            difference, tolerance, "\(label): max relative difference \(difference)", file: file, line: line
        )
    }

    /// Compares a nested array of the profile with the reference fixture.
    private func assertMatches(
        _ values: [[Double]],
        _ reference: JSONValue?,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let expected = try XCTUnwrap(reference?.flatDoubles, "\(label): missing reference")
        let flat = values.flatMap { $0 }
        XCTAssertEqual(flat.count, expected.count, "\(label): wrong length", file: file, line: line)
        let difference = maxRelativeDifference(flat, expected)
        XCTAssertLessThanOrEqual(
            difference, tolerance, "\(label): max relative difference \(difference)", file: file, line: line
        )
    }

    // MARK: - Tests

    /// The film profile of the bundle is the profile the upstream engine used.
    func testFilmProfileMatchesTheDigestedData() throws {
        let common = try JSONValue.load(named: "slice1_common")
        let fixture = try XCTUnwrap(common["film"])
        let profile = try ProfileLoader.load(stock: "kodak_portra_400")

        // --- the info block --------------------------------------------
        XCTAssertEqual(profile.info.stock, fixture["stock"]?.string)
        XCTAssertEqual(profile.info.name, fixture["name"]?.string)
        XCTAssertEqual(profile.info.type.rawValue, fixture["type"]?.string)
        XCTAssertEqual(profile.info.support.rawValue, fixture["support"]?.string)
        XCTAssertEqual(profile.info.stage.rawValue, fixture["stage"]?.string)
        XCTAssertEqual(profile.info.use.rawValue, fixture["use"]?.string)
        XCTAssertEqual(profile.info.antihalation.rawValue, fixture["antihalation"]?.string)
        XCTAssertEqual(profile.info.referenceIlluminant, fixture["reference_illuminant"]?.string)
        XCTAssertEqual(profile.info.viewingIlluminant, fixture["viewing_illuminant"]?.string)

        // --- the data block --------------------------------------------
        try assertMatches(profile.data.wavelengths, fixture["wavelengths"], "film.wavelengths")
        try assertMatches(profile.data.logSensitivity, fixture["log_sensitivity"], "film.log_sensitivity")
        try assertMatches(profile.data.channelDensity, fixture["channel_density"], "film.channel_density")
        try assertMatches(profile.data.baseDensity, fixture["base_density"], "film.base_density")
        try assertMatches(
            profile.data.midscaleNeutralDensity,
            fixture["midscale_neutral_density"],
            "film.midscale_neutral_density"
        )
        try assertMatches(profile.data.logExposure, fixture["log_exposure"], "film.log_exposure")
        try assertMatches(profile.data.densityCurves, fixture["density_curves"], "film.density_curves")
        try assertMatches(
            profile.data.densityCurvesLayers.flatMap { $0 }.flatMap { $0 },
            fixture["density_curves_layers"]?.flatDoubles,
            "film.density_curves_layers"
        )

        // --- the derived curves ----------------------------------------
        try assertMatches(
            DensityCurves.normalized(profile.data.densityCurves).flatMap { $0 },
            fixture["density_curves_normalized"],
            "film.density_curves_normalized"
        )
        let densityMin = try XCTUnwrap(fixture["density_min"]?.doubles)
        let densityMax = try XCTUnwrap(fixture["density_max"]?.doubles)
        for channel in 0..<3 {
            let minimum = Numerics.nanMin(profile.data.densityCurves.map { $0[channel] })
            let maximum = Numerics.nanMax(profile.data.densityCurves.map { $0[channel] })
            XCTAssertEqual(minimum, densityMin[channel], accuracy: tolerance)
            XCTAssertEqual(maximum, densityMax[channel], accuracy: tolerance)
        }
    }

    /// The print profile of the bundle is the profile the upstream engine used.
    func testPrintProfileMatchesTheDigestedData() throws {
        let common = try JSONValue.load(named: "slice1_common")
        let fixture = try XCTUnwrap(common["print"])
        let profile = try ProfileLoader.load(stock: "kodak_portra_endura")

        XCTAssertEqual(profile.info.stock, fixture["stock"]?.string)
        XCTAssertEqual(profile.info.name, fixture["name"]?.string)
        XCTAssertEqual(profile.info.type.rawValue, fixture["type"]?.string)
        XCTAssertEqual(profile.info.support.rawValue, fixture["support"]?.string)
        XCTAssertEqual(profile.info.stage.rawValue, fixture["stage"]?.string)
        XCTAssertEqual(profile.info.referenceIlluminant, fixture["reference_illuminant"]?.string)
        XCTAssertEqual(profile.info.viewingIlluminant, fixture["viewing_illuminant"]?.string)

        try assertMatches(profile.data.wavelengths, fixture["wavelengths"], "print.wavelengths")
        try assertMatches(profile.data.logSensitivity, fixture["log_sensitivity"], "print.log_sensitivity")
        try assertMatches(profile.data.channelDensity, fixture["channel_density"], "print.channel_density")
        try assertMatches(profile.data.baseDensity, fixture["base_density"], "print.base_density")
        try assertMatches(
            profile.data.midscaleNeutralDensity,
            fixture["midscale_neutral_density"],
            "print.midscale_neutral_density"
        )
        try assertMatches(profile.data.logExposure, fixture["log_exposure"], "print.log_exposure")
        try assertMatches(profile.data.densityCurves, fixture["density_curves"], "print.density_curves")
        try assertMatches(
            profile.data.densityCurvesLayers.flatMap { $0 }.flatMap { $0 },
            fixture["density_curves_layers"]?.flatDoubles,
            "print.density_curves_layers"
        )

        // The print stage evaluates the fitted CDF model of the profile.
        let fitted = DensityCurves.evaluateFittedDensity(
            logExposure: profile.data.logExposure,
            model: profile.data.densityCurvesModel,
            profileType: profile.info.type
        )
        try assertMatches(fitted.flatMap { $0 }, fixture["density_curves_fitted"], "print.density_curves_fitted")
    }

    /// The parametric density curve model of the profiles is loaded.
    func testDensityCurvesModelIsLoaded() throws {
        let common = try JSONValue.load(named: "slice1_common")
        for (stock, key) in [("kodak_portra_400", "film"), ("kodak_portra_endura", "print")] {
            let fixture = try XCTUnwrap(common[key]?["density_curves_model"])
            let profile = try ProfileLoader.load(stock: stock)
            let model = profile.data.densityCurvesModel
            XCTAssertEqual(model.modelType, fixture["model_type"]?.string)
            XCTAssertEqual(model.nChannels, 3)
            XCTAssertEqual(model.nLayers, 3)
            try assertMatches(model.centers.flatMap { $0 }, fixture["centers"], "\(key).model.centers")
            try assertMatches(model.amplitudes.flatMap { $0 }, fixture["amplitudes"], "\(key).model.amplitudes")
            try assertMatches(model.sigmas.flatMap { $0 }, fixture["sigmas"], "\(key).model.sigmas")
        }
    }

    /// The `null` entries of the profiles are decoded as `NaN`, exactly like
    /// the upstream `numpy` arrays.
    func testMissingMeasurementsAreDecodedAsNaN() throws {
        let profile = try ProfileLoader.load(stock: "kodak_portra_400")
        let missing = profile.data.baseDensity.filter { $0.isNaN }
        XCTAssertEqual(missing.count, 20)
        let missingChannelDensity = profile.data.channelDensity.flatMap { $0 }.filter { $0.isNaN }
        XCTAssertEqual(missingChannelDensity.count, 22)

        // The upstream replaces the NaN sensitivities with zeros.
        let sensitivity = profile.data.logSensitivity.map { row in
            Numerics.nanToNum(row.map { pow(10.0, $0) })
        }
        XCTAssertFalse(sensitivity.flatMap { $0 }.contains { $0.isNaN })
    }

    /// The digest of the runtime parameters reproduces the digested parameters
    /// of the reference fixtures.
    func testDigestMatchesTheDigestedParameters() throws {
        let fixture = try JSONValue.load(named: "slice1_defaults")
        let params = try XCTUnwrap(fixture["params"])
        let filmParams = try XCTUnwrap(params["film_render"])
        let dirCouplers = try XCTUnwrap(filmParams["dir_couplers"])
        let halation = try XCTUnwrap(filmParams["halation"])

        let profile = try ProfileLoader.load(stock: "kodak_portra_400")
        let digest = Digest.filmRender(for: profile)

        // The DIR coupler inhibition values of a negative stock.
        try assertMatches(
            digest.dirCouplers.gammaSamelayerRGB,
            dirCouplers["gamma_samelayer_rgb"],
            "dir_couplers.gamma_samelayer_rgb"
        )
        try assertMatches(
            digest.dirCouplers.gammaInterlayerRToGB,
            dirCouplers["gamma_interlayer_r_to_gb"],
            "dir_couplers.gamma_interlayer_r_to_gb"
        )
        try assertMatches(
            digest.dirCouplers.gammaInterlayerGToRB,
            dirCouplers["gamma_interlayer_g_to_rb"],
            "dir_couplers.gamma_interlayer_g_to_rb"
        )
        try assertMatches(
            digest.dirCouplers.gammaInterlayerBToRG,
            dirCouplers["gamma_interlayer_b_to_rg"],
            "dir_couplers.gamma_interlayer_b_to_rg"
        )

        // The halation baseline of the stock.
        try assertMatches(
            digest.halation.halationFirstSigmaUM,
            halation["halation_first_sigma_um"],
            "halation.halation_first_sigma_um"
        )
        try assertMatches(
            digest.halation.halationStrength,
            halation["halation_strength"],
            "halation.halation_strength"
        )
    }

    /// The inhibitor matrix of the DIR couplers matches the reference.
    func testDirCouplersMatrixMatchesTheReference() throws {
        let fixture = try JSONValue.load(named: "slice1_defaults")
        let derived = try XCTUnwrap(fixture["derived"])
        let couplers = try XCTUnwrap(derived["dir_couplers"])
        let profile = try ProfileLoader.load(stock: "kodak_portra_400")
        let digest = Digest.filmRender(for: profile)
        var matrix = Couplers.matrix(digest.dirCouplers)
        for row in 0..<3 {
            for column in 0..<3 {
                matrix[row][column] *= digest.dirCouplers.amount
            }
        }
        try assertMatches(matrix.flatMap { $0 }, couplers["matrix"], "dir_couplers.matrix")
    }

    /// The density curves before the DIR couplers match the reference.
    func testDensityCurvesBeforeCouplersMatchTheReference() throws {
        let fixture = try JSONValue.load(named: "slice1_defaults")
        let derived = try XCTUnwrap(fixture["derived"])
        let couplers = try XCTUnwrap(derived["dir_couplers"])
        let profile = try ProfileLoader.load(stock: "kodak_portra_400")
        let digest = Digest.filmRender(for: profile)
        var matrix = Couplers.matrix(digest.dirCouplers)
        for row in 0..<3 {
            for column in 0..<3 {
                matrix[row][column] *= digest.dirCouplers.amount
            }
        }
        let normalized = DensityCurves.normalized(profile.data.densityCurves)
        let curves = Couplers.densityCurvesBeforeCouplers(
            densityCurves: normalized,
            logExposure: profile.data.logExposure,
            matrix: matrix,
            positive: false
        )
        try assertMatches(
            curves.flatMap { $0 },
            couplers["density_curves_before_couplers"],
            "dir_couplers.density_curves_before_couplers"
        )
    }
}
