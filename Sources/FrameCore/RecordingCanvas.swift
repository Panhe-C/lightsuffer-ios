import Foundation

/// A canvas that draws nothing and logs every call as JSON-friendly values.
/// The JS twin (tools/recording-context.mjs) logs the very same operations, so
/// the geometry of the Swift painter can be compared with border.js.
///
/// The log vocabulary (an array per call):
///
/// * `["save"]`, `["restore"]`, `["beginPath"]`, `["closePath"]`, `["fill"]`
/// * `["translate", x, y]`, `["rotate", angle]`, `["scale", x, y]`
/// * `["fillStyle", "#rrggbb"]`, `["strokeStyle", "..."]`, `["lineWidth", w]`
/// * `["textAlign", "left" | "right"]`, `["font", size]`
/// * `["fillRect", x, y, w, h]`, `["strokeRect", x, y, w, h]`
/// * `["moveTo", x, y]`, `["lineTo", x, y]`, `["arcTo", x1, y1, x2, y2, r]`
/// * `["fillText", text, x, y]`
///
/// `textBaseline` is ignored (the painter always uses "middle"), exactly like
/// in the JS twin.
///
/// `measureText` is a deterministic stub (0.6 em per UTF-16 unit) so that the
/// font fitting does not depend on the installed fonts.
public final class RecordingCanvas: Canvas2D {
    public private(set) var calls: [CanvasCall] = []

    private struct State {
        var fillStyle: String
        var strokeStyle: String
        var lineWidth: Double
        var textAlign: TextAlign
        var fontSize: Double
    }

    private var fontSize: Double = 10
    private var stack: [State] = []

    // The style properties log every assignment, but a `restore()` puts the
    // previous state back silently (like a real canvas).
    private var storedFillStyle = "#000000"
    private var storedStrokeStyle = "#000000"
    private var storedLineWidth = 1.0
    private var storedTextAlign = TextAlign.left

    public init() {}

    public var fillStyle: String {
        get { storedFillStyle }
        set {
            storedFillStyle = newValue
            calls.append(["fillStyle", newValue])
        }
    }
    public var strokeStyle: String {
        get { storedStrokeStyle }
        set {
            storedStrokeStyle = newValue
            calls.append(["strokeStyle", newValue])
        }
    }
    public var lineWidth: Double {
        get { storedLineWidth }
        set {
            storedLineWidth = newValue
            calls.append(["lineWidth", newValue])
        }
    }
    public var textAlign: TextAlign {
        get { storedTextAlign }
        set {
            storedTextAlign = newValue
            calls.append(["textAlign", newValue.rawValue])
        }
    }

    public func setFont(size: Double) {
        fontSize = size
        calls.append(["font", size])
    }

    public func measureText(_ text: String) -> Double {
        Double(text.utf16.count) * fontSize * 0.6
    }

    public func save() {
        stack.append(
            State(
                fillStyle: fillStyle,
                strokeStyle: strokeStyle,
                lineWidth: lineWidth,
                textAlign: textAlign,
                fontSize: fontSize
            )
        )
        calls.append(["save"])
    }

    public func restore() {
        if let state = stack.popLast() {
            storedFillStyle = state.fillStyle
            storedStrokeStyle = state.strokeStyle
            storedLineWidth = state.lineWidth
            storedTextAlign = state.textAlign
            fontSize = state.fontSize
        }
        calls.append(["restore"])
    }

    public func translate(_ x: Double, _ y: Double) { calls.append(["translate", x, y]) }
    public func rotate(_ angle: Double) { calls.append(["rotate", angle]) }
    public func scale(_ x: Double, _ y: Double) { calls.append(["scale", x, y]) }
    public func fillRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        calls.append(["fillRect", x, y, width, height])
    }
    public func strokeRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        calls.append(["strokeRect", x, y, width, height])
    }
    public func beginPath() { calls.append(["beginPath"]) }
    public func moveTo(_ x: Double, _ y: Double) { calls.append(["moveTo", x, y]) }
    public func lineTo(_ x: Double, _ y: Double) { calls.append(["lineTo", x, y]) }
    public func arcTo(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ radius: Double) {
        calls.append(["arcTo", x1, y1, x2, y2, radius])
    }
    public func closePath() { calls.append(["closePath"]) }
    public func fill() { calls.append(["fill"]) }
    public func fillText(_ text: String, _ x: Double, _ y: Double) { calls.append(["fillText", text, x, y]) }
}
