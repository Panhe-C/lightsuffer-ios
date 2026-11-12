// Port of the style catalogue of wx-spektrafilm's utils/border.js.

public enum BorderStyle: String, CaseIterable, Codable, Identifiable {
    case none
    case thinWhite = "thin-white"
    case polaroid
    case black
    case film35
    case film120
    case edgeBlackThin = "edge-black-thin"
    case edgeBlack = "edge-black"
    case edgeWhiteThin = "edge-white-thin"
    case edgeWhite = "edge-white"

    public var id: String { rawValue }

    /// The label shown in the picker.
    public var displayName: String {
        switch self {
        case .none: return "无边框"
        case .thinWhite: return "细白边"
        case .polaroid: return "拍立得"
        case .black: return "黑边"
        case .film35: return "35mm 胶片"
        case .film120: return "120 胶片"
        case .edgeBlackThin: return "不规则细黑边"
        case .edgeBlack: return "不规则黑边"
        case .edgeWhiteThin: return "不规则细白边"
        case .edgeWhite: return "不规则白边"
        }
    }

    /// Unknown ids fall back to `.none`, like `normalizeStyle` in JS.
    public static func normalized(_ id: String?) -> BorderStyle {
        guard let id = id, let style = BorderStyle(rawValue: id) else { return .none }
        return style
    }

    /// Does this style print the film stock name on the border?
    public var printsEdgeText: Bool {
        self == .film35 || self == .film120
    }

    /// The irregular film-edge styles share one painter.
    public var edgeSpec: EdgeSpec? {
        switch self {
        case .edgeBlackThin: return EdgeSpec(color: "#050505", rim: "#2e2d2a", lo: 0.006, hi: 0.012, seed: 21)
        case .edgeBlack: return EdgeSpec(color: "#050505", rim: "#2e2d2a", lo: 0.015, hi: 0.025, seed: 22)
        case .edgeWhiteThin: return EdgeSpec(color: "#fcfbf8", rim: "#e2e0d9", lo: 0.006, hi: 0.012, seed: 23)
        case .edgeWhite: return EdgeSpec(color: "#fcfbf8", rim: "#e2e0d9", lo: 0.015, hi: 0.025, seed: 24)
        default: return nil
        }
    }

    /// Base colour of the frame (COLORS in JS; '#000000' when unlisted).
    public var color: String {
        switch self {
        case .thinWhite: return "#ffffff"
        case .polaroid: return "#f4f1e8"
        case .black: return "#000000"
        case .film35: return "#0c0b0a"
        case .film120: return "#050505"
        case .edgeBlackThin, .edgeBlack, .edgeWhiteThin, .edgeWhite: return edgeSpec!.color
        case .none: return "#000000"
        }
    }
}

/// The specification of an irregular film edge (EDGE_STYLES in JS).
public struct EdgeSpec: Equatable {
    public let color: String
    public let rim: String
    public let lo: Double
    public let hi: Double
    public let seed: UInt32

    public init(color: String, rim: String, lo: Double, hi: Double, seed: UInt32) {
        self.color = color
        self.rim = rim
        self.lo = lo
        self.hi = hi
        self.seed = seed
    }
}

/// The constants of the JS painter (the numbers never change).
public enum BorderConstants {
    public static let edgePrintColor = "#f2a03a"
    public static let sprocketColor = "#ece6d6"

    public static let film35Band = 0.153
    public static let film35Side = 0.025
    public static let sprocketLength = 0.36
    public static let sprocketAcross = 0.51
    public static let sprocketPitch = 0.864
    public static let sprocketInset = 0.17
    public static let sprocketRadius = 0.08

    public static let film120Seed: UInt32 = 9
    public static let film120PrintBand = 0.034
    public static let film120Margin = 0.016
    public static let film120Radius = 0.011
    public static let film120Jitter = 0.005
    public static let film120FrameNumber = 7
    public static let scanMarginColor = "#fcfbf8"
    public static let monoPrintColor = "#e8e8e2"
    public static let film120Fringe = "rgba(255, 140, 50, 0.55)"
    public static let film120FringeMono = "rgba(255, 255, 255, 0.2)"
    /// The Mini Program has no condensed font and squeezes a bold sans
    /// horizontally. The app keeps that (parity) unless a real condensed font is
    /// available, in which case it passes 1.
    public static let defaultPrintSqueeze = 0.8
    public static let defaultFrameNumber = 12
    /// The smallest edge a picker card shows (a 1 % edge would be a hairline).
    public static let edgeThumbnailMin = 0.035
    /// The font of the edge print (the Mini Program has no condensed font).
    public static let edgeFont = "sans-serif"
}
