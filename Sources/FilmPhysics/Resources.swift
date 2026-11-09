//
//  Resources.swift
//  light suffer胶片 — iOS app
//
//  Access to the bundled upstream resources: the hanatos 2025 irradiance
//  spectra table, the CIE 1931 2° colour matching functions, the standard
//  illuminant spectra and the neutral print filter database.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The errors thrown while loading the bundled resources.
public enum ResourceError: Error, CustomStringConvertible {
    /// A resource is missing from the bundle.
    case notFound(String)
    /// A resource has an unexpected shape.
    case invalidShape(String)

    public var description: String {
        switch self {
        case let .notFound(name):
            return "the resource '\(name)' is not bundled with the package"
        case let .invalidShape(reason):
            return "invalid bundled resource: \(reason)"
        }
    }
}

/// The upstream data bundled with the package.
///
/// The resources are packed by `tools/pack_resources.py`; their provenance is
/// documented in `Sources/FilmPhysics/Resources/CHANGELOG.txt`.
///
/// | File | Shape | Content |
/// |---|---|---|
/// | `spectral/irradiance_xy_tc.f16` | 192 × 192 × 81 (float16) | the hanatos 2025 irradiance spectra |
/// | `spectral/cmfs_cie1931_2deg.f32` | 81 × 3 (float32) | the CIE 1931 2° colour matching functions |
/// | `spectral/illuminants.f32` | 6 × 81 (float32) | TH-KG3, D55, D50, D65, T and K75P |
/// | `filters/neutral_print_filters.json` | JSON | the neutral print filter database |
public enum Resources {

    /// The number of wavelength samples of the spectral shape
    /// (380…780 nm in 5 nm steps).
    public static let wavelengthCount = 81

    /// The size of the hanatos 2025 tc grid.
    public static let tcGridSize = 192

    /// The labels of the bundled illuminants, in the order they are packed.
    ///
    /// | Label | Role |
    /// |---|---|
    /// | `TH-KG3` | the enlarger lamp and the reference illuminant of the papers |
    /// | `D55` | the reference illuminant of the films |
    /// | `D50` | the viewing illuminant of the films and of the papers |
    /// | `D65` | the white point of the sRGB output colourspace |
    /// | `T` | the incandescent reference illuminant of the Kodak Vision3 200T / 500T |
    /// | `K75P` | the Kinoton viewing illuminant of the Kodak 2383 / 2393 print films |
    public static let illuminantLabels = ["TH-KG3", "D55", "D50", "D65", "T", "K75P"]

    // MARK: - Caching

    /// The lazily loaded resources.
    ///
    /// The hanatos 2025 irradiance table holds three million values (12 MiB
    /// as `Float`); decoding it for every pipeline would dominate the run
    /// time of a catalogue sweep, so the decoded resources are cached.
    private static let storage = Storage()

    private final class Storage {
        private let lock = NSLock()
        private var spectraCache: [Float]?
        private var colourMatchingFunctionsCache: [[Double]]?
        private var illuminantsCache: [String: [Double]]?
        private var neutralPrintFiltersCache: [String: [String: [String: [Double]]]]?

        func spectra() throws -> [Float] {
            lock.lock()
            if let cached = spectraCache { lock.unlock(); return cached }
            lock.unlock()
            let decoded = try Resources.decodeSpectra()
            lock.lock()
            spectraCache = decoded
            lock.unlock()
            return decoded
        }

        func colourMatchingFunctions() throws -> [[Double]] {
            lock.lock()
            if let cached = colourMatchingFunctionsCache { lock.unlock(); return cached }
            lock.unlock()
            let decoded = try Resources.decodeColourMatchingFunctions()
            lock.lock()
            colourMatchingFunctionsCache = decoded
            lock.unlock()
            return decoded
        }

        func illuminants() throws -> [String: [Double]] {
            lock.lock()
            if let cached = illuminantsCache { lock.unlock(); return cached }
            lock.unlock()
            let decoded = try Resources.decodeIlluminants()
            lock.lock()
            illuminantsCache = decoded
            lock.unlock()
            return decoded
        }

        func neutralPrintFilters() throws -> [String: [String: [String: [Double]]]] {
            lock.lock()
            if let cached = neutralPrintFiltersCache { lock.unlock(); return cached }
            lock.unlock()
            let decoded = try Resources.decodeNeutralPrintFilters()
            lock.lock()
            neutralPrintFiltersCache = decoded
            lock.unlock()
            return decoded
        }
    }

    // MARK: - Locating

    /// Finds a bundled resource by name, whatever the layout SwiftPM chose.
    private static func url(named name: String, extension ext: String) -> URL? {
        for subdirectory in [nil, "spectral", "filters", "Resources/spectral", "Resources/filters"] {
            if let url = FilmPhysics.resourcesBundle.url(
                forResource: name, withExtension: ext, subdirectory: subdirectory
            ) {
                return url
            }
        }
        for root in [FilmPhysics.resourcesBundle.resourceURL, FilmPhysics.resourcesBundle.bundleURL]
            .compactMap({ $0 })
        {
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

    // MARK: - Binary decoding

    /// Decodes a little-endian binary file of 32 bit floats.
    private static func float32Data(named name: String) throws -> [Float] {
        guard let url = url(named: name, extension: "f32") else {
            throw ResourceError.notFound(name)
        }
        let data = try Data(contentsOf: url)
        let count = data.count / 4
        var values = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let source = raw.bindMemory(to: UInt8.self)
            for index in 0..<count {
                let offset = index * 4
                let bits = UInt32(source[offset])
                    | (UInt32(source[offset + 1]) << 8)
                    | (UInt32(source[offset + 2]) << 16)
                    | (UInt32(source[offset + 3]) << 24)
                values[index] = Float(bitPattern: bits)
            }
        }
        return values
    }

    /// Decodes a little-endian binary file of 16 bit floats.
    private static func float16Data(named name: String) throws -> [Float] {
        guard let url = url(named: name, extension: "f16") else {
            throw ResourceError.notFound(name)
        }
        let data = try Data(contentsOf: url)
        let count = data.count / 2
        var values = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let source = raw.bindMemory(to: UInt8.self)
            for index in 0..<count {
                let offset = index * 2
                let bits = UInt16(source[offset]) | (UInt16(source[offset + 1]) << 8)
                values[index] = Float(Self.float16(bits: bits))
            }
        }
        return values
    }

    /// Converts an IEEE 754 half precision bit pattern into a `Float`.
    private static func float16(bits: UInt16) -> Float {
        let sign: Float = (bits & 0x8000) != 0 ? -1.0 : 1.0
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = Int(bits & 0x03FF)
        if exponent == 0 {
            if mantissa == 0 { return sign < 0 ? -0.0 : 0.0 }
            // Subnormal: value = mantissa / 1024 · 2⁻¹⁴
            let magnitude = Float(mantissa) * Float(pow(2.0, -24.0))
            return sign * magnitude
        }
        if exponent == 0x1F {
            return mantissa == 0 ? sign * Float.infinity : Float.nan
        }
        let mantissaFraction = 1.0 + Float(mantissa) / 1024.0
        let scale = Float(pow(2.0, Double(exponent - 15)))
        return sign * mantissaFraction * scale
    }

    // MARK: - The spectra

    /// The hanatos 2025 irradiance spectra table.
    ///
    /// Upstream reference: `spektrafilm.data.luts.spectral_upsampling.irradiance_xy_tc.npy`,
    /// loaded by `spektrafilm.utils.spectral_upsampling._load_hanatos2025_spectra_lut`.
    ///
    /// The table is indexed as `spectra[(i * 192 + j) * 81 + wavelength]`,
    /// i.e. the first axis is the `tc.x` grid, the second the `tc.y` grid and
    /// the third the wavelength.
    public static func hanatosSpectra() throws -> [Float] {
        try storage.spectra()
    }

    /// Decodes the hanatos 2025 irradiance spectra table.
    private static func decodeSpectra() throws -> [Float] {
        let values = try float16Data(named: "irradiance_xy_tc")
        let expected = tcGridSize * tcGridSize * wavelengthCount
        guard values.count == expected else {
            throw ResourceError.invalidShape(
                "the hanatos spectra table holds \(values.count) values, expected \(expected)"
            )
        }
        return values
    }

    /// The CIE 1931 2° colour matching functions, `[wavelength][XYZ]`.
    ///
    /// Upstream reference: `spektrafilm.config.STANDARD_OBSERVER_CMFS`.
    public static func colourMatchingFunctions() throws -> [[Double]] {
        try storage.colourMatchingFunctions()
    }

    /// Decodes the CIE 1931 2° colour matching functions.
    private static func decodeColourMatchingFunctions() throws -> [[Double]] {
        let values = try float32Data(named: "cmfs_cie1931_2deg")
        guard values.count == wavelengthCount * 3 else {
            throw ResourceError.invalidShape(
                "the colour matching functions hold \(values.count) values, expected "
                    + "\(wavelengthCount * 3)"
            )
        }
        return (0..<wavelengthCount).map { wavelength in
            [
                Double(values[wavelength * 3]),
                Double(values[wavelength * 3 + 1]),
                Double(values[wavelength * 3 + 2]),
            ]
        }
    }

    /// The bundled illuminant spectra, keyed by label.
    ///
    /// Upstream reference: `spektrafilm.model.illuminants.standard_illuminant`.
    public static func illuminants() throws -> [String: [Double]] {
        try storage.illuminants()
    }

    /// Decodes the bundled illuminant spectra.
    private static func decodeIlluminants() throws -> [String: [Double]] {
        let values = try float32Data(named: "illuminants")
        guard values.count == illuminantLabels.count * wavelengthCount else {
            throw ResourceError.invalidShape(
                "the illuminant table holds \(values.count) values, expected "
                    + "\(illuminantLabels.count * wavelengthCount)"
            )
        }
        var result: [String: [Double]] = [:]
        for (index, label) in illuminantLabels.enumerated() {
            let start = index * wavelengthCount
            result[label] = (0..<wavelengthCount).map { Double(values[start + $0]) }
        }
        return result
    }

    // MARK: - The neutral print filter database

    /// The neutral print filter database.
    ///
    /// Upstream reference: `spektrafilm.data.filters.neutral_print_filters.json`,
    /// read by `spektrafilm.utils.io.read_neutral_print_filters` and applied
    /// by `spektrafilm.runtime.params_builder.apply_database_neutral_print_filters`.
    ///
    /// The database maps a print stock to an illuminant to a film stock and to
    /// the (C, M, Y) Kodak CC values of the neutral print filters.
    public static func neutralPrintFilters() throws -> [String: [String: [String: [Double]]]] {
        try storage.neutralPrintFilters()
    }

    /// Decodes the neutral print filter database.
    private static func decodeNeutralPrintFilters() throws -> [String: [String: [String: [Double]]]] {
        guard let url = url(named: "neutral_print_filters", extension: "json") else {
            throw ResourceError.notFound("neutral_print_filters")
        }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResourceError.invalidShape("the neutral print filter database is not an object")
        }
        var result: [String: [String: [String: [Double]]]] = [:]
        for (printStock, illuminants) in object {
            guard let illuminants = illuminants as? [String: Any] else { continue }
            var perIlluminant: [String: [String: [Double]]] = [:]
            for (illuminant, films) in illuminants {
                guard let films = films as? [String: Any] else { continue }
                var perFilm: [String: [Double]] = [:]
                for (film, values) in films {
                    guard let values = values as? [NSNumber] else { continue }
                    perFilm[film] = values.map { $0.doubleValue }
                }
                perIlluminant[illuminant] = perFilm
            }
            result[printStock] = perIlluminant
        }
        return result
    }
}
