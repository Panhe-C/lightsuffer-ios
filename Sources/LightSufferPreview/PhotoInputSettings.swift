//
//  PhotoInputSettings.swift
//  Platform-neutral RAW, white-balance and input-colour policy.
//

import FilmPhysics
import Foundation

/// The container / decoder classification used by the app shell.
///
/// `dng` is also the portable model's category for other camera-RAW files;
/// the Apple decoder still has to validate every RAW candidate with
/// `CIRAWFilter`. A TIFF signature is therefore only a RAW *candidate*, not
/// proof that the file is a DNG.
public enum PhotoKind: String, CaseIterable, Equatable, Sendable {
    case jpeg
    case heic
    case png
    case dng
    case proraw
    case unknown

    public var isRAW: Bool {
        self == .dng || self == .proraw
    }

    public var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .png: return "PNG"
        case .dng: return "RAW / DNG"
        case .proraw: return "ProRAW"
        case .unknown: return "Image"
        }
    }

    /// Detects a kind without Image I/O or UniformTypeIdentifiers so the same
    /// rules can be tested on Linux. RAW hints are conservative: if any
    /// supplied hint says RAW, the Apple layer must validate it with
    /// `CIRAWFilter` instead of silently taking the processed-image path.
    public static func detect(
        typeIdentifier: String? = nil,
        filename: String? = nil,
        data: Data? = nil
    ) -> PhotoKind {
        let uti = typeIdentifier.flatMap(kind(forTypeIdentifier:))
        let ext = filename.flatMap(kind(forFilename:))
        let magic = data.map(detectMagic(_:))

        if uti == .proraw || ext == .proraw || magic == .proraw {
            return .proraw
        }
        if uti?.isRAW == true || ext?.isRAW == true || magic?.isRAW == true {
            return .dng
        }
        // Image I/O's container UTI is more reliable than a filename. Magic
        // bytes break a tie between an unhelpful/generic UTI and an extension.
        if let uti, uti != .unknown { return uti }
        if let magic, magic != .unknown { return magic }
        if let ext, ext != .unknown { return ext }
        return .unknown
    }

    /// JPEG FF D8, PNG's eight-byte signature, ISO-BMFF `ftyp` for HEIC, and
    /// little/big-endian TIFF signatures used by DNG and other TIFF RAWs.
    public static func detectMagic(_ data: Data) -> PhotoKind {
        let bytes = [UInt8](data.prefix(32))
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 {
            return .jpeg
        }
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if bytes.count >= png.count, Array(bytes.prefix(png.count)) == png {
            return .png
        }
        if bytes.count >= 12,
           bytes[4] == 0x66, bytes[5] == 0x74, // "ft"
           bytes[6] == 0x79, bytes[7] == 0x70 { // "yp"
            let brand = String(decoding: bytes[8..<12], as: UTF8.self).lowercased()
            if brand == "pror" { return .proraw }
            let heicBrands: Set<String> = [
                "heic", "heix", "hevc", "hevx", "heim", "heis",
                "hevm", "hevs", "mif1", "msf1",
            ]
            if heicBrands.contains(brand) { return .heic }
        }
        if bytes.count >= 4 {
            let littleEndianTIFF = bytes[0] == 0x49 && bytes[1] == 0x49 &&
                bytes[2] == 0x2A && bytes[3] == 0x00
            let bigEndianTIFF = bytes[0] == 0x4D && bytes[1] == 0x4D &&
                bytes[2] == 0x00 && bytes[3] == 0x2A
            if littleEndianTIFF || bigEndianTIFF { return .dng }
        }
        return .unknown
    }

    private static func kind(forTypeIdentifier identifier: String) -> PhotoKind {
        switch identifier.lowercased() {
        case "public.jpeg", "public.jpg", "image/jpeg":
            return .jpeg
        case "public.heic", "public.heif", "public.heic-standard", "image/heic", "image/heif":
            return .heic
        case "public.png", "image/png":
            return .png
        case "com.apple.proraw", "com.apple.proraw-image", "image/proraw":
            return .proraw
        case "public.camera-raw-image", "com.adobe.raw-image", "com.adobe.dng",
             "public.dng", "image/x-adobe-dng", "image/dng":
            return .dng
        default:
            return .unknown
        }
    }

    private static func kind(forFilename filename: String) -> PhotoKind {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif": return .heic
        case "png": return .png
        case "proraw": return .proraw
        // These extensions are only candidates. CIRAWFilter remains the
        // authority on whether the bytes can actually be demosaiced.
        case "dng", "raw", "cr2", "cr3", "nef", "nrw", "arw", "orf",
             "rw2", "raf", "pef", "sr2", "srf", "erf", "mrw", "dcr",
             "kdc", "3fr", "iiq":
            return .dng
        default:
            return .unknown
        }
    }
}

public enum PhotoInputSettingsError: LocalizedError, Equatable {
    case customTemperatureRequired
    case invalidTemperature(Double)
    case temperatureOutsideCoreImageRange(Double)
    case invalidTint(Double)
    case unknownInputColorSpace(String)

    public var errorDescription: String? {
        switch self {
        case .customTemperatureRequired:
            return "Custom white balance requires a colour temperature."
        case let .invalidTemperature(value):
            return "The white-balance temperature \(value) K is not finite and positive."
        case let .temperatureOutsideCoreImageRange(value):
            return "The white-balance temperature \(value) K is outside CIRAWFilter's 2000–50000 K range."
        case let .invalidTint(value):
            return "The white-balance tint \(value) is not finite and positive."
        case let .unknownInputColorSpace(name):
            return "The input colour space ‘\(name)’ is not in the offered colour-space list."
        }
    }
}

/// White-balance choices matching the upstream GUI.
public enum WhiteBalanceMode: String, CaseIterable, Equatable, Hashable, Sendable {
    case asShot
    case daylight
    case tungsten
    case custom

    /// Upstream `_DAYLIGHT_REFERENCE_TEMPERATURE` (not 6500 K).
    public static let daylightReferenceTemperature = 6504.0
    /// Upstream `_TUNGSTEN_TEMPERATURE`.
    public static let tungstenReferenceTemperature = 2850.0
    public static let defaultCustomTemperature = daylightReferenceTemperature
    public static let defaultTint = 1.0

    /// CIRAWFilter's documented iOS 17 temperature range.
    public static let coreImageTemperatureRange = 2000.0...50000.0

    public var displayName: String {
        switch self {
        case .asShot: return "As shot"
        case .daylight: return "Daylight"
        case .tungsten: return "Tungsten"
        case .custom: return "Custom"
        }
    }

    /// `nil` means that no temperature is forced (camera/as-shot WB).
    public func resolvedTemperature(customTemperature: Double?) throws -> Double? {
        switch self {
        case .asShot:
            return nil
        case .daylight:
            return Self.daylightReferenceTemperature
        case .tungsten:
            return Self.tungstenReferenceTemperature
        case .custom:
            guard let customTemperature else {
                throw PhotoInputSettingsError.customTemperatureRequired
            }
            guard customTemperature.isFinite, customTemperature > 0 else {
                throw PhotoInputSettingsError.invalidTemperature(customTemperature)
            }
            return customTemperature
        }
    }
}

/// The exact settings the Apple adapter writes to CIRAWFilter.
public struct AppleWhiteBalanceMapping: Equatable, Sendable {
    /// Leave both neutral properties untouched for as-shot camera WB.
    public let usesCameraWhiteBalance: Bool
    public let neutralTemperature: Double?
    /// Core Image's conventional green–magenta axis, where 0 is neutral.
    public let neutralTint: Double?
    public let mappingDescription: String

    public init(
        usesCameraWhiteBalance: Bool,
        neutralTemperature: Double?,
        neutralTint: Double?,
        mappingDescription: String
    ) {
        self.usesCameraWhiteBalance = usesCameraWhiteBalance
        self.neutralTemperature = neutralTemperature
        self.neutralTint = neutralTint
        self.mappingDescription = mappingDescription
    }
}

/// `.automatic` uses the embedded profile / camera colour. `.explicit` is a
/// requested engine-input space, with conversion fallback where necessary.
public enum PhotoInputColorSpace: Equatable, Hashable, Sendable {
    case automatic
    case explicit(String)

    public static let offeredNames = [
        "sRGB", "DCI-P3", "Display P3", "Adobe RGB", "BT.2020",
        "ProPhoto RGB", "ACES2065-1",
    ]

    public static var offered: [PhotoInputColorSpace] {
        [.automatic] + offeredNames.map { .explicit($0) }
    }

    public var displayName: String {
        switch self {
        case .automatic: return "Embedded / automatic"
        case let .explicit(name): return name
        }
    }
}

public struct EngineInputColorSpace: Equatable, Sendable {
    public let inputColorSpace: String
    public let inputCCTFDecoding: Bool

    public init(inputColorSpace: String, inputCCTFDecoding: Bool) {
        self.inputColorSpace = inputColorSpace
        self.inputCCTFDecoding = inputCCTFDecoding
    }
}

public struct InputColorSpaceResolution: Equatable, Sendable {
    public let requestedName: String?
    public let engine: EngineInputColorSpace
    public let requiresConversionFallback: Bool
    public let fallbackReason: String?

    public init(
        requestedName: String?,
        engine: EngineInputColorSpace,
        requiresConversionFallback: Bool,
        fallbackReason: String?
    ) {
        self.requestedName = requestedName
        self.engine = engine
        self.requiresConversionFallback = requiresConversionFallback
        self.fallbackReason = fallbackReason
    }
}

/// The engine implements only sRGB and ProPhoto RGB. All other offered names
/// are deliberately converted to linear ProPhoto in the Apple I/O layer.
public enum InputColorSpacePolicy {
    public static let engineSupportedNames = ["sRGB", "ProPhoto RGB"]
    public static let linearProPhoto = EngineInputColorSpace(
        inputColorSpace: "ProPhoto RGB",
        inputCCTFDecoding: false
    )
    /// The app chooses linear sRGB, not encoded sRGB + CCTF decoding.
    public static let linearSRGB = EngineInputColorSpace(
        inputColorSpace: "sRGB",
        inputCCTFDecoding: false
    )

    public static func resolve(
        _ selection: PhotoInputColorSpace
    ) throws -> InputColorSpaceResolution {
        guard case let .explicit(suppliedName) = selection else {
            return InputColorSpaceResolution(
                requestedName: nil,
                engine: linearProPhoto,
                requiresConversionFallback: false,
                fallbackReason: nil
            )
        }
        let name = canonicalName(for: suppliedName)
        guard PhotoInputColorSpace.offeredNames.contains(name) else {
            throw PhotoInputSettingsError.unknownInputColorSpace(suppliedName)
        }
        if name == "sRGB" {
            return InputColorSpaceResolution(
                requestedName: name,
                engine: linearSRGB,
                requiresConversionFallback: false,
                fallbackReason: nil
            )
        }
        if name == "ProPhoto RGB" {
            return InputColorSpaceResolution(
                requestedName: name,
                engine: linearProPhoto,
                requiresConversionFallback: false,
                fallbackReason: nil
            )
        }
        return InputColorSpaceResolution(
            requestedName: name,
            engine: linearProPhoto,
            requiresConversionFallback: true,
            fallbackReason: "\(name) is converted to linear ProPhoto RGB; the engine has no native \(name)."
        )
    }

    private static func canonicalName(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept the longer labels used by the current upstream GUI too.
        switch trimmed {
        case "Adobe RGB (1998)": return "Adobe RGB"
        case "ITU-R BT.2020": return "BT.2020"
        default: return trimmed
        }
    }
}

/// Immutable input settings shared by preview and the full-resolution export.
public struct PhotoInputSettings: Equatable, Sendable {
    public var whiteBalanceMode: WhiteBalanceMode
    /// Optional so an incomplete custom setting is a reported error, never a
    /// silently substituted temperature. The default is upstream's 6504 K.
    public var customTemperature: Double?
    /// Upstream's multiplicative green-channel scale; 1.0 is no adjustment.
    public var customTint: Double
    public var inputColorSpace: PhotoInputColorSpace

    public init(
        whiteBalanceMode: WhiteBalanceMode = .asShot,
        customTemperature: Double? = WhiteBalanceMode.defaultCustomTemperature,
        customTint: Double = WhiteBalanceMode.defaultTint,
        inputColorSpace: PhotoInputColorSpace = .automatic
    ) {
        self.whiteBalanceMode = whiteBalanceMode
        self.customTemperature = customTemperature
        self.customTint = customTint
        self.inputColorSpace = inputColorSpace
    }

    public var resolvedInputColorSpace: InputColorSpaceResolution {
        get throws { try InputColorSpacePolicy.resolve(inputColorSpace) }
    }

    public func resolvedWhiteBalance() throws -> AppleWhiteBalanceMapping {
        let temperature = try whiteBalanceMode.resolvedTemperature(
            customTemperature: customTemperature
        )
        if let temperature,
           !WhiteBalanceMode.coreImageTemperatureRange.contains(temperature) {
            throw PhotoInputSettingsError.temperatureOutsideCoreImageRange(temperature)
        }
        switch whiteBalanceMode {
        case .asShot:
            return AppleWhiteBalanceMapping(
                usesCameraWhiteBalance: true,
                neutralTemperature: nil,
                neutralTint: nil,
                mappingDescription: "As shot leaves CIRAWFilter's camera-metadata neutral temperature and tint untouched, approximating LibRaw use_camera_wb."
            )
        case .daylight:
            return AppleWhiteBalanceMapping(
                usesCameraWhiteBalance: false,
                neutralTemperature: temperature,
                neutralTint: 0,
                mappingDescription: "Daylight sets CIRAWFilter neutralTemperature to 6504 K and neutralTint to 0 at demosaic time. This is the iOS approximation of LibRaw's daylight-balanced default; no extra ACES adaptation is applied."
            )
        case .tungsten:
            return AppleWhiteBalanceMapping(
                usesCameraWhiteBalance: false,
                neutralTemperature: temperature,
                neutralTint: 0,
                mappingDescription: "Tungsten sets CIRAWFilter neutralTemperature to 2850 K and neutralTint to 0. This demosaic-time WB approximates upstream's daylight base followed by chromatic adaptation in linear ACES."
            )
        case .custom:
            guard customTint.isFinite, customTint > 0 else {
                throw PhotoInputSettingsError.invalidTint(customTint)
            }
            return AppleWhiteBalanceMapping(
                usesCameraWhiteBalance: false,
                neutralTemperature: temperature,
                neutralTint: Self.coreImageNeutralTint(greenMultiplier: customTint),
                mappingDescription: "Custom temperature drives CIRAWFilter neutralTemperature at demosaic time. Upstream's green multiplier is approximated on Core Image's conventional green–magenta neutralTint axis by (1 − greenMultiplier) × 150; 1.0 maps to 0. This replaces upstream's daylight-base ACES adaptation and exact green-channel multiplication."
            )
        }
    }

    /// Maps a multiplicative green adjustment to Core Image's -150…150
    /// conventional tint slider. Positive Core Image tint is treated as
    /// magenta, hence the opposite sign. Clamping keeps the property in its
    /// documented range; the default 1.0 is exactly neutral.
    public static func coreImageNeutralTint(greenMultiplier: Double) -> Double {
        min(150, max(-150, (1 - greenMultiplier) * 150))
    }

    /// Writes only engine-supported I/O tags. Pixel conversion is performed by
    /// the Apple decoder; an unsupported engine name is never passed through.
    public func apply(to params: inout PipelineParams) throws {
        _ = try resolvedWhiteBalance()
        let resolution = try resolvedInputColorSpace
        params.io.inputColorSpace = resolution.engine.inputColorSpace
        params.io.inputCCTFDecoding = resolution.engine.inputCCTFDecoding
    }

    public func applying(to params: PipelineParams) throws -> PipelineParams {
        var output = params
        try apply(to: &output)
        return output
    }

    /// Visible policy text; the decoder adds the actual Image I/O / RAW path.
    public func status(for kind: PhotoKind) throws -> String {
        let resolution = try resolvedInputColorSpace
        var messages: [String] = []
        if let reason = resolution.fallbackReason {
            messages.append(reason)
        } else if resolution.engine.inputColorSpace == "sRGB" {
            messages.append("Colour-managed input is linear sRGB; the engine receives sRGB with CCTF decoding off.")
        } else {
            messages.append("Colour-managed input is linear ProPhoto RGB; the engine receives ProPhoto RGB with CCTF decoding off.")
        }
        if !kind.isRAW && whiteBalanceMode != .asShot {
            messages.append("White balance applies to RAW files; this processed photo was not re-tinted.")
        }
        return messages.joined(separator: " ")
    }
}
