import Foundation

// Port of the layout math of wx-spektrafilm's utils/border.js
// (computeLayout, film120Geometry, edgeGeometry). Everything is expressed in
// the pixels of the picture, so a layout scales linearly with the photo.

public struct Sides: Codable, Equatable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    subscript(side: Side) -> Double {
        switch side {
        case .left: return left
        case .top: return top
        case .right: return right
        case .bottom: return bottom
        }
    }
}

public enum Side: CaseIterable {
    case left, top, right, bottom
}

public struct Wobble: Codable, Equatable {
    public var base: Double
    public var f1: Double
    public var p1: Double
    public var f2: Double
    public var p2: Double
}

public struct WobbleSet: Codable, Equatable {
    public var left: Wobble
    public var top: Wobble
    public var right: Wobble
    public var bottom: Wobble

    subscript(side: Side) -> Wobble {
        switch side {
        case .left: return left
        case .top: return top
        case .right: return right
        case .bottom: return bottom
        }
    }
}

public struct EdgeGeometry: Codable, Equatable {
    public var rim: String
    public var widths: Sides
    public var wobble: WobbleSet
    public var radius: Double
}

public struct Film120Geometry: Codable, Equatable {
    /// "top" for a landscape picture, "left" for a portrait or square one.
    public var printSide: String
    public var wide: Double
    public var black: Sides
    public var white: Sides
    /// Nudge of the four outer corners of the black strip, clockwise from top left.
    public var corners: [[Double]]
    public var radius: Double

    enum CodingKeys: String, CodingKey {
        case printSide = "print"
        case wide, black, white, corners, radius
    }
}

public enum Orientation: String, Codable {
    case horizontal, vertical
}

public struct Layout: Codable, Equatable {
    public var style: BorderStyle
    public var photoW: Int
    public var photoH: Int
    public var left: Int
    public var top: Int
    public var right: Int
    public var bottom: Int
    public var color: String
    public var orientation: Orientation
    public var band: Int
    public var side: Int
    public var edge: EdgeGeometry?
    public var film: Film120Geometry?
    public var outerW: Int
    public var outerH: Int

    subscript(side: Side) -> Int {
        switch side {
        case .left: return left
        case .top: return top
        case .right: return right
        case .bottom: return bottom
        }
    }
}

public enum LayoutError: Error, CustomStringConvertible {
    case invalidDimension(Double)

    public var description: String {
        switch self {
        case .invalidDimension(let value): return "Invalid picture dimension: \(value)"
        }
    }
}

public enum BorderLayout {
    /// The JS `positive()`: the dimension is rounded and must be at least one pixel.
    public static func positive(_ value: Double) throws -> Int {
        let number = jsRound(value)
        guard number.isFinite, number >= 1, number <= Double(Int.max) else {
            throw LayoutError.invalidDimension(value)
        }
        return Int(number)
    }

    /// Margins are at least one pixel so that a tiny picture still shows a frame.
    public static func margin(_ fraction: Double, _ basis: Double) -> Int {
        Int(max(1, jsRound(fraction * basis)))
    }

    /// The geometry of the 120 film edge for a picture whose short side is `short` pixels.
    static func film120Geometry(horizontal: Bool, short: Double) -> Film120Geometry {
        var random = SeededRandom(seed: BorderConstants.film120Seed)
        var r: [Double] = []
        for _ in 0..<24 {
            r.append(random.next())
        }
        let wide = BorderConstants.film120PrintBand * short
        let black: Sides
        if horizontal {
            black = Sides(
                left: 0.008 * short * (0.8 + 0.5 * r[1]),
                top: wide * (0.96 + 0.08 * r[0]),
                right: 0.0125 * short * (0.8 + 0.5 * r[2]),
                bottom: (0.011 * (0.8 + 0.5 * r[3]) + 0.003) * short
            )
        } else {
            black = Sides(
                left: wide * (0.96 + 0.08 * r[0]),
                top: 0.0075 * short * (0.8 + 0.5 * r[2]),
                right: 0.012 * short * (0.8 + 0.5 * r[1]),
                bottom: 0.011 * short * (0.8 + 0.5 * r[3])
            )
        }
        let m0 = BorderConstants.film120Margin * short
        let white = Sides(
            left: m0 * (1 + 0.9 * r[4]),
            top: m0 * (0.6 + 0.9 * r[5]),
            right: m0 * (0.5 + 0.7 * r[6]),
            bottom: m0 * (0.9 + r[7])
        )
        var corners: [[Double]] = []
        for index in 0..<4 {
            corners.append([
                (r[8 + index * 2] - 0.5) * BorderConstants.film120Jitter * short,
                (r[9 + index * 2] - 0.5) * BorderConstants.film120Jitter * short,
            ])
        }
        return Film120Geometry(
            printSide: horizontal ? "top" : "left",
            wide: wide,
            black: black,
            white: white,
            corners: corners,
            radius: BorderConstants.film120Radius * short
        )
    }

    /// The geometry of an irregular film edge.
    static func edgeGeometry(_ spec: EdgeSpec, short: Double) -> EdgeGeometry {
        var random = SeededRandom(seed: spec.seed)
        var levels = [0.04, 0.38, 0.68, 1.0]
        var index = levels.count - 1
        while index > 0 {
            let pick = Int((random.next() * Double(index + 1)).rounded(.down))
            levels.swapAt(index, pick)
            index -= 1
        }
        func width(_ level: Double) -> Double {
            (spec.lo + (spec.hi - spec.lo) * level) * short
        }
        let widths = Sides(
            left: width(levels[0]), top: width(levels[1]), right: width(levels[2]), bottom: width(levels[3])
        )
        // The JS loop draws five numbers per side, in the order left, top, right, bottom.
        func nextWobble() -> Wobble {
            let base = 0.36 + 0.12 * random.next()
            let f1 = 1.4 + 1.2 * random.next()
            let p1 = random.next() * Double.pi * 2
            let f2 = 3.6 + 2.2 * random.next()
            let p2 = random.next() * Double.pi * 2
            return Wobble(base: base, f1: f1, p1: p1, f2: f2, p2: p2)
        }
        let left = nextWobble()
        let top = nextWobble()
        let right = nextWobble()
        let bottom = nextWobble()
        return EdgeGeometry(
            rim: spec.rim,
            widths: widths,
            wobble: WobbleSet(left: left, top: top, right: right, bottom: bottom),
            radius: min(widths.left, widths.top, widths.right, widths.bottom) * 1.6
        )
    }

    /// The frame around a picture of photoW x photoH pixels (top-down margins).
    public static func compute(style: BorderStyle, photoW: Int, photoH: Int) throws -> Layout {
        try compute(style: style, photoW: Double(photoW), photoH: Double(photoH))
    }

    /// The frame around a picture of photoW x photoH pixels (top-down margins).
    /// The dimensions are rounded like the JS `positive()`.
    public static func compute(style: BorderStyle, photoW: Double, photoH: Double) throws -> Layout {
        let width = try positive(photoW)
        let height = try positive(photoH)
        let w = Double(width)
        let h = Double(height)
        let short = min(w, h)
        let long = max(w, h)
        // A 3:2 picture gets the real film proportions; a panorama does not get
        // an absurdly wide band.
        let filmBasis = min(long, short * 1.5)
        let horizontal = width >= height
        var layout = Layout(
            style: style, photoW: width, photoH: height,
            left: 0, top: 0, right: 0, bottom: 0,
            color: style.color,
            orientation: horizontal ? .horizontal : .vertical,
            band: 0, side: 0, edge: nil, film: nil, outerW: 0, outerH: 0
        )
        switch style {
        case .thinWhite:
            let edge = margin(0.035, short)
            layout.left = edge; layout.top = edge; layout.right = edge; layout.bottom = edge
        case .polaroid:
            let edge = margin(0.06, short)
            layout.left = edge; layout.top = edge; layout.right = edge
            layout.bottom = margin(0.22, short)
        case .black:
            let edge = margin(0.04, short)
            layout.left = edge; layout.top = edge; layout.right = edge; layout.bottom = edge
        case .film35:
            let band = margin(BorderConstants.film35Band, filmBasis)
            let side = margin(BorderConstants.film35Side, long)
            layout.band = band
            layout.side = side
            // The strip runs along the long edge: bands on the long sides.
            if horizontal {
                layout.left = side; layout.right = side; layout.top = band; layout.bottom = band
            } else {
                layout.left = band; layout.right = band; layout.top = side; layout.bottom = side
            }
        case .edgeBlackThin, .edgeBlack, .edgeWhiteThin, .edgeWhite:
            let edge = edgeGeometry(style.edgeSpec!, short: short)
            layout.left = margin(1, edge.widths.left)
            layout.top = margin(1, edge.widths.top)
            layout.right = margin(1, edge.widths.right)
            layout.bottom = margin(1, edge.widths.bottom)
            layout.edge = edge
        case .film120:
            let film = film120Geometry(horizontal: width > height, short: short)
            func total(_ side: Side) -> Int {
                Int(max(1, jsRound(film.white[side] + film.black[side])))
            }
            layout.left = total(.left)
            layout.top = total(.top)
            layout.right = total(.right)
            layout.bottom = total(.bottom)
            layout.band = Int(jsRound(film.wide))
            layout.film = film
        case .none:
            break
        }
        layout.outerW = width + layout.left + layout.right
        layout.outerH = height + layout.top + layout.bottom
        return layout
    }

    /// The black widths of the 120 edge, clamped so that a tiny picture keeps a
    /// sliver of white scan margin.
    public static func film120Blacks(_ layout: Layout) -> Sides {
        let black = layout.film!.black
        return Sides(
            left: min(black.left, Double(layout.left) * 0.9),
            top: min(black.top, Double(layout.top) * 0.9),
            right: min(black.right, Double(layout.right) * 0.9),
            bottom: min(black.bottom, Double(layout.bottom) * 0.9)
        )
    }

    /// The width of the white scan margin on one side of the picture.
    public static func film120Edge(_ layout: Layout, _ side: Side) -> Double {
        Double(layout[side]) - film120Blacks(layout)[side]
    }

    /// The result of `fit`: the frame around a picture that fits the budget.
    public struct FittedLayout {
        public let layout: Layout
        public let photoW: Int
        public let photoH: Int
    }

    /// A frame for the export: the picture is shrunk until the framed picture
    /// fits `maxOuterLongEdge`.
    ///
    /// `fit(width, height, targetLongEdge)` returns the smaller picture size to
    /// try; the loop converges because the layout is linear. This is the port
    /// of `fitLayout` in border.js.
    public static func fit(
        style: BorderStyle,
        photoW: Int,
        photoH: Int,
        maxOuterLongEdge: Int,
        fit: (Int, Int, Int) -> (width: Int, height: Int)
    ) throws -> FittedLayout {
        var width = try positive(Double(photoW))
        var height = try positive(Double(photoH))
        var layout = try compute(style: style, photoW: width, photoH: height)
        let cap = max(1, maxOuterLongEdge)
        for guardStep in 0..<24 {
            let outerLong = max(layout.outerW, layout.outerH)
            if outerLong <= cap { break }
            let photoLong = max(width, height)
            let ratio = Double(outerLong) / Double(photoLong)
            // Aim slightly below the exact solution so that rounding converges.
            let targetLong = max(1, min(photoLong - 1, Int(floor(Double(cap) / ratio)) - guardStep))
            let next = fit(width, height, targetLong)
            width = try positive(Double(next.width))
            height = try positive(Double(next.height))
            layout = try compute(style: style, photoW: width, photoH: height)
        }
        return FittedLayout(layout: layout, photoW: width, photoH: height)
    }

    /// The default `fit`: the picture is scaled down, its aspect ratio is kept.
    public static func scaledFit(
        _ width: Int, _ height: Int, _ targetLongEdge: Int
    ) -> (width: Int, height: Int) {
        let long = max(width, height)
        guard long > 0 else { return (max(1, width), max(1, height)) }
        let ratio = Double(targetLongEdge) / Double(long)
        return (
            max(1, Int(jsRound(Double(width) * ratio))),
            max(1, Int(jsRound(Double(height) * ratio)))
        )
    }

    /// The miniature of a style for the picker: the frame boxes as fractions
    /// (0..1) of a sample picture's outer size.
    public struct ThumbnailGeometry: Equatable {
        public var style: BorderStyle
        public var aspect: Double
        public var left: Double
        public var right: Double
        public var top: Double
        public var bottom: Double
        public var color: String
        public var orientation: Orientation
        /// The colour of the outer ring (only the 120 film has a second colour).
        public var outerColor: String
        /// The box of the inner colour, as fractions of the outer size.
        public var ring: Sides?
    }

    /// A CSS-free miniature of a style for the picker.
    public static func thumbnailGeometry(
        style: BorderStyle, sampleW: Int = 300, sampleH: Int = 200
    ) throws -> ThumbnailGeometry {
        let layout = try compute(style: style, photoW: sampleW, photoH: sampleH)
        var left = Double(layout.left)
        var right = Double(layout.right)
        var top = Double(layout.top)
        var bottom = Double(layout.bottom)
        var outerW = Double(layout.outerW)
        var outerH = Double(layout.outerH)
        if layout.edge != nil {
            // The edge of these styles is far too thin to read in a card.
            let least = BorderConstants.edgeThumbnailMin * Double(min(layout.photoW, layout.photoH))
            left = max(left, least)
            top = max(top, least)
            right = max(right, least)
            bottom = max(bottom, least)
            outerW = Double(layout.photoW) + left + right
            outerH = Double(layout.photoH) + top + bottom
        }
        var ring: Sides?
        if layout.film != nil {
            ring = Sides(
                left: film120Edge(layout, .left) / outerW,
                top: film120Edge(layout, .top) / outerH,
                right: film120Edge(layout, .right) / outerW,
                bottom: film120Edge(layout, .bottom) / outerH
            )
        }
        return ThumbnailGeometry(
            style: layout.style,
            aspect: outerW / outerH,
            left: left / outerW,
            right: right / outerW,
            top: top / outerH,
            bottom: bottom / outerH,
            color: layout.color,
            orientation: layout.orientation,
            outerColor: layout.film != nil ? BorderConstants.scanMarginColor : "",
            ring: ring
        )
    }

    /// Is this stock a black-and-white one? Its edge print is light, not amber.
    public static func isMonochrome(_ stockName: String?) -> Bool {
        guard let name = stockName, !name.isEmpty else { return false }
        let pattern = #"(tri-?x|hp5|fp4|delta|t-?max|tmax|acros|neopan|plus-?x|pan\s?f|ilford|b\s?&\s?w|\bbw\b|mono|black\s+and\s+white|黑白)"#
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
