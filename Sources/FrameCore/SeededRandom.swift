/// mulberry32, the same tiny deterministic generator as border.js, so a
/// "random" frame is identical to the Mini Program's frame.
public struct SeededRandom {
    private var state: UInt32

    public init(seed: UInt32) {
        state = seed
    }

    public mutating func next() -> Double {
        state = state &+ 0x6D2B79F5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
}

/// JavaScript's Math.round: halves round towards +infinity.
@inline(__always)
func jsRound(_ value: Double) -> Double {
    (value + 0.5).rounded(.down)
}
