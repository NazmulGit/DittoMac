import Foundation
import CoreGraphics

/// Pure geometry/colour helpers for the screenshot annotation tools. Coordinates are view points; the canvas
/// is flipped (origin top-left, y grows downwards), so "north" below means smaller y.
public enum AnnotationMath {
    // MARK: Constraints

    /// Snaps `b` so the vector a→b points along a multiple of 45°, preserving its length.
    public static func constrain45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let len = hypot(dx, dy)
        if len == 0 { return b }
        let step = Double.pi / 4
        let ang = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: Double(a.x) + len * cos(ang), y: Double(a.y) + len * sin(ang))
    }

    /// Moves `b` so the rectangle a…b is a square (side = the larger extent), keeping the drag quadrant.
    public static func squareConstrain(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: a.x + (dx < 0 ? -side : side), y: a.y + (dy < 0 ? -side : side))
    }

    /// Normalised rect spanned by two corner points.
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Line width

    public static let minLineWidth: CGFloat = 1
    public static let maxLineWidth: CGFloat = 40
    public static func clampLineWidth(_ w: CGFloat) -> CGFloat {
        w.isFinite ? min(max(w, minLineWidth), maxLineWidth) : minLineWidth
    }
    public static let minFontSize: CGFloat = 8
    public static let maxFontSize: CGFloat = 200
    public static func clampFontSize(_ s: CGFloat) -> CGFloat {
        s.isFinite ? min(max(s, minFontSize), maxFontSize) : 18
    }

    // MARK: Arrow

    public struct ArrowHead: Equatable {
        public var tip: CGPoint
        public var left: CGPoint
        public var right: CGPoint
        /// Where the shaft should end so a thick line doesn't poke through the tip.
        public var shaftEnd: CGPoint
        public var length: CGFloat
    }

    /// Head length grows with the stroke width.
    public static func arrowHeadLength(width: CGFloat) -> CGFloat { max(10, width * 4) }

    /// Triangle for an arrow from `tail` to `tip`. The head shrinks for very short arrows.
    public static func arrowHead(from tail: CGPoint, to tip: CGPoint, width: CGFloat, halfAngleDegrees: CGFloat = 26) -> ArrowHead {
        let dx = Double(tip.x - tail.x), dy = Double(tip.y - tail.y)
        let dist = hypot(dx, dy)
        guard dist > 0 else { return ArrowHead(tip: tip, left: tip, right: tip, shaftEnd: tip, length: 0) }
        let ux = dx / dist, uy = dy / dist
        let len = min(Double(arrowHeadLength(width: width)), dist)
        let a = Double(halfAngleDegrees) * .pi / 180
        func rot(_ s: Double) -> CGPoint {
            // vector pointing back from the tip, rotated by ±a
            let bx = -ux, by = -uy
            let c = cos(s * a), sn = sin(s * a)
            return CGPoint(x: Double(tip.x) + len * (bx * c - by * sn), y: Double(tip.y) + len * (bx * sn + by * c))
        }
        let back = len * cos(a) * 0.85
        return ArrowHead(tip: tip, left: rot(1), right: rot(-1),
                         shaftEnd: CGPoint(x: Double(tip.x) - ux * back, y: Double(tip.y) - uy * back), length: CGFloat(len))
    }

    // MARK: Path smoothing

    /// Drops points closer than `minDistance` to the previously kept one (always keeps first and last).
    public static func decimate(_ pts: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]]
        for p in pts.dropFirst().dropLast() where hypot(p.x - out[out.count - 1].x, p.y - out[out.count - 1].y) >= minDistance {
            out.append(p)
        }
        out.append(pts[pts.count - 1])
        return out
    }

    /// Catmull-Rom spline through the points (endpoints duplicated), `segments` samples per span.
    /// Output stays within the input bounding box expanded by a small overshoot margin.
    public static func smooth(_ pts: [CGPoint], segments: Int = 8) -> [CGPoint] {
        guard pts.count > 2, segments > 0 else { return pts }
        var out: [CGPoint] = [pts[0]]
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            for s in 1...segments {
                let t = CGFloat(s) / CGFloat(segments), t2 = t * t, t3 = t2 * t
                func c(_ a: CGFloat, _ b: CGFloat, _ cc: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * ((2 * b) + (-a + cc) * t + (2 * a - 5 * b + 4 * cc - d) * t2 + (-a + 3 * b - 3 * cc + d) * t3)
                }
                out.append(CGPoint(x: c(p0.x, p1.x, p2.x, p3.x), y: c(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        return out
    }

    // MARK: Hit testing

    public static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / len2, 0), 1)
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }

    public static func distanceToPolyline(_ p: CGPoint, _ pts: [CGPoint]) -> CGFloat {
        guard let first = pts.first else { return .infinity }
        if pts.count == 1 { return hypot(p.x - first.x, p.y - first.y) }
        var best = CGFloat.infinity
        for i in 0..<(pts.count - 1) { best = min(best, distanceToSegment(p, pts[i], pts[i + 1])) }
        return best
    }

    /// Distance from `p` to the outline of `r` (0 on the edge).
    public static func distanceToRectOutline(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let c = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
        return distanceToPolyline(p, c)
    }

    /// Approximate distance from `p` to an ellipse outline inscribed in `r`.
    public static func distanceToEllipseOutline(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        guard r.width > 0, r.height > 0 else { return distanceToRectOutline(p, r) }
        let rx = r.width / 2, ry = r.height / 2
        let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
        let d = hypot(nx, ny)
        if d == 0 { return min(rx, ry) }
        // scale the radial distance by the local radius
        let k = hypot(rx * nx / d, ry * ny / d)
        return abs(d - 1) * k
    }

    public static func ellipseContains(_ p: CGPoint, _ r: CGRect) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        let nx = (p.x - r.midX) / (r.width / 2), ny = (p.y - r.midY) / (r.height / 2)
        return nx * nx + ny * ny <= 1
    }

    // MARK: Resize handles

    /// Eight handles of a selection rectangle. n = minY (top of a flipped view), w = minX.
    public enum Handle: CaseIterable, Sendable { case nw, n, ne, e, se, s, sw, w }

    public static func handlePoint(_ h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .nw: return CGPoint(x: r.minX, y: r.minY)
        case .n: return CGPoint(x: r.midX, y: r.minY)
        case .ne: return CGPoint(x: r.maxX, y: r.minY)
        case .e: return CGPoint(x: r.maxX, y: r.midY)
        case .se: return CGPoint(x: r.maxX, y: r.maxY)
        case .s: return CGPoint(x: r.midX, y: r.maxY)
        case .sw: return CGPoint(x: r.minX, y: r.maxY)
        case .w: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// The handle whose centre is within `radius` of `p` (nearest wins), if any.
    public static func hitHandle(_ p: CGPoint, in r: CGRect, radius: CGFloat) -> Handle? {
        var best: (Handle, CGFloat)?
        for h in Handle.allCases {
            let hp = handlePoint(h, in: r)
            let d = hypot(p.x - hp.x, p.y - hp.y)
            if d <= radius, d < (best?.1 ?? .infinity) { best = (h, d) }
        }
        return best?.0
    }

    /// New rect after dragging `handle` of `r` to `p`; the opposite side stays fixed. Result is normalised
    /// (dragging past the opposite side flips) and never smaller than `minSize` along a dragged axis.
    public static func resize(_ r: CGRect, handle: Handle, to p: CGPoint, minSize: CGFloat = 1) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .nw: minX = p.x; minY = p.y
        case .n: minY = p.y
        case .ne: maxX = p.x; minY = p.y
        case .e: maxX = p.x
        case .se: maxX = p.x; maxY = p.y
        case .s: maxY = p.y
        case .sw: minX = p.x; maxY = p.y
        case .w: minX = p.x
        }
        var out = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        let moves: (x: Bool, y: Bool) = (![.n, .s].contains(handle), ![.e, .w].contains(handle))
        if moves.x && out.width < minSize { out.size.width = minSize }
        if moves.y && out.height < minSize { out.size.height = minSize }
        return out
    }

    /// Maps `p` from rect `old` into rect `new` (used to scale annotation geometry when resizing).
    public static func map(_ p: CGPoint, from old: CGRect, to new: CGRect) -> CGPoint {
        let sx = old.width > 0.0001 ? new.width / old.width : 1
        let sy = old.height > 0.0001 ? new.height / old.height : 1
        return CGPoint(x: new.minX + (p.x - old.minX) * sx,
                       y: new.minY + (p.y - old.minY) * sy)
    }

    // MARK: Steps

    /// Number shown on each annotation: consecutive 1,2,3… for the step ones (in z-order), nil for the rest.
    public static func stepNumbers(isStep: [Bool]) -> [Int?] {
        var n = 0
        return isStep.map { s in
            guard s else { return nil }
            n += 1
            return n
        }
    }

    // MARK: Regions (pixelate / blur)

    /// `r` clamped into `(0,0,size)`; nil when nothing (at least 1×1) remains.
    public static func clampRegion(_ r: CGRect, to size: CGSize) -> CGRect? {
        let c = r.standardized.intersection(CGRect(origin: .zero, size: size))
        guard !c.isNull, c.width >= 1, c.height >= 1 else { return nil }
        return c
    }

    /// Pixel rect (top-left origin, integral, inside the image) for a point rect at `scale` pixels per point.
    public static func pixelRect(for r: CGRect, scale: CGFloat, imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard scale > 0 else { return nil }
        let s = r.standardized
        let x0 = max(0, (s.minX * scale).rounded(.down)), y0 = max(0, (s.minY * scale).rounded(.down))
        let x1 = min(CGFloat(imageWidth), (s.maxX * scale).rounded(.up)), y1 = min(CGFloat(imageHeight), (s.maxY * scale).rounded(.up))
        guard x1 - x0 >= 1, y1 - y0 >= 1 else { return nil }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Effect strength in points (block size / blur radius) from a line width.
    public static func regionStrength(forLineWidth w: CGFloat) -> CGFloat { min(max(w * 3, 4), 36) }

    // MARK: Colour

    public struct RGBA: Equatable, Sendable {
        public var r: Double, g: Double, b: Double, a: Double
        public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    }

    /// Parses `#RRGGBB` or `#RRGGBBAA` (the `#` is optional, case-insensitive, surrounding whitespace ignored).
    public static func parseHex(_ s: String) -> RGBA? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6 || t.count == 8, t.allSatisfy({ $0.isASCII && $0.isHexDigit }), let v = UInt64(t, radix: 16) else { return nil }
        if t.count == 6 {
            return RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
        }
        return RGBA(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255, b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when `includeAlpha`.
    public static func hexString(_ c: RGBA, includeAlpha: Bool = false) -> String {
        func b(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        var s = String(format: "#%02X%02X%02X", b(c.r), b(c.g), b(c.b))
        if includeAlpha { s += String(format: "%02X", b(c.a)) }
        return s
    }

    /// Relative luminance (0…1) of an sRGB colour, for picking readable text/chip colours.
    public static func luminance(_ c: RGBA) -> Double {
        func lin(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
}
