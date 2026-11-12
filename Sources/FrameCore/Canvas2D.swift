// A tiny subset of the HTML Canvas 2D API.
//
// The border painter (Painter.swift) is a line-by-line port of the JavaScript
// painter in wx-spektrafilm's utils/border.js, which only uses this subset.
// Keeping the same call vocabulary is what lets the Swift port and the JS
// original be compared call by call (see `RecordingCanvas` and tools/).

public enum TextAlign: String {
    case left, right
}

/// Canvas 2D-like drawing surface. The origin is the top-left corner of the
/// OUTER picture, y runs down, and one unit is one picture pixel.
public protocol Canvas2D: AnyObject {
    var fillStyle: String { get set }
    var strokeStyle: String { get set }
    var lineWidth: Double { get set }
    var textAlign: TextAlign { get set }
    /// Selects the bold edge-print font at `size` (picture pixels). Text is
    /// always drawn with a "middle" baseline.
    func setFont(size: Double)
    func measureText(_ text: String) -> Double

    func save()
    func restore()
    func translate(_ x: Double, _ y: Double)
    func rotate(_ angle: Double)
    func scale(_ x: Double, _ y: Double)

    func fillRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double)
    func strokeRect(_ x: Double, _ y: Double, _ width: Double, _ height: Double)

    func beginPath()
    func moveTo(_ x: Double, _ y: Double)
    func lineTo(_ x: Double, _ y: Double)
    func arcTo(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ radius: Double)
    func closePath()
    /// Fills the current path with the non-zero winding rule.
    func fill()
    func fillText(_ text: String, _ x: Double, _ y: Double)
}
