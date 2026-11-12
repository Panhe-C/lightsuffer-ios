// Adapted from FrameKit/CGCanvas.swift in Panhe-C/lightsuffer-border-mac
// @ f6de465d5195f01bf6ded1b023e234233dd9ca7b. No AppKit dependency.

import Foundation
import FrameCore

#if canImport(CoreGraphics)
// FrameKit - Core Graphics back end of the portable FrameCore painter.
//
// The whole file is guarded: the package must still build on Linux, where the
// Apple frameworks do not exist.
import CoreGraphics
import CoreText

/// The bold edge-print font of the film styles.
///
/// The Mini Program has no condensed font and squeezes a bold sans
/// horizontally (printSqueeze = 0.8). A real condensed font needs no squeeze,
/// so the renderer asks the canvas whether the font it got is condensed.
public struct EdgeFont {
    /// The Core Text font.
    public let font: CTFont
    /// The PostScript name of the font.
    public let name: String
    /// True for a real condensed font (the print needs no horizontal squeeze).
    public let isCondensed: Bool
}

/// A `Canvas2D` implementation on top of a `CGContext`.
///
/// The context is expected to be flipped once by the renderer
/// (`translate(0, height)` + `scale(1, -1)`), so the user space is y-down with
/// the origin in the top left corner, exactly like an HTML canvas.
public final class CGCanvas: Canvas2D {
    /// The fonts of the edge print, in the order of preference.
    ///
    /// The first two are real condensed fonts; the last one is the plain bold
    /// system font (the fallback keeps the 0.8 squeeze of the Mini Program).
    public static let preferredFontNames = [
        "HelveticaNeue-CondensedBold",
        "AvenirNextCondensed-Bold",
        "Helvetica-Bold",
    ]

    /// The font that is not condensed.
    public static let fallbackFontName = "Helvetica-Bold"

    private let context: CGContext
    private var fontSize: Double = 10
    private var currentFont: CTFont?
    private var condensedFont = false

    private var storedFillStyle = "#000000"
    private var storedStrokeStyle = "#000000"
    private var storedLineWidth: Double = 1
    private var storedTextAlign: TextAlign = .left

    private struct State {
        var fillStyle: String
        var strokeStyle: String
        var lineWidth: Double
        var textAlign: TextAlign
        var fontSize: Double
        var font: CTFont?
        var condensed: Bool
    }

    private var stack: [State] = []

    public init(context: CGContext) {
        self.context = context
        // The default font is the system font, so that a text drawn before the
        // first setFont(size:) still shows something.
        let fallback = CGCanvas.edgeFont(size: 10)
        currentFont = fallback.font
        condensedFont = fallback.isCondensed
    }

    // MARK: - Canvas2D

    public var fillStyle: String {
        get { storedFillStyle }
        set {
            storedFillStyle = newValue
            if let color = CGColorParser.color(newValue) {
                context.setFillColor(color)
            }
        }
    }

    public var strokeStyle: String {
        get { storedStrokeStyle }
        set {
            storedStrokeStyle = newValue
            if let color = CGColorParser.color(newValue) {
                context.setStrokeColor(color)
            }
        }
    }

    public var lineWidth: Double {
        get { storedLineWidth }
        set {
            storedLineWidth = newValue
            context.setLineWidth(CGFloat(newValue))
        }
    }

    public var textAlign: TextAlign {
        get { storedTextAlign }
        set { storedTextAlign = newValue }
    }

    public func setFont(size: Double) {
        fontSize = size
        let resolved = CGCanvas.edgeFont(size: size)
        currentFont = resolved.font
        condensedFont = resolved.isCondensed
    }

    public func measureText(_ text: String) -> Double {
        guard let line = makeLine(text) else { return 0 }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return Double(width)
    }

    public func save() {
        stack.append(
            State(
                fillStyle: storedFillStyle,
                strokeStyle: storedStrokeStyle,
                lineWidth: storedLineWidth,
                textAlign: storedTextAlign,
                fontSize: fontSize,
                font: currentFont,
                condensed: condensedFont
            )
        )
        context.saveGState()
    }

    public func restore() {
        context.restoreGState()
        guard let state = stack.popLast() else { return }
        storedFillStyle = state.fillStyle
        storedStrokeStyle = state.strokeStyle
        storedLineWidth = state.lineWidth
        storedTextAlign = state.textAlign
        fontSize = state.fontSize
        currentFont = state.font
        condensedFont = state.condensed
    }

    public func translate(_ x: Double, _ y: Double) {
        context.translateBy(x: CGFloat(x), y: CGFloat(y))
    }

    public func rotate(_ angle: Double) {
        context.rotate(by: CGFloat(angle))
    }

    public func scale(_ x: Double, _ y: Double) {
        context.scaleBy(x: CGFloat(x), y: CGFloat(y))
    }

    public func fillRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)))
    }

    public func strokeRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        context.stroke(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)))
    }

    public func beginPath() {
        context.beginPath()
    }

    public func moveTo(_ x: Double, _ y: Double) {
        context.move(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
    }

    public func lineTo(_ x: Double, _ y: Double) {
        context.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
    }

    public func arcTo(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ radius: Double) {
        context.addArc(
            tangent1End: CGPoint(x: CGFloat(x1), y: CGFloat(y1)),
            tangent2End: CGPoint(x: CGFloat(x2), y: CGFloat(y2)),
            radius: CGFloat(radius)
        )
    }

    public func closePath() {
        context.closePath()
    }

    public func fill() {
        // The non-zero winding rule, like the canvas.
        context.fillPath()
    }

    /// Draws the text with a "middle" baseline.
    ///
    /// The context is flipped (y down), so Core Text would draw the glyphs
    /// upside down; the text is flipped back inside a save/restore. The
    /// baseline of the "middle" baseline sits half an em box below the middle
    /// of the text, and a right aligned text is shifted by its width.
    public func fillText(_ text: String, _ x: Double, _ y: Double) {
        guard !text.isEmpty, let line = makeLine(text) else { return }
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let originX: CGFloat = storedTextAlign == .right ? -width : 0
        // Core Text reports the descender as a negative number; the em box
        // spans from -descent to +ascent around the baseline.
        let baseline = -(ascent + descent) / 2
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: CGFloat(x), y: CGFloat(y))
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: originX, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - Fonts

    /// Is the font of the edge print a real condensed font?
    ///
    /// True means the print needs no horizontal squeeze (printSqueeze = 1).
    public var isCondensed: Bool { condensedFont }

    /// The font of the edge print at `size` picture pixels.
    public static func edgeFont(size: Double) -> EdgeFont {
        let pointSize = CGFloat(max(1, size))
        for name in preferredFontNames {
            if let font = makeFont(named: name, size: pointSize) {
                return EdgeFont(font: font, name: name, isCondensed: name != fallbackFontName)
            }
        }
        // The system font of last resort; the call gives nil when the system
        // has no UI font for the language, so the bold system font is used.
        let system = CTFontCreateUIFontForLanguage(.system, pointSize, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, pointSize, nil)
        return EdgeFont(font: system, name: "System", isCondensed: false)
    }

    /// The font with the given PostScript name, or nil when the system does not
    /// have it (Core Text silently substitutes another font otherwise).
    private static func makeFont(named name: String, size: CGFloat) -> CTFont? {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        let actual = CTFontCopyPostScriptName(font) as String
        guard actual.compare(name, options: .caseInsensitive) == .orderedSame else { return nil }
        return font
    }

    /// A Core Text line with the current font; the colour comes from the
    /// context (the fill colour at the moment of the drawing).
    private func makeLine(_ text: String) -> CTLine? {
        guard let font = currentFont else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(attributed)
    }
}

/// Turns the CSS style strings of the painter into Core Graphics colours.
public enum CGColorParser {
    /// The sRGB colour space of the painter's colours.
    public static var sRGB: CGColorSpace {
        if let space = CGColorSpace(name: CGColorSpace.sRGB) {
            return space
        }
        return CGColorSpaceCreateDeviceRGB()
    }

    /// Parses "#rrggbb", "#rgb", "rgb(r, g, b)" and "rgba(r, g, b, a)" into an
    /// sRGB colour. Unknown strings give black.
    public static func color(_ string: String) -> CGColor? {
        guard let components = components(of: string) else {
            return CGColor(colorSpace: sRGB, components: [0, 0, 0, 1])
        }
        return CGColor(colorSpace: sRGB, components: components)
    }

    /// The red, green, blue and alpha components (0...1) of a CSS colour.
    public static func components(of string: String) -> [CGFloat]? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") {
            return hexComponents(String(text.dropFirst()))
        }
        if text.hasPrefix("rgba(") || text.hasPrefix("rgb(") {
            let open = text.hasPrefix("rgba(")
            // "rgb(" is four characters long, "rgba(" five.
            let start = text.index(text.startIndex, offsetBy: open ? 5 : 4)
            guard let close = text.lastIndex(of: ")"), close > start else {
                return nil
            }
            let inner = String(text[start..<close])
            let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || (open && parts.count == 4) else { return nil }
            var values: [CGFloat] = []
            for part in parts {
                guard let number = Double(part) else { return nil }
                values.append(CGFloat(number))
            }
            let red = clamp(values[0] / 255)
            let green = clamp(values[1] / 255)
            let blue = clamp(values[2] / 255)
            let alpha = values.count == 4 ? clamp(values[3]) : 1
            return [red, green, blue, alpha]
        }
        return nil
    }

    private static func hexComponents(_ hex: String) -> [CGFloat]? {
        let characters = Array(hex)
        if characters.count == 3 {
            var values: [CGFloat] = []
            for character in characters {
                guard let digit = digit(character) else { return nil }
                values.append(CGFloat(digit * 17) / 255)
            }
            return [values[0], values[1], values[2], 1]
        }
        guard characters.count == 6 || characters.count == 8 else { return nil }
        var values: [CGFloat] = []
        var index = 0
        while index + 1 < characters.count {
            guard let high = digit(characters[index]), let low = digit(characters[index + 1]) else { return nil }
            values.append(CGFloat(high * 16 + low) / 255)
            index += 2
        }
        if values.count == 3 {
            values.append(1)
        }
        return values
    }

    private static func digit(_ character: Character) -> Int? {
        if character.isNumber { return character.wholeNumberValue }
        switch character {
        case "a": return 10
        case "b": return 11
        case "c": return 12
        case "d": return 13
        case "e": return 14
        case "f": return 15
        default: return nil
        }
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}
#endif
