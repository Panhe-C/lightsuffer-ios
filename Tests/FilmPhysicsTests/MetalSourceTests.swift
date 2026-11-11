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
//  * the shading language uses no `double` (the GPU path is `Float32`),
//  * the shading language uses no **keyword** as an identifier (a keyword
//    is a reserved word of the language: `kernel`, `constant`, `device`,
//    `threadgroup`, … — the compiler rejects them),
//  * the attributes of the kernels (`[[…]]`) belong to the **whitelist**
//    of the valid Metal attributes (a typo, e.g. `[[threads_per_group]]`,
//    is a compile error, not a warning).
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
        // The range must be the range of the string the expression is run
        // on: the source of the kernel is a *substring* of the file, and
        // the range of the file would be out of its bounds (the crash of
        // the macOS run).
        let body = String(source[bodyRange])
        let bodySearchRange = NSRange(body.startIndex..., in: body)
        let indices = indexPattern.matches(in: body, range: bodySearchRange)
            .compactMap { match -> Int? in
                guard let swiftRange = Range(match.range(at: 1), in: body) else { return nil }
                return Int(body[swiftRange])
            }
        return indices.sorted()
    }

    // MARK: - The lexical analysis of the shading language

    /// The keywords of the Metal shading language.
    ///
    /// A keyword is a reserved word of the language: it cannot be the name
    /// of a variable, of a parameter, of a function or of a member.  The
    /// Metal compiler rejects it (`invalid parameter name: 'kernel' is a
    /// keyword`).
    private static let metalKeywords: Set<String> = [
        "kernel", "vertex", "fragment", "constant", "device", "threadgroup",
        "thread", "sampler", "texture", "bool", "break", "case", "char",
        "class", "const", "continue", "default", "do", "double", "else",
        "enum", "extern", "float", "for", "goto", "half", "if", "inline",
        "int", "long", "namespace", "new", "operator", "private",
        "protected", "public", "register", "return", "short", "signed",
        "sizeof", "static", "struct", "switch", "typedef", "union",
        "unsigned", "using", "virtual", "void", "volatile", "while",
    ]

    /// The words that introduce a **name** in the shading language.
    ///
    /// When one of them is followed by a keyword, the keyword is used as a
    /// name: it is a compile error.
    private static let metalTypeWords: Set<String> = [
        "bool", "char", "float", "float2", "float3", "float4", "half",
        "half2", "half3", "half4", "int", "int2", "int3", "int4", "long",
        "short", "size_t", "uint", "uint2", "uint3", "uint4", "void",
    ]

    /// The words that are skipped when the analysis looks for the type of
    /// a name (the qualifiers and the pointers).
    private static let metalQualifierWords: Set<String> = [
        "const", "device", "constant", "threadgroup", "inline", "static",
        "volatile", "unsigned", "signed",
    ]

    /// The valid attributes of the Metal shading language.
    ///
    /// The whitelist is the one of the compute kernels (the buffer, the
    /// texture and the sampler bindings, and the attributes of the
    /// position of the thread); the attributes of the graphics pipeline
    /// are listed too, for the sake of the completeness.
    private static let metalAttributes: Set<String> = [
        "buffer", "texture", "sampler", "id", "color",
        "thread_position_in_grid", "thread_position_in_threadgroup",
        "threadgroup_position_in_grid", "thread_index_in_threadgroup",
        "threads_per_threadgroup", "threads_per_grid",
        "position", "point_size", "stage_in", "stage_out", "vertex_id",
        "instance_id", "primitive_id", "base_vertex", "base_instance",
    ]

    /// The source of the shading language without its comments.
    ///
    /// The analysis of the keywords and of the attributes looks at the
    /// **code** only: the comments of the source mention the keywords of
    /// the language (e.g. `the 'reflect' boundary`), and they must not be
    /// taken for code.
    ///
    /// - Parameter source: the source of the shading language.
    /// - Returns: the source without its comments (the line breaks are
    ///   kept, so that the line numbers stay right).
    private static func code(of source: String) -> String {
        var output = ""
        var index = source.startIndex
        var inBlockComment = false
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if inBlockComment {
                if character == "*", next < source.endIndex, source[next] == "/" {
                    inBlockComment = false
                    index = source.index(after: next)
                    continue
                }
                if character == "\n" { output.append(character) }
                index = next
                continue
            }
            if character == "/", next < source.endIndex {
                if source[next] == "/" {
                    while index < source.endIndex, source[index] != "\n" {
                        index = source.index(after: index)
                    }
                    continue
                }
                if source[next] == "*" {
                    inBlockComment = true
                    index = source.index(after: next)
                    continue
                }
            }
            output.append(character)
            index = next
        }
        return output
    }

    /// The tokens of a piece of code.
    ///
    /// A token is either an identifier (a letter, a digit or an
    /// underscore, followed by letters, digits or underscores) or a single
    /// symbol.
    ///
    /// - Parameter code: the code to tokenise.
    /// - Returns: the tokens of the code.
    private static func tokens(of code: String) -> [String] {
        var tokens: [String] = []
        var index = code.startIndex
        while index < code.endIndex {
            let character = code[index]
            if character.isWhitespace {
                index = code.index(after: index)
                continue
            }
            if character.isLetter || character == "_" {
                var end = index
                while end < code.endIndex {
                    let next = code[end]
                    if next.isLetter || next.isNumber || next == "_" {
                        end = code.index(after: end)
                    } else {
                        break
                    }
                }
                tokens.append(String(code[index..<end]))
                index = end
                continue
            }
            if character.isNumber {
                var end = index
                while end < code.endIndex, code[end].isNumber || code[end] == "." {
                    end = code.index(after: end)
                }
                tokens.append(String(code[index..<end]))
                index = end
                continue
            }
            tokens.append(String(character))
            index = code.index(after: index)
        }
        return tokens
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

    /// The shading language uses no keyword as an identifier.
    ///
    /// A keyword of the Metal shading language is a reserved word: it
    /// cannot be the name of a variable, of a parameter, of a function or
    /// of a member.  The compiler rejects it (`invalid parameter name:
    /// 'kernel' is a keyword`), and the error shows up only on a machine
    /// with a Metal compiler — so it is checked here, statically.
    func testTheShadingLanguageUsesNoKeywordAsAnIdentifier() throws {
        let code = Self.code(of: Self.shaderSource)
        let tokens = Self.tokens(of: code)
        var reported: Set<String> = []

        for (index, token) in tokens.enumerated() where Self.metalKeywords.contains(token) {
            // The token before the keyword is looked for, through the
            // qualifiers and the pointers: when it is a type, the keyword
            // is used as a name.
            var previous = index - 1
            while previous >= 0,
                  Self.metalQualifierWords.contains(tokens[previous])
                    || tokens[previous] == "*" || tokens[previous] == "&" {
                previous -= 1
            }
            guard previous >= 0 else { continue }
            let before = tokens[previous]
            let isAName = Self.metalTypeWords.contains(before) || before == "."
            guard isAName else { continue }
            guard reported.insert(token).inserted else { continue }
            XCTFail(
                "the shading language uses the keyword '\(token)' as an "
                    + "identifier (after '\(before)'): the Metal compiler "
                    + "rejects it (invalid parameter name)"
            )
        }
    }

    /// The attributes of the shading language are valid Metal attributes.
    ///
    /// A typo in an attribute (`[[threads_per_group]]` instead of
    /// `[[threads_per_threadgroup]]`) is a compile error of the Metal
    /// compiler, and it is only seen on a machine with Metal — so it is
    /// checked here, statically, against the whitelist of the valid
    /// attributes.
    func testTheAttributesOfTheShadingLanguageAreValid() throws {
        let code = Self.code(of: Self.shaderSource)
        let pattern = try? NSRegularExpression(pattern: #"\[\[([A-Za-z_][A-Za-z0-9_]*)"#)
        guard let pattern else {
            XCTFail("the pattern of the attributes could not be built")
            return
        }
        let range = NSRange(code.startIndex..., in: code)
        let attributes = pattern.matches(in: code, range: range).compactMap { match -> String? in
            guard let swiftRange = Range(match.range(at: 1), in: code) else { return nil }
            return String(code[swiftRange])
        }
        XCTAssertFalse(attributes.isEmpty, "the shading language holds attributes")
        for attribute in attributes {
            XCTAssertTrue(
                Self.metalAttributes.contains(attribute),
                "the attribute '\(attribute)' of the shading language is not a "
                    + "valid Metal attribute"
            )
        }
    }

    /// The loops of the shading language are bounded.
    ///
    /// A loop whose bound comes from a parameter (a radius, a number of
    /// samples, a number of threads) can run for billions of iterations —
    /// or for ever, when the bound is zero (a stride of zero in the
    /// reduction) — and hang the GPU.  The test checks that every `while`
    /// of the shading language compares its condition with a bound, and
    /// that every `for` loop has a limit.
    func testTheLoopsOfTheShadingLanguageAreBounded() throws {
        let code = Self.code(of: Self.shaderSource)
        let range = NSRange(code.startIndex..., in: code)

        // The `while` loops (the `do { … } while (…)` loops included).
        let whilePattern = try? NSRegularExpression(pattern: #"while\s*\(([^)]*)\)"#)
        guard let whilePattern else {
            XCTFail("the pattern of the while loops could not be built")
            return
        }
        let whiles = whilePattern.matches(in: code, range: range)
        XCTAssertFalse(whiles.isEmpty, "the shading language holds while loops")
        for match in whiles {
            guard let swiftRange = Range(match.range(at: 1), in: code) else { continue }
            let condition = String(code[swiftRange])
            XCTAssertTrue(
                condition.contains("<") || condition.contains(">"),
                "the while loop '\(condition)' of the shading language has no bound"
            )
        }

        // The `for` loops.
        let forPattern = try? NSRegularExpression(pattern: #"for\s*\(([^)]*)\)"#)
        guard let forPattern else {
            XCTFail("the pattern of the for loops could not be built")
            return
        }
        let fors = forPattern.matches(in: code, range: range)
        XCTAssertFalse(fors.isEmpty, "the shading language holds for loops")
        for match in fors {
            guard let swiftRange = Range(match.range(at: 1), in: code) else { continue }
            let header = String(code[swiftRange])
            let parts = header.split(separator: ";")
            XCTAssertEqual(
                parts.count, 3,
                "the for loop '\(header)' of the shading language has no limit"
            )
            if parts.count == 3 {
                XCTAssertTrue(
                    parts[1].contains("<") || parts[1].contains("!="),
                    "the for loop '\(header)' of the shading language has no limit"
                )
            }
        }
    }

    /// The bound of the radius of the convolutions is the same on the two
    /// sides.
    ///
    /// The shading language clamps the radius of the convolutions
    /// (`FILM_MAX_BLUR_RADIUS`) and the Swift side builds the kernels
    /// with the same bound (`MetalKernels.maxBlurRadius`): the two must
    /// agree, or the kernels would read outside of the buffer of the
    /// weights.
    func testTheBoundOfTheRadiusOfTheConvolutionsIsTheSameOnTheTwoSides() throws {
        let shader = Self.shaderSource
        let plan = Self.source(of: "Sources/FilmPhysicsMetal/MetalPlan.swift")
        let metalPattern = try? NSRegularExpression(
            pattern: #"#define\s+FILM_MAX_BLUR_RADIUS\s+(\d+)"#
        )
        let swiftPattern = try? NSRegularExpression(
            pattern: #"maxBlurRadius\s*=\s*(\d+)"#
        )
        let range = NSRange(shader.startIndex..., in: shader)
        guard let metalPattern, let swiftPattern,
              let metalMatch = metalPattern.firstMatch(in: shader, range: range),
              let metalRange = Range(metalMatch.range(at: 1), in: shader) else {
            XCTFail("the bound of the radius is not in the shading language")
            return
        }
        let planRange = NSRange(plan.startIndex..., in: plan)
        guard let swiftMatch = swiftPattern.firstMatch(in: plan, range: planRange),
              let swiftRange = Range(swiftMatch.range(at: 1), in: plan) else {
            XCTFail("the bound of the radius is not in the Swift source")
            return
        }
        XCTAssertEqual(
            Int(shader[metalRange]), Int(plan[swiftRange]),
            "the bound of the radius of the convolutions is not the same on "
                + "the two sides"
        )
    }
}
