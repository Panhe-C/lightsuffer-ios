import Foundation

/// A recorded canvas call: `["fillRect", x, y, w, h]`, `["moveTo", x, y]`,
/// `["font", size]`, `["save"]`, ... The very same vocabulary is produced by the
/// JS twin `tools/recording-context.mjs`, so the two painters can be compared
/// call by call.
public typealias CanvasCall = [Any]

/// The 2D transformation matrix of a canvas, in the Canvas 2D convention
/// `[a, b, c, d, e, f]`: the point `(x, y)` is mapped to
/// `(a*x + c*y + e, b*x + d*y + f)`.
public struct CanvasMatrix: Equatable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var e: Double
    public var f: Double

    public init(a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = e
        self.f = f
    }

    public static let identity = CanvasMatrix(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    public static func translation(x: Double, y: Double) -> CanvasMatrix {
        CanvasMatrix(a: 1, b: 0, c: 0, d: 1, e: x, f: y)
    }

    public static func scaling(x: Double, y: Double) -> CanvasMatrix {
        CanvasMatrix(a: x, b: 0, c: 0, d: y, e: 0, f: 0)
    }

    public static func rotation(_ angle: Double) -> CanvasMatrix {
        CanvasMatrix(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle), e: 0, f: 0)
    }

    /// Maps a point through the matrix.
    public func apply(_ x: Double, _ y: Double) -> [Double] {
        [a * x + c * y + e, b * x + d * y + f]
    }

    /// `self` followed by `other` (the JS `multiply(matrix, transform)`).
    public func multiplied(by other: CanvasMatrix) -> CanvasMatrix {
        CanvasMatrix(
            a: a * other.a + c * other.b,
            b: b * other.a + d * other.b,
            c: a * other.c + c * other.d,
            d: b * other.c + d * other.d,
            e: a * other.e + c * other.f + e,
            f: b * other.e + d * other.f + f
        )
    }
}

/// Replays a recorded call log.
///
/// The painter records the raw arguments of every call; the transform stack is
/// replayed here so that the points of every call can be read in device space
/// (the coordinates of the outer picture). The JS twin of this replay lives in
/// `tools/recording-context.mjs`.
public enum CallLog {
    /// The points every call touches, in device space, in the order of the calls.
    ///
    /// * `fillRect` / `strokeRect`: the two corners of the rectangle.
    /// * `moveTo` / `lineTo` / `arcTo`: the points of the path.
    /// * `fill`: every point of the path since the last `beginPath`.
    /// * `fillText`: the anchor point of the text.
    public static func devicePoints(_ calls: [CanvasCall]) -> [[[Double]]] {
        var matrix = CanvasMatrix.identity
        var stack: [CanvasMatrix] = []
        var path: [[Double]] = []
        var result: [[[Double]]] = []
        result.reserveCapacity(calls.count)

        func number(_ call: CanvasCall, _ index: Int) -> Double {
            guard call.count > index, let value = call[index] as? Double else { return 0 }
            return value
        }

        for call in calls {
            guard let op = call.first as? String else {
                result.append([])
                continue
            }
            switch op {
            case "save":
                stack.append(matrix)
                result.append([])
            case "restore":
                if let saved = stack.popLast() { matrix = saved }
                result.append([])
            case "translate":
                matrix = matrix.multiplied(by: .translation(x: number(call, 1), y: number(call, 2)))
                result.append([])
            case "rotate":
                matrix = matrix.multiplied(by: .rotation(number(call, 1)))
                result.append([])
            case "scale":
                matrix = matrix.multiplied(by: .scaling(x: number(call, 1), y: number(call, 2)))
                result.append([])
            case "fillRect", "strokeRect":
                let x = number(call, 1), y = number(call, 2)
                let width = number(call, 3), height = number(call, 4)
                result.append([matrix.apply(x, y), matrix.apply(x + width, y + height)])
            case "moveTo", "lineTo":
                let point = matrix.apply(number(call, 1), number(call, 2))
                path.append(point)
                result.append([point])
            case "arcTo":
                let first = matrix.apply(number(call, 1), number(call, 2))
                let second = matrix.apply(number(call, 3), number(call, 4))
                path.append(first)
                path.append(second)
                result.append([first, second])
            case "beginPath":
                path = []
                result.append([])
            case "closePath":
                result.append([])
            case "fill":
                result.append(path)
            case "fillText":
                result.append([matrix.apply(number(call, 2), number(call, 3))])
            default:
                result.append([])
            }
        }
        return result
    }
}
