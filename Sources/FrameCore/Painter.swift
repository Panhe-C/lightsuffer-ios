import Foundation

// Port of the Canvas 2D painter of wx-spektrafilm's utils/border.js.
//
// The calls are made in exactly the same order and with the same arguments as
// the JavaScript original, so the call log of `RecordingCanvas` can be compared
// one to one with the JS one (tools/parity-check.mjs).

public struct PaintOptions {
    /// The text printed on the 35mm / 120 film edge. Printed in capitals.
    public var stockName: String
    /// The printed frame number (default 12; 7 on 120 film).
    public var frameNumber: Int?
    /// Print the 120 edge in light grey. nil: guess from the stock name.
    public var monochrome: Bool?
    /// Horizontal squeeze of the 120 edge print. 0.8 squeezes a regular bold
    /// sans like the Mini Program; pass 1 with a real condensed font.
    public var printSqueeze: Double

    public init(
        stockName: String = "",
        frameNumber: Int? = nil,
        monochrome: Bool? = nil,
        printSqueeze: Double = BorderConstants.defaultPrintSqueeze
    ) {
        self.stockName = stockName
        self.frameNumber = frameNumber
        self.monochrome = monochrome
        self.printSqueeze = printSqueeze
    }
}

public enum BorderPainter {
    /// Paint the frame of `layout` into a canvas whose origin is the top-left
    /// corner of the OUTER picture and whose unit is one picture pixel (scale the
    /// canvas for a smaller preview). The photo rectangle is left untouched.
    public static func draw(on ctx: Canvas2D, layout: Layout, options: PaintOptions = PaintOptions()) {
        if layout.style == .none {
            return
        }
        ctx.save()
        fillFrame(ctx, layout)
        if layout.style == .film35 {
            drawFilm35(ctx, layout, options)
        } else if layout.style == .film120 {
            drawFilm120(ctx, layout, options)
        } else if layout.edge != nil {
            drawEdge(ctx, layout)
        } else if layout.style == .polaroid {
            drawPolaroidEdge(ctx, layout)
        }
        ctx.restore()
    }

    // MARK: building blocks

    static func fillFrame(_ ctx: Canvas2D, _ layout: Layout) {
        let left = Double(layout.left), top = Double(layout.top)
        let right = Double(layout.right), bottom = Double(layout.bottom)
        let outerW = Double(layout.outerW), outerH = Double(layout.outerH)
        let photoH = Double(layout.photoH)
        ctx.fillStyle = layout.color
        // Four rectangles: the photo area is never painted.
        ctx.fillRect(0, 0, outerW, top)
        ctx.fillRect(0, outerH - bottom, outerW, bottom)
        ctx.fillRect(0, top, left, photoH)
        ctx.fillRect(outerW - right, top, right, photoH)
    }

    static func roundedRect(_ ctx: Canvas2D, _ x: Double, _ y: Double, _ width: Double, _ height: Double, _ radius: Double) {
        let r = min(radius, width / 2, height / 2)
        ctx.beginPath()
        ctx.moveTo(x + r, y)
        ctx.lineTo(x + width - r, y)
        ctx.arcTo(x + width, y, x + width, y + r, r)
        ctx.lineTo(x + width, y + height - r)
        ctx.arcTo(x + width, y + height, x + width - r, y + height, r)
        ctx.lineTo(x + r, y + height)
        ctx.arcTo(x, y + height, x, y + height - r, r)
        ctx.lineTo(x, y + r)
        ctx.arcTo(x, y, x + r, y, r)
        ctx.closePath()
    }

    /// A small right-pointing triangle, the film's frame arrow.
    static func drawArrow(_ ctx: Canvas2D, _ x: Double, _ centerY: Double, _ size: Double) {
        ctx.beginPath()
        ctx.moveTo(x, centerY - size / 2)
        ctx.lineTo(x + size * 0.9, centerY)
        ctx.lineTo(x, centerY + size / 2)
        ctx.closePath()
        ctx.fill()
    }

    static func fitFontSize(_ ctx: Canvas2D, _ text: String, _ size: Double, _ maxWidth: Double) -> Double {
        ctx.setFont(size: size)
        let width = ctx.measureText(text)
        if width > maxWidth && width > 0 {
            return max(1, size * (maxWidth / width))
        }
        return size
    }

    static func stockText(_ options: PaintOptions) -> String {
        options.stockName.uppercased()
    }

    struct StripGeometry {
        var length: Double
        var across: Double
        var band: Double
        var side: Double
        var photoLength: Double
    }

    /// The edge imprint of one 35mm band.
    static func drawEdgePrint(
        _ ctx: Canvas2D, _ geometry: StripGeometry, kind: String, centerY: Double, fontSize: Double,
        _ options: PaintOptions
    ) {
        let text = stockText(options)
        let number = String(options.frameNumber ?? BorderConstants.defaultFrameNumber)
        let x0 = geometry.side + geometry.photoLength * 0.03
        let x1 = geometry.side + geometry.photoLength * 0.97
        ctx.fillStyle = BorderConstants.edgePrintColor
        let arrow = fontSize * 0.8
        if kind == "top" {
            if !text.isEmpty {
                let size = fitFontSize(ctx, text, fontSize, geometry.photoLength * 0.62)
                ctx.setFont(size: size)
                ctx.textAlign = .left
                ctx.fillText(text, x0, centerY)
            }
            drawArrow(ctx, x1 - arrow * 0.9, centerY, arrow)
        } else {
            ctx.setFont(size: fontSize)
            drawArrow(ctx, x0, centerY, arrow)
            ctx.textAlign = .left
            ctx.fillText(number, x0 + arrow * 1.7, centerY)
            ctx.textAlign = .right
            ctx.fillText("\(number)A", x1, centerY)
        }
    }

    /// Strip coordinates: x runs along the strip, y across it. A portrait picture
    /// rotates the strip a quarter turn.
    static func withStrip(_ ctx: Canvas2D, _ layout: Layout, _ paint: (StripGeometry) -> Void) {
        let horizontal = layout.orientation == .horizontal
        let geometry = StripGeometry(
            length: Double(horizontal ? layout.outerW : layout.outerH),
            across: Double(horizontal ? layout.outerH : layout.outerW),
            band: Double(layout.band),
            side: Double(layout.side),
            photoLength: Double(horizontal ? layout.photoW : layout.photoH)
        )
        ctx.save()
        if !horizontal {
            ctx.translate(Double(layout.outerW), 0)
            ctx.rotate(Double.pi / 2)
        }
        paint(geometry)
        ctx.restore()
    }

    // MARK: 35 mm

    static func drawFilm35(_ ctx: Canvas2D, _ layout: Layout, _ options: PaintOptions) {
        withStrip(ctx, layout) { geometry in
            let band = geometry.band
            let holeLength = band * BorderConstants.sprocketLength
            let holeAcross = band * BorderConstants.sprocketAcross
            let pitch = band * BorderConstants.sprocketPitch
            let count = Int(max(1, ((geometry.length - holeLength) / pitch).rounded(.down) + 1))
            let offset = (geometry.length - (Double(count - 1) * pitch + holeLength)) / 2
            let inset = band * BorderConstants.sprocketInset
            ctx.fillStyle = BorderConstants.sprocketColor
            for index in 0..<count {
                let x = offset + Double(index) * pitch
                roundedRect(ctx, x, inset, holeLength, holeAcross, band * BorderConstants.sprocketRadius)
                ctx.fill()
                roundedRect(
                    ctx, x, geometry.across - inset - holeAcross, holeLength, holeAcross,
                    band * BorderConstants.sprocketRadius
                )
                ctx.fill()
            }
            let fontSize = band * 0.19
            drawEdgePrint(ctx, geometry, kind: "top", centerY: band * 0.84, fontSize: fontSize, options)
            drawEdgePrint(ctx, geometry, kind: "bottom", centerY: geometry.across - band * 0.84, fontSize: fontSize, options)
        }
    }

    // MARK: 120 film

    typealias Point = (Double, Double)

    /// A rounded polygon through four points, each corner with its own radius.
    static func roundedQuad(_ ctx: Canvas2D, _ points: [Point], _ radii: [Double]) {
        let count = points.count
        let mid = ((points[0].0 + points[1].0) / 2, (points[0].1 + points[1].1) / 2)
        ctx.moveTo(mid.0, mid.1)
        for index in 1...count {
            let corner = points[index % count]
            let next = points[(index + 1) % count]
            ctx.arcTo(corner.0, corner.1, next.0, next.1, radii[index % count])
        }
        ctx.closePath()
    }

    /// A thin slanted sliver along an edge of the black strip: the orange light bleed.
    static func fringe(_ ctx: Canvas2D, _ a: Point, _ b: Point, _ inward: Point, _ thickness: Double) {
        ctx.beginPath()
        ctx.moveTo(a.0, a.1)
        ctx.lineTo(b.0, b.1)
        ctx.lineTo(b.0 + inward.0 * thickness, b.1 + inward.1 * thickness)
        ctx.lineTo(a.0 + inward.0 * thickness, a.1 + inward.1 * thickness)
        ctx.closePath()
        ctx.fill()
    }

    static func lerp(_ a: Point, _ b: Point, _ t: Double) -> Point {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
    }

    static func isMono(_ options: PaintOptions) -> Bool {
        options.monochrome ?? BorderLayout.isMonochrome(options.stockName)
    }

    /// The print of one 120 film: stock name, frame arrow with its number and the
    /// half-frame number. Runs along the wide black band: left to right on top
    /// of a landscape picture, bottom to top on the left of a portrait one.
    static func drawFilm120Print(_ ctx: Canvas2D, _ layout: Layout, _ blacks: Sides, _ options: PaintOptions) {
        let film = layout.film!
        let vertical = film.printSide == "left"
        let length = Double(vertical ? layout.photoH : layout.photoW)
        let fontSize = film.wide * 0.5
        let number = String(options.frameNumber ?? BorderConstants.film120FrameNumber)
        let mono = isMono(options)
        let text = stockText(options)
        let squeeze = options.printSqueeze
        ctx.save()
        ctx.fillStyle = mono ? BorderConstants.monoPrintColor : BorderConstants.edgePrintColor
        ctx.textAlign = .left
        // The origin of the print: the centre of the band, at the start of the strip direction.
        if vertical {
            ctx.translate(Double(layout.left) - blacks.left / 2, Double(layout.top + layout.photoH))
            ctx.rotate(-Double.pi / 2)
        } else {
            ctx.translate(Double(layout.left), Double(layout.top) - blacks.top / 2)
        }
        ctx.scale(squeeze, 1)
        // From here on x runs along the strip in squeezed units.
        func unit(_ fraction: Double) -> Double { (fraction * length) / squeeze }
        let arrow = fontSize * 0.8
        if !text.isEmpty {
            ctx.setFont(size: fontSize)
            let room = (length * 0.42) / squeeze
            let width = ctx.measureText(text)
            let size = width > room && width > 0 ? max(1, fontSize * (room / width)) : fontSize
            ctx.setFont(size: size)
            ctx.fillText(text, unit(0.07), 0)
        }
        ctx.setFont(size: fontSize)
        drawArrow(ctx, unit(0.52), 0, arrow)
        ctx.fillText(number, unit(0.52) + arrow * 1.6, 0)
        ctx.fillText("\(number)A", unit(0.86), 0)
        ctx.restore()
    }

    static func drawFilm120(_ ctx: Canvas2D, _ layout: Layout, _ options: PaintOptions) {
        let film = layout.film!
        let blacks = BorderLayout.film120Blacks(layout)
        let left = Double(layout.left), top = Double(layout.top)
        let right = left + Double(layout.photoW)
        let bottom = top + Double(layout.photoH)
        // Outer corners of the black strip, each nudged a little, clockwise from the top left.
        let raw: [Point] = [
            (left - blacks.left, top - blacks.top),
            (right + blacks.right, top - blacks.top),
            (right + blacks.right, bottom + blacks.bottom),
            (left - blacks.left, bottom + blacks.bottom),
        ]
        var corners: [Point] = []
        for (index, point) in raw.enumerated() {
            corners.append((point.0 + film.corners[index][0], point.1 + film.corners[index][1]))
        }
        // The outer corners are rounded, but never so much that the corner of the
        // picture itself would fall outside the strip.
        var radii: [Double] = []
        for index in 0..<4 {
            let dx = index == 0 || index == 3 ? blacks.left : blacks.right
            let dy = index < 2 ? blacks.top : blacks.bottom
            radii.append(max(0.5, min(film.radius, dx * 0.9, dy * 0.9)))
        }
        // The white scan margin: the frame rectangle with the black strip cut out.
        ctx.fillStyle = BorderConstants.scanMarginColor
        ctx.beginPath()
        ctx.moveTo(0, 0)
        ctx.lineTo(Double(layout.outerW), 0)
        ctx.lineTo(Double(layout.outerW), Double(layout.outerH))
        ctx.lineTo(0, Double(layout.outerH))
        ctx.closePath()
        let reversed = [corners[0], corners[3], corners[2], corners[1]]
        roundedQuad(ctx, reversed, [radii[0], radii[3], radii[2], radii[1]])
        ctx.fill()
        // The orange fringe along the outer edge of the black strip.
        let mono = isMono(options)
        ctx.fillStyle = mono ? BorderConstants.film120FringeMono : BorderConstants.film120Fringe
        let thickness = max(1, min(Double(layout.photoW), Double(layout.photoH)) * 0.0016)
        func topEdge(_ from: Double, _ to: Double) {
            fringe(ctx, lerp(corners[0], corners[1], from), lerp(corners[0], corners[1], to), (0, 1), thickness)
        }
        func leftEdge(_ from: Double, _ to: Double) {
            fringe(ctx, lerp(corners[0], corners[3], from), lerp(corners[0], corners[3], to), (1, 0), thickness)
        }
        topEdge(0.06, 0.38)
        topEdge(0.52, 0.6)
        leftEdge(0.1, 0.27)
        drawFilm120Print(ctx, layout, blacks, options)
    }

    // MARK: irregular edges

    /// A wobble in [-1, 1] along one side, 0 at both ends so that the contour
    /// meets the rounded corners tangentially.
    static func wobbleAt(_ spec: Wobble, _ fraction: Double) -> Double {
        let wave = 0.62 * sin(Double.pi * 2 * spec.f1 * fraction + spec.p1) +
            0.38 * sin(Double.pi * 2 * spec.f2 * fraction + spec.p2)
        let edge = min(1, fraction / 0.12, (1 - fraction) / 0.12)
        let taper = edge * edge * (3 - 2 * edge)
        return wave * taper
    }

    /// The irregular film edge: the margin is the band colour (four rectangles); a
    /// contour inside the band, wobbling slightly per side and softly rounded at
    /// the corners, separates it from the film base outside, painted in a slightly
    /// different tone. The contour never gets near the picture.
    static func drawEdge(_ ctx: Canvas2D, _ layout: Layout) {
        let edge = layout.edge!
        let amplitude = 0.32
        let steps = 64
        var insets: [Side: Double] = [:]
        for side in Side.allCases {
            insets[side] = Double(layout[side]) * edge.wobble[side].base
        }
        let outerW = Double(layout.outerW), outerH = Double(layout.outerH)
        let x0 = insets[.left]!
        let x1 = outerW - insets[.right]!
        let y0 = insets[.top]!
        let y1 = outerH - insets[.bottom]!
        let radius = max(0.5, min(edge.radius, (x1 - x0) / 4, (y1 - y0) / 4))
        func offset(_ side: Side, _ fraction: Double) -> Double {
            insets[side]! * (1 + amplitude * wobbleAt(edge.wobble[side], fraction))
        }
        ctx.fillStyle = edge.rim
        ctx.beginPath()
        // The frame rectangle, counter-clockwise ...
        ctx.moveTo(0, 0)
        ctx.lineTo(0, outerH)
        ctx.lineTo(outerW, outerH)
        ctx.lineTo(outerW, 0)
        ctx.closePath()
        // ... and the contour, clockwise, which cuts a hole in it.
        ctx.moveTo(x0 + radius, offset(.top, 0))
        for index in 1...steps {
            let fraction = Double(index) / Double(steps)
            ctx.lineTo(x0 + radius + fraction * (x1 - x0 - 2 * radius), offset(.top, fraction))
        }
        ctx.arcTo(x1, y0, x1, y0 + radius, radius)
        for index in 1...steps {
            let fraction = Double(index) / Double(steps)
            ctx.lineTo(outerW - offset(.right, fraction), y0 + radius + fraction * (y1 - y0 - 2 * radius))
        }
        ctx.arcTo(x1, y1, x1 - radius, y1, radius)
        for index in 1...steps {
            let fraction = Double(index) / Double(steps)
            ctx.lineTo(x1 - radius - fraction * (x1 - x0 - 2 * radius), outerH - offset(.bottom, fraction))
        }
        ctx.arcTo(x0, y1, x0, y1 - radius, radius)
        for index in 1...steps {
            let fraction = Double(index) / Double(steps)
            ctx.lineTo(offset(.left, fraction), y1 - radius - fraction * (y1 - y0 - 2 * radius))
        }
        ctx.arcTo(x0, y0, x0 + radius, y0, radius)
        ctx.closePath()
        ctx.fill()
    }

    // MARK: Polaroid

    static func drawPolaroidEdge(_ ctx: Canvas2D, _ layout: Layout) {
        // A hairline where the print meets the paper.
        let width = max(1, jsRound(Double(min(layout.photoW, layout.photoH)) * 0.0015))
        ctx.strokeStyle = "rgba(0, 0, 0, 0.12)"
        ctx.lineWidth = width
        ctx.strokeRect(
            Double(layout.left) - width / 2,
            Double(layout.top) - width / 2,
            Double(layout.photoW) + width,
            Double(layout.photoH) + width
        )
    }
}
