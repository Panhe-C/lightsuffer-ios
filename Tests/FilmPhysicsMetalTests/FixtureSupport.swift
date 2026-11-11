//
//  FixtureSupport.swift
//  light suffer胶片 — iOS app
//
//  A minimal JSON reader for the reference fixtures.
//
//  This file is a copy of the reader of the CPU test target
//  (`Tests/FilmPhysicsTests/FixtureSupport.swift`): the Metal test target
//  reads the very same fixtures, but it locates them **by path** (the
//  fixtures live in the bundle of the CPU test target, which the Metal test
//  target cannot copy from).
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

#if canImport(Metal)
import Foundation
import XCTest

/// A JSON tree, used to navigate the reference fixtures in the tests.
///
/// The fixtures store a `NaN` as a JSON `null`, so ``number(_:)`` maps a
/// `null` onto `Double.nan`.
enum JSONValue {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses a JSON document.
    static func parse(_ data: Data) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: data)
        return try convert(object)
    }

    /// Loads a JSON document from the test bundle.
    static func load(named name: String) throws -> JSONValue {
        let url = try FixtureSupport.resourceURL(named: name, extension: "json")
        return try parse(Data(contentsOf: url))
    }

    private static func convert(_ object: Any) throws -> JSONValue {
        switch object {
        case let value as NSNumber:
            // JSONSerialization encodes the booleans as a `char` NSNumber.
            if String(cString: value.objCType) == "c" {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        case let value as String:
            return .string(value)
        case is NSNull:
            return .null
        case let value as [Any]:
            return .array(try value.map(convert))
        case let value as [String: Any]:
            var object: [String: JSONValue] = [:]
            for (key, element) in value {
                object[key] = try convert(element)
            }
            return .object(object)
        default:
            throw FixtureError.unexpectedJSON(String(describing: object))
        }
    }

    // MARK: - Accessors

    subscript(key: String) -> JSONValue? {
        guard case let .object(object) = self else { return nil }
        return object[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard case let .array(array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// The value as a number; a `null` becomes `NaN`.
    var double: Double? {
        switch self {
        case let .number(value): return value
        case .null: return .nan
        default: return nil
        }
    }

    /// The value as an array of numbers; a `null` becomes `NaN`.
    var doubles: [Double]? {
        guard case let .array(array) = self else { return nil }
        var values: [Double] = []
        values.reserveCapacity(array.count)
        for element in array {
            guard let value = element.double else { return nil }
            values.append(value)
        }
        return values
    }

    /// The value as an array of JSON values.
    var arrayElements: [JSONValue]? {
        guard case let .array(array) = self else { return nil }
        return array
    }

    /// The value as a nested array of numbers.
    var doubleRows: [[Double]]? {
        guard case let .array(array) = self else { return nil }
        var rows: [[Double]] = []
        rows.reserveCapacity(array.count)
        for element in array {
            guard let row = element.doubles else { return nil }
            rows.append(row)
        }
        return rows
    }

    /// The value as a flat array of numbers, flattening the nested arrays.
    var flatDoubles: [Double]? {
        guard case let .array(array) = self else { return nil }
        var values: [Double] = []
        for element in array {
            if let number = element.double {
                values.append(number)
            } else if let nested = element.flatDoubles {
                values.append(contentsOf: nested)
            } else {
                return nil
            }
        }
        return values
    }

    /// The value as a string.
    var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    /// The value as a boolean.
    var bool: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    /// The value as an integer.
    var int: Int? {
        guard case let .number(value) = self else { return nil }
        return Int(value)
    }
}

/// The errors of the fixture reader.
enum FixtureError: Error, CustomStringConvertible {
    case resourceNotFound(String)
    case unexpectedJSON(String)

    var description: String {
        switch self {
        case let .resourceNotFound(name):
            return "the fixture resource '\(name)' was not found"
        case let .unexpectedJSON(description):
            return "unexpected JSON content: \(description)"
        }
    }
}

    /// Locates the resources of the test bundle.
    enum FixtureSupport {

    /// Finds a bundled resource by name, whatever the layout SwiftPM chose on
    /// this platform.
    static func resourceURL(named name: String, extension ext: String) throws -> URL {
        // The fixtures live in the directory of the CPU test target; the path
        // is resolved from the location of this file, so that the tests work
        // both in the build directory and in the CI.
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FilmPhysicsTests")
            .appendingPathComponent("Fixtures")
        let url = directory.appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        throw FixtureError.resourceNotFound("\(name).\(ext)")
    }
}

// MARK: - Comparison helpers

/// The maximum absolute difference between two arrays.
///
/// Two `NaN` values count as equal, the upstream profiles store the missing
/// measurements as `NaN`.
func maxAbsoluteDifference(_ lhs: [Double], _ rhs: [Double]) -> Double {
    guard lhs.count == rhs.count else { return .infinity }
    var maximum = 0.0
    for index in 0..<lhs.count {
        if lhs[index].isNaN && rhs[index].isNaN { continue }
        let difference = abs(lhs[index] - rhs[index])
        if difference.isNaN { return .nan }
        maximum = Swift.max(maximum, difference)
    }
    return maximum
}

/// The maximum absolute difference between two nested arrays.
func maxAbsoluteDifference(_ lhs: [[Double]], _ rhs: [[Double]]) -> Double {
    guard lhs.count == rhs.count else { return .infinity }
    var maximum = 0.0
    for index in 0..<lhs.count {
        maximum = Swift.max(maximum, maxAbsoluteDifference(lhs[index], rhs[index]))
    }
    return maximum
}

/// The mean absolute difference between two arrays.
func meanAbsoluteDifference(_ lhs: [Double], _ rhs: [Double]) -> Double {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return .nan }
    var sum = 0.0
    for index in 0..<lhs.count {
        sum += abs(lhs[index] - rhs[index])
    }
    return sum / Double(lhs.count)
}

#endif
