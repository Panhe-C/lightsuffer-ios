//
//  Profile.swift
//  light suffer胶片 — iOS app
//
//  Pure-Swift port of the spektrafilm profile model and loader.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

// MARK: - Profile enumerations

/// The kind of emulsion a profile describes (`negative` or `positive`).
///
/// Upstream: `spektrafilm.profiles.io.ProfileInfo.type`.
public enum ProfileType: String, Codable, Sendable {
    case negative
    case positive
}

/// The physical support of the emulsion (`film` or `paper`).
///
/// Upstream: `spektrafilm.profiles.io.ProfileInfo.support`.
public enum ProfileSupport: String, Codable, Sendable {
    case film
    case paper
}

/// The pipeline stage a profile belongs to (`filming` or `printing`).
///
/// Upstream: `spektrafilm.profiles.io.ProfileInfo.stage`.
public enum ProfileStage: String, Codable, Sendable {
    case filming
    case printing
}

/// The intended use of the stock (`still` or `cine`).
///
/// Upstream: `spektrafilm.profiles.io.ProfileInfo.use`.
public enum ProfileUse: String, Codable, Sendable {
    case still
    case cine
}

/// The strength of the anti-halation layer (`strong`, `weak` or `no`).
///
/// Upstream: `spektrafilm.profiles.io.ProfileInfo.antihalation`.
public enum Antihalation: String, Codable, Sendable {
    case strong
    case weak
    case no
}

/// The channel model of the emulsion (`color` or `bw`).
///
/// Upstream: `spektrafilm.profiles.io.ProfileInfo.channel_model`.
public enum ChannelModel: String, Codable, Sendable {
    case color
    case bw
}

// MARK: - Profile metadata

/// Descriptive metadata of a profile.
///
/// Upstream: `spektrafilm.profiles.io.ProfileMetadata`.
public struct ProfileMetadata: Codable, Equatable, Sendable {
    public var version: String
    public var copyright: String
    public var created: String
    public var license: String
    public var citation: String
    public var datasource: String

    public init(
        version: String = "",
        copyright: String = "",
        created: String = "",
        license: String = "",
        citation: String = "",
        datasource: String = ""
    ) {
        self.version = version
        self.copyright = copyright
        self.created = created
        self.license = license
        self.citation = citation
        self.datasource = datasource
    }
}

// MARK: - Profile info

/// The human readable description of a stock.
///
/// Upstream: `spektrafilm.profiles.io.ProfileInfo`.
public struct ProfileInfo: Codable, Equatable, Sendable {
    public var stock: String
    public var name: String
    public var type: ProfileType
    public var support: ProfileSupport
    public var stage: ProfileStage
    public var use: ProfileUse
    public var antihalation: Antihalation
    public var targetPrint: String?
    public var channelModel: ChannelModel
    public var densitometer: String
    public var logSensitivityDensityOverMin: Double
    public var referenceIlluminant: String
    public var viewingIlluminant: String

    enum CodingKeys: String, CodingKey {
        case stock, name, type, support, stage, use, antihalation
        case targetPrint = "target_print"
        case channelModel = "channel_model"
        case densitometer
        case logSensitivityDensityOverMin = "log_sensitivity_density_over_min"
        case referenceIlluminant = "reference_illuminant"
        case viewingIlluminant = "viewing_illuminant"
    }

    public init(
        stock: String,
        name: String,
        type: ProfileType = .negative,
        support: ProfileSupport = .film,
        stage: ProfileStage = .filming,
        use: ProfileUse = .still,
        antihalation: Antihalation = .weak,
        targetPrint: String? = nil,
        channelModel: ChannelModel = .color,
        densitometer: String = "status_M",
        logSensitivityDensityOverMin: Double = 0.2,
        referenceIlluminant: String = "D55",
        viewingIlluminant: String = "D50"
    ) {
        self.stock = stock
        self.name = name
        self.type = type
        self.support = support
        self.stage = stage
        self.use = use
        self.antihalation = antihalation
        self.targetPrint = targetPrint
        self.channelModel = channelModel
        self.densitometer = densitometer
        self.logSensitivityDensityOverMin = logSensitivityDensityOverMin
        self.referenceIlluminant = referenceIlluminant
        self.viewingIlluminant = viewingIlluminant
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stock = try container.decode(String.self, forKey: .stock)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(ProfileType.self, forKey: .type)
        support = try container.decode(ProfileSupport.self, forKey: .support)
        stage = try container.decode(ProfileStage.self, forKey: .stage)
        use = try container.decode(ProfileUse.self, forKey: .use)
        antihalation = try container.decode(Antihalation.self, forKey: .antihalation)
        targetPrint = try container.decodeIfPresent(String.self, forKey: .targetPrint)
        channelModel = try container.decode(ChannelModel.self, forKey: .channelModel)
        densitometer = try container.decode(String.self, forKey: .densitometer)
        logSensitivityDensityOverMin = try container.decode(
            Double.self, forKey: .logSensitivityDensityOverMin
        )
        referenceIlluminant = try container.decode(String.self, forKey: .referenceIlluminant)
        viewingIlluminant = try container.decode(String.self, forKey: .viewingIlluminant)
    }
}

// MARK: - Density curves model

/// The parametric (sum of CDFs) model of the density curves.
///
/// `centers`, `amplitudes` and `sigmas` are 2-D arrays shaped
/// `(n_channels, n_layers)`.
///
/// Upstream: `spektrafilm.profiles.io.DensityCurvesModel`.
public struct DensityCurvesModel: Codable, Equatable, Sendable {
    public var modelType: String
    /// The centre (log exposure) of every layer, `[channel][layer]`.
    public var centers: [[Double]]
    /// The amplitude (maximum density contribution) of every layer, `[channel][layer]`.
    public var amplitudes: [[Double]]
    /// The standard deviation of every layer, `[channel][layer]`.
    public var sigmas: [[Double]]

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case centers, amplitudes, sigmas
    }

    public init(
        modelType: String = "cdfs",
        centers: [[Double]] = [],
        amplitudes: [[Double]] = [],
        sigmas: [[Double]] = []
    ) {
        self.modelType = modelType
        self.centers = centers
        self.amplitudes = amplitudes
        self.sigmas = sigmas
    }

    /// Number of channels described by the model.
    public var nChannels: Int { centers.count }

    /// Number of layers per channel described by the model.
    public var nLayers: Int { centers.first?.count ?? 0 }
}

// MARK: - Profile data

/// The spectral and densitometric data of a profile.
///
/// Upstream: `spektrafilm.profiles.io.ProfileData`.
///
/// All arrays are stored with the upstream layout:
/// * wavelength indexed arrays are `[wavelength][channel]`,
/// * the density curve arrays are `[sample][channel]`,
/// * `densityCurvesLayers` is `[sample][channel][layer]`.
///
/// JSON `null` entries are decoded as `Double.nan`, mirroring the upstream
/// `profiles.io._json_safe` writer, which stores NaN as `null`.
public struct ProfileData: Codable, Equatable, Sendable {
    /// The spectral sampling, in nanometres.
    public var wavelengths: [Double]
    /// The base-10 logarithm of the spectral sensitivity, `[wavelength][channel]`.
    public var logSensitivity: [[Double]]
    /// The spectral density of the image forming layer, `[wavelength][channel]`.
    public var channelDensity: [[Double]]
    /// The base (fog) density of the emulsion, `[wavelength]`.
    public var baseDensity: [Double]
    /// The neutral density at mid scale, `[wavelength]`.
    public var midscaleNeutralDensity: [Double]
    /// The log10 exposure axis of the density curves.
    public var logExposure: [Double]
    /// The characteristic density curves, `[sample][channel]`.
    public var densityCurves: [[Double]]
    /// The per layer density curves, `[sample][channel][layer]`.
    public var densityCurvesLayers: [[[Double]]]
    /// The parametric model of the density curves.
    public var densityCurvesModel: DensityCurvesModel

    enum CodingKeys: String, CodingKey {
        case wavelengths
        case logSensitivity = "log_sensitivity"
        case channelDensity = "channel_density"
        case baseDensity = "base_density"
        case midscaleNeutralDensity = "midscale_neutral_density"
        case logExposure = "log_exposure"
        case densityCurves = "density_curves"
        case densityCurvesLayers = "density_curves_layers"
        case densityCurvesModel = "density_curves_model"
    }

    public init(
        wavelengths: [Double] = [],
        logSensitivity: [[Double]] = [],
        channelDensity: [[Double]] = [],
        baseDensity: [Double] = [],
        midscaleNeutralDensity: [Double] = [],
        logExposure: [Double] = [],
        densityCurves: [[Double]] = [],
        densityCurvesLayers: [[[Double]]] = [],
        densityCurvesModel: DensityCurvesModel = DensityCurvesModel()
    ) {
        self.wavelengths = wavelengths
        self.logSensitivity = logSensitivity
        self.channelDensity = channelDensity
        self.baseDensity = baseDensity
        self.midscaleNeutralDensity = midscaleNeutralDensity
        self.logExposure = logExposure
        self.densityCurves = densityCurves
        self.densityCurvesLayers = densityCurvesLayers
        self.densityCurvesModel = densityCurvesModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wavelengths = try container.decodeNaNAwareDoubles(forKey: .wavelengths)
        logSensitivity = try container.decodeNaNAwareDoubleRows(forKey: .logSensitivity)
        channelDensity = try container.decodeNaNAwareDoubleRows(forKey: .channelDensity)
        baseDensity = try container.decodeNaNAwareDoubles(forKey: .baseDensity)
        midscaleNeutralDensity = try container.decodeNaNAwareDoubles(forKey: .midscaleNeutralDensity)
        logExposure = try container.decodeNaNAwareDoubles(forKey: .logExposure)
        densityCurves = try container.decodeNaNAwareDoubleRows(forKey: .densityCurves)
        densityCurvesLayers = try container.decodeNaNAwareDoubleRowsRows(forKey: .densityCurvesLayers)
        densityCurvesModel = try container.decode(DensityCurvesModel.self, forKey: .densityCurvesModel)
    }
}

// MARK: - Profile

/// A complete spektrafilm profile.
///
/// Upstream: `spektrafilm.profiles.io.Profile`.
public struct Profile: Codable, Equatable, Sendable {
    public var metadata: ProfileMetadata
    public var info: ProfileInfo
    public var data: ProfileData

    public init(
        metadata: ProfileMetadata = ProfileMetadata(),
        info: ProfileInfo,
        data: ProfileData = ProfileData()
    ) {
        self.metadata = metadata
        self.info = info
        self.data = data
    }

    /// `true` for slide / direct-scan positive emulsions.
    public var isPositive: Bool { info.type == .positive }

    /// `true` for colour negative emulsions.
    public var isNegative: Bool { info.type == .negative }

    /// `true` when the profile describes a photographic paper.
    public var isPaper: Bool { info.support == .paper }

    /// `true` when the profile describes a film.
    public var isFilm: Bool { info.support == .film }
}

// MARK: - Loading

/// Errors thrown while loading or validating a profile.
public enum ProfileError: Error, CustomStringConvertible {
    /// The requested stock is not bundled with the package.
    case notFound(stock: String)
    /// The profile JSON could not be parsed.
    case decodingFailed(stock: String, underlying: Error)
    /// The profile does not have the shape the upstream engine requires.
    case invalid(stock: String, reason: String)

    public var description: String {
        switch self {
        case let .notFound(stock):
            return "profile '\(stock)' not found in the bundled resources"
        case let .decodingFailed(stock, underlying):
            return "profile '\(stock)' could not be decoded: \(underlying)"
        case let .invalid(stock, reason):
            return "profile '\(stock)' is invalid: \(reason)"
        }
    }
}

/// Loads spektrafilm profiles from the bundled JSON resources.
///
/// Upstream: `spektrafilm.profiles.io.load_profile` and
/// `spektrafilm.profiles.io._validate_profile`.
public enum ProfileLoader {

    /// Loads a profile from the bundled resources.
    ///
    /// - Parameter stock: the profile stock name, e.g. `kodak_portra_400`.
    public static func load(stock: String) throws -> Profile {
        guard let url = FilmPhysics.profileURL(stock: stock) else {
            throw ProfileError.notFound(stock: stock)
        }
        return try load(contentsOf: url, stock: stock)
    }

    /// Loads a profile from an arbitrary JSON file.
    public static func load(contentsOf url: URL, stock: String? = nil) throws -> Profile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProfileError.decodingFailed(stock: stock ?? url.lastPathComponent, underlying: error)
        }
        let name = stock ?? url.deletingPathExtension().lastPathComponent
        return try decode(data, stock: name)
    }

    /// Decodes and validates a profile from its JSON representation.
    public static func decode(_ data: Data, stock: String) throws -> Profile {
        let profile: Profile
        do {
            profile = try JSONDecoder().decode(Profile.self, from: data)
        } catch {
            throw ProfileError.decodingFailed(stock: stock, underlying: error)
        }
        try validate(profile, stock: stock)
        return profile
    }

    /// Validates the shape of a profile.
    ///
    /// This mirrors `spektrafilm.profiles.io._validate_profile`: the density
    /// curves must be sampled on the log exposure axis, the spectral arrays
    /// must be sampled on the wavelength axis and the channel dimension must
    /// always be 3 (CMY).
    public static func validate(_ profile: Profile, stock: String? = nil) throws {
        let name = stock ?? profile.info.stock
        let data = profile.data

        func fail(_ reason: String) -> ProfileError { .invalid(stock: name, reason: reason) }

        guard data.logExposure.count >= 2 else {
            throw fail("log_exposure must contain at least two samples")
        }
        guard data.densityCurves.count == data.logExposure.count else {
            throw fail("density_curves must have one row per log_exposure sample")
        }
        guard data.densityCurves.allSatisfy({ $0.count == 3 }) else {
            throw fail("density_curves must have three channels")
        }
        guard data.logSensitivity.allSatisfy({ $0.count == 3 }) else {
            throw fail("log_sensitivity must have three channels")
        }
        guard data.channelDensity.count == data.wavelengths.count else {
            throw fail("channel_density must have one row per wavelength")
        }
        guard data.channelDensity.allSatisfy({ $0.count == 3 }) else {
            throw fail("channel_density must have three channels")
        }
        guard data.baseDensity.count == data.wavelengths.count else {
            throw fail("base_density must have one value per wavelength")
        }
        guard data.midscaleNeutralDensity.count == data.wavelengths.count else {
            throw fail("midscale_neutral_density must have one value per wavelength")
        }
    }
}

// MARK: - NaN aware decoding

extension KeyedDecodingContainer {
    /// Decodes an array of doubles, mapping JSON `null` to `Double.nan`.
    func decodeNaNAwareDoubles(forKey key: Key) throws -> [Double] {
        let values = try decodeIfPresent([Double?].self, forKey: key) ?? []
        return values.map { $0 ?? Double.nan }
    }

    /// Decodes a two dimensional array of doubles, mapping JSON `null` to `Double.nan`.
    func decodeNaNAwareDoubleRows(forKey key: Key) throws -> [[Double]] {
        let rows = try decodeIfPresent([[Double?]].self, forKey: key) ?? []
        return rows.map { row in row.map { $0 ?? Double.nan } }
    }

    /// Decodes a three dimensional array of doubles, mapping JSON `null` to `Double.nan`.
    func decodeNaNAwareDoubleRowsRows(forKey key: Key) throws -> [[[Double]]] {
        let rows = try decodeIfPresent([[[Double?]]].self, forKey: key) ?? []
        return rows.map { row in row.map { line in line.map { $0 ?? Double.nan } } }
    }
}
