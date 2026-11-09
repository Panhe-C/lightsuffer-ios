//
//  FilmPhysicsTests.swift
//  light suffer胶片 — iOS app
//
//  Smoke tests for the package scaffold and the reference fixtures that the
//  Swift port is validated against.
//

import XCTest
@testable import FilmPhysics

final class FilmPhysicsTests: XCTestCase {

    // MARK: - package metadata

    func testVersionIsNotEmpty() {
        XCTAssertFalse(FilmPhysics.version.isEmpty)
        XCTAssertEqual(FilmPhysics.upstreamProject, "spektrafilm")
        XCTAssertEqual(FilmPhysics.upstreamCommit, "3bb2c2d")
        XCTAssertEqual(FilmPhysics.credit, "film modeling powered by spektrafilm")
    }

    // MARK: - resource lookup

    /// Finds a bundled resource by name, whatever the layout SwiftPM chose on
    /// this platform (the directory structure of copied resources differs
    /// slightly between Linux and Apple platforms).
    private func resourceURL(named name: String, extension ext: String) -> URL? {
        for subdirectory in [
            nil, "profiles", "Resources/profiles", "Fixtures", "Resources/Fixtures",
        ] {
            if let url = Bundle.module.url(
                forResource: name, withExtension: ext, subdirectory: subdirectory
            ) {
                return url
            }
        }
        for root in [Bundle.module.resourceURL, Bundle.module.bundleURL].compactMap({ $0 }) {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in enumerator
            where url.lastPathComponent == "\(name).\(ext)" {
                return url
            }
        }
        return nil
    }

    // MARK: - bundled profiles

    func testBundledProfilesArePresent() throws {
        for stock in ["kodak_portra_400", "kodak_portra_endura"] {
            let url = try XCTUnwrap(
                FilmPhysics.profileURL(stock: stock),
                "missing bundled profile \(stock)"
            )
            let data = try Data(contentsOf: url)
            let object = try JSONSerialization.jsonObject(with: data)
            let json = try XCTUnwrap(object as? [String: Any])

            XCTAssertEqual(json["info"] as? [String: Any] != nil, true)

            let profile = try XCTUnwrap(json["data"] as? [String: Any])
            for key in [
                "wavelengths", "log_sensitivity", "channel_density", "base_density",
                "log_exposure", "density_curves", "density_curves_layers",
            ] {
                XCTAssertNotNil(profile[key], "profile \(stock) is missing \(key)")
            }
        }
    }

    func testProfileChangelogIsPresent() throws {
        let url = try XCTUnwrap(
            FilmPhysics.profileResourceURL(name: "CHANGELOG", extension: "txt"),
            "missing profile CHANGELOG.txt"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("CC BY-SA 4.0"))
        XCTAssertTrue(text.contains("3bb2c2d"))
    }

    // MARK: - reference fixtures

    /// Loads a fixture JSON file (name without the `.json` extension).
    private func loadFixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(
            resourceURL(named: name, extension: "json"),
            "missing fixture \(name).json"
        )
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    func testCommonFixtureHasTheSharedData() throws {
        let common = try loadFixture("slice1_common")
        XCTAssertNotNil(common["film"])
        XCTAssertNotNil(common["print"])
        XCTAssertNotNil(common["spectral"])
        XCTAssertNotNil(common["illuminants"])
        XCTAssertNotNil(common["color"])
        XCTAssertNotNil(common["hanatos2025_tc_lut"])

        let spectral = try XCTUnwrap(common["spectral"] as? [String: Any])
        let wavelengths = try XCTUnwrap(doubles(spectral["wavelengths"]))
        XCTAssertEqual(wavelengths.count, 81)
        XCTAssertEqual(wavelengths.first, 380)
        XCTAssertEqual(wavelengths.last, 780)
    }

    /// Flattens a (possibly nested) JSON array of numbers into `[Double]`.
    ///
    /// `JSONSerialization` hands back `NSNumber`, so a plain `as? [Double]`
    /// cast would fail.
    private func doubles(_ value: Any?) -> [Double]? {
        guard let array = value as? [Any] else { return nil }
        var out: [Double] = []
        for element in array {
            if let number = element as? NSNumber {
                out.append(number.doubleValue)
            } else if let nested = element as? [Any] {
                guard let flat = doubles(nested) else { return nil }
                out.append(contentsOf: flat)
            } else {
                return nil
            }
        }
        return out
    }

    func testCaseFixturesCarryEveryTap() throws {
        let cases = [
            "slice1_defaults",
            "slice1_camera_ev_plus1",
            "slice1_print_exposure_and_filter_shifts",
            "slice1_dir_couplers_inactive",
        ]
        let taps = [
            "rgb_in", "log_e_film", "cmy_film", "log_e_print", "cmy_print", "rgb_out",
        ]
        for name in cases {
            let fixture = try loadFixture(name)
            let tapDict = try XCTUnwrap(fixture["taps"] as? [String: Any])
            for tap in taps {
                let values = try XCTUnwrap(
                    doubles(tapDict[tap]), "\(name): missing tap \(tap)"
                )
                XCTAssertEqual(values.count, 12 * 12 * 3, "\(name): wrong tap size for \(tap)")
            }
            XCTAssertNotNil(fixture["params"])
            XCTAssertNotNil(fixture["derived"])
        }
    }
}
