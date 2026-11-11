//
//  MetalSourceTests.swift
//  light suffer胶片 — iOS app
//
//  The static validation of the Metal port.
//
//  The Metal kernels cannot run on Linux (there is no GPU here), but the
//  **sources** can be checked: the test reads the Metal Shading Language
//  source and the Swift sources of the Metal target, and verifies that
//
//  * every kernel name of the shading language is unique,
//  * every kernel the Swift code looks up exists exactly once in the
//    shading language,
//  * every kernel binds its buffers with the indices `0 … n - 1` (the
//    Swift side binds them in order),
//  * the structures the shaders read have **exactly** the layout of their
//    Swift counterparts (the same members, in the same order, with the
//    same widths),
//  * the shading language uses no `double` (the GPU path is `Float32`).
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest

final class MetalSourceTests: XCTestCase {

    // MARK: - The helpers

    /// The directory of the sources of the package.
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FilmPhysicsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // the root of the package
    }

    /// The source of the Metal shading language.
    private static var shaderSource: String {
        let url = packageRoot
            .appendingPathComponent("Sources/FilmPhysicsMetal/Shaders/FilmShaders.metal")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The source of a file of the Metal target.
    private static func source(of relativePath: String) -> String {
        let url = packageRoot.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// The names of the kernels of the shading language, in the order of the
    /// source.
    private static func kernelNames(in source: String) -> [String] {
        let pattern = try? NSRegularExpression(
            pattern: #"kernel\s+void\s+(\w+)\s*\("#
        )
        guard let pattern else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return pattern.matches(in: source, range: range).compactMap { match in
            guard let swiftRange = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[swiftRange])
        }
    }

    /// The names of the kernels the Swift code looks up.
    ///
    /// The backend dispatches its passes by name (`dispatch(encoder,
    /// "filmXXX", …)`) and looks its functions up by name (`makeFunction(name:)`).
    private static func dispatchedKernelNames(in source: String) -> [String] {
        let pattern = try? NSRegularExpression(pattern: #""(film[A-Za-z0-9_]+)""#)
        guard let pattern else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return pattern.matches(in: source, range: range).compactMap { match in
            guard let swiftRange = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[swiftRange])
        }
    }

    /// The members of a structure of the shading language.
    ///
    /// - Returns: the members, as `(type, name)` pairs, or `nil` when the
    ///   structure is not in the source.
    private static func members(
        ofStructure name: String, in source: String
    ) -> [(type: String, name: String)]? {
        let pattern = try? NSRegularExpression(
            pattern: #"struct\s+"# + name + #"\s*\{([^}]*)\}"#
        )
        guard let pattern else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        guard let match = pattern.firstMatch(in: source, range: range),
              let bodyRange = Range(match.range(at: 1), in: source) else { return nil }
        var members: [(type: String, name: String)] = []
        for line in source[bodyRange].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }
            let parts = trimmed.split(separator: ";").first.map(String.init) ?? String(trimmed)
            let fields = parts.split(separator: " ").map(String.init)
            guard fields.count >= 2 else { continue }
            members.append((type: fields[0], name: fields[1]))
        }
        return members
    }

    /// The members of a structure of the Swift source of the Metal target.
    private static func swiftMembers(
        ofStructure name: String, in source: String
    ) -> [(type: String, name: String)]? {
        let pattern = try? NSRegularExpression(
            pattern: #"struct\s+"# + name + #"\s*(:\s*[^\{]*)?\s*\{"#
        )
        guard let pattern else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        guard let match = pattern.firstMatch(in: source, range: range),
              let bodyRange = Range(match.range, in: source) else { return nil }
        // The body of the structure: up to the closing brace at the start of
        // a line.
        let body = source[bodyRange.upperBound...]
        var depth = 1
        var end = body.startIndex
        var index = body.startIndex
        while index < body.endIndex {
            if body[index] == "{" { depth += 1 }
            if body[index] == "}" {
                depth -= 1
                if depth == 0 { end = index; break }
            }
            index = body.index(after: index)
        }
        var members: [(type: String, name: String)] = []
        for line in body[body.startIndex..<end].split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("var ") else { continue }
            let declaration = trimmed.dropFirst(4)
            let parts = declaration.split(separator: "=").first.map(String.init)
                ?? String(declaration)
            let fields = parts.split(separator: ":").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 2 else { continue }
            members.append((type: fields[1], name: fields[0]))
        }
        return members
    }

    /// The buffer indices of a kernel of the shading language.
    private static func bufferIndices(ofKernel name: String, in source: String) -> [Int]? {
        let pattern = try? NSRegularExpression(
            pattern: #"kernel\s+void\s+"# + name + #"\s*\(([^)]*)\)"#
        )
        guard let pattern else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        guard let match = pattern.firstMatch(in: source, range: range),
              let bodyRange = Range(match.range(at: 1), in: source) else { return nil }
        let indexPattern = try? NSRegularExpression(pattern: #"\[\[buffer\((\d+)\)\]\]"#)
        guard let indexPattern else { return nil }
        let indices = indexPattern.matches(in: String(source[bodyRange]), range: range)
            .compactMap { match -> Int? in
                guard let swiftRange = Range(match.range(at: 1), in: source) else { return nil }
                return Int(source[swiftRange])
            }
        return indices.sorted()
    }

    // MARK: - The tests

    /// The kernel names of the shading language are unique and every kernel
    /// the Swift code looks up exists.
    func testTheKernelNamesAreUniqueAndComplete() throws {
        let shader = Self.shaderSource
        XCTAssertFalse(shader.isEmpty, "the shading language source was found")
        let kernels = Self.kernelNames(in: shader)
        XCTAssertFalse(kernels.isEmpty, "the shading language holds kernels")

        // The names are unique.
        var seen = Set<String>()
        for name in kernels {
            XCTAssertTrue(seen.insert(name).inserted, "the kernel '\(name)' is declared twice")
        }

        // Every kernel the Swift code dispatches exists exactly once.
        let backend = Self.source(of: "Sources/FilmPhysicsMetal/MetalBackend.swift")
        let plan = Self.source(of: "Sources/FilmPhysicsMetal/MetalPlan.swift")
        let dispatched = Set(Self.dispatchedKernelNames(in: backend))
            .union(Self.dispatchedKernelNames(in: plan))
        XCTAssertFalse(dispatched.isEmpty, "the backend dispatches kernels")
        for name in dispatched.sorted() {
            let count = kernels.filter { $0 == name }.count
            XCTAssertEqual(count, 1, "the kernel '\(name)' is declared \(count) times")
        }

        // Every kernel of the shading language is dispatched (an unused
        // kernel is dead code, and it is a hint that a pass was forgotten).
        for name in kernels {
            XCTAssertTrue(
                dispatched.contains(name),
                "the kernel '\(name)' is never dispatched"
            )
        }
        print("[metal source] \(kernels.count) kernels, \(dispatched.count) dispatched")
    }

    /// The buffers of every kernel are bound with the indices `0 … n - 1`.
    func testTheBufferIndicesOfTheKernelsAreContiguous() throws {
        let shader = Self.shaderSource
        for name in Self.kernelNames(in: shader) {
            guard let indices = Self.bufferIndices(ofKernel: name, in: shader) else {
                XCTFail("the kernel '\(name)' was not found")
                continue
            }
            XCTAssertEqual(
                indices, Array(0..<indices.count),
                "the kernel '\(name)' binds its buffers with the indices \(indices)"
            )
        }
    }

    /// The structures of the shaders have the layout of their Swift
    /// counterparts.
    func testTheStructuresOfTheShadersMatchTheSwiftOnes() throws {
        let shader = Self.shaderSource
        let plan = Self.source(of: "Sources/FilmPhysicsMetal/MetalPlan.swift")
        XCTAssertFalse(plan.isEmpty, "the source of the Metal target was found")

        let structures = [
            "FilmPlanParams", "FilmBlurParams", "FilmCombineParams",
            "FilmGrainParams", "FilmGrainClumpingParams", "FilmGlareParams",
        ]
        for name in structures {
            guard let metal = Self.members(ofStructure: name, in: shader) else {
                XCTFail("the structure '\(name)' is not in the shading language")
                continue
            }
            guard let swift = Self.swiftMembers(ofStructure: name, in: plan) else {
                XCTFail("the structure '\(name)' is not in the Swift source")
                continue
            }
            XCTAssertEqual(
                metal.count, swift.count,
                "the structure '\(name)' has \(metal.count) members in the shading "
                    + "language and \(swift.count) in Swift"
            )
            for index in 0..<min(metal.count, swift.count) {
                XCTAssertEqual(
                    metal[index].name, swift[index].name,
                    "the member \(index) of the structure '\(name)'"
                )
                let metalType = metal[index].type == "uint" ? "UInt32" : "Float"
                XCTAssertEqual(
                    metalType, swift[index].type,
                    "the type of the member '\(metal[index].name)' of the structure '\(name)'"
                )
            }
        }
    }

    /// The shading language uses no double precision.
    func testTheShadingLanguageUsesNoDouble() throws {
        let shader = Self.shaderSource
        // The word `double` must not appear (the comments of the source
        // mention it, so the check looks at the code only: the lines that
        // are not comments).
        for (number, line) in shader.split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }
            XCTAssertFalse(
                trimmed.contains("double"),
                "the line \(number + 1) of the shading language uses a double: \(trimmed)"
            )
        }
    }
}
