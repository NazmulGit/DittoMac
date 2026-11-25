// AnnotationModel.swift — value-type annotation model (points, relative to the canvas; y grows downwards).
import AppKit
import DittoCore

enum AnnotationRegionMode: Equatable { case pixelate, blur }

extension AnnotationTool {
    var title: String {
        switch self {
        case .select: return "Select"
        case .pen: return "Pen"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .marker: return "Marker"
        case .text: return "Text"
        case .step: return "Step number"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        case .eyedropper: return "Colour picker"
        }
    }
    /// Single-letter shortcut (works while the canvas has focus and no text is being edited).
    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .pen: return "p"
        case .line: return "l"
        case .arrow: return "a"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .marker: return "m"
        case .text: return "t"
        case .step: return "n"
        case .pixelate: return "x"
        case .blur: return "b"
        case .eyedropper: return "i"
        }
    }
    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .marker: return "highlighter"
        case .text: return "textformat"
        case .step: return "1.circle"
        case .pixelate: return "squareshape.split.3x3"
        case .blur: return "drop"
        case .eyedropper: return "eyedropper"
        }
    }
    var tooltip: String { "\(title) (\(String(shortcut).uppercased()))" }
    static func forShortcut(_ c: Character) -> AnnotationTool? {
        allCases.first { $0.shortcut == Character(c.lowercased()) }
    }
    /// Tools whose result depends on the line-width setting.
    var usesLineWidth: Bool {
        switch self {
        case .pen, .line, .arrow, .rectangle, .ellipse, .marker, .pixelate, .blur: return true
        default: return false
        }
    }
}

struct Annotation: Identifiable {
    enum Kind {
        case pen(points: [CGPoint])
        case marker(points: [CGPoint])
        case line(a: CGPoint, b: CGPoint)
        case arrow(a: CGPoint, b: CGPoint)
        case rectangle(CGRect, filled: Bool)
        case ellipse(CGRect, filled: Bool)
        case text(origin: CGPoint, string: String, chip: Bool)
        case step(center: CGPoint)
        case region(CGRect, mode: AnnotationRegionMode)
    }

    static let textPadding: CGFloat = 4

    var id = UUID()
    var kind: Kind
    var color: NSColor
    /// Stroke width (pen/line/arrow/shapes/marker) or effect strength source (pixelate/blur).
    var width: CGFloat
    /// Text size, or the base size of a step badge.
    var fontSize: CGFloat

    var isStep: Bool { if case .step = kind { return true }; return false }
    var isText: Bool { if case .text = kind { return true }; return false }
    var isLineLike: Bool {
        switch kind { case .line, .arrow: return true; default: return false }
    }

    static func markerWidth(for w: CGFloat) -> CGFloat { max(14, w * 4) }
    static func stepDiameter(for fontSize: CGFloat) -> CGFloat { max(16, fontSize * 1.45) }

    // MARK: Text metrics
    static func font(size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }
    static func textContentSize(_ s: String, fontSize: CGFloat) -> CGSize {
        let str = s.isEmpty ? " " : s
        let r = (str as NSString).boundingRect(with: CGSize(width: 10_000, height: 10_000),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading],
                                               attributes: [.font: font(size: fontSize)])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    // MARK: Geometry
    /// Geometry bounding box (no stroke inflation); used for selection handles and resizing.
    var frame: CGRect {
        switch kind {
        case .pen(let p), .marker(let p): return Self.bbox(p)
        case .line(let a, let b), .arrow(let a, let b): return AnnotationMath.rect(from: a, to: b)
        case .rectangle(let r, _), .ellipse(let r, _), .region(let r, _): return r
        case .text(let o, let s, _):
            let sz = Self.textContentSize(s, fontSize: fontSize)
            return CGRect(x: o.x, y: o.y, width: sz.width + 2 * Self.textPadding, height: sz.height + 2 * Self.textPadding)
        case .step(let c):
            let d = Self.stepDiameter(for: fontSize)
            return CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        }
    }

    static func bbox(_ p: [CGPoint]) -> CGRect {
        guard let f = p.first else { return .zero }
        var minX = f.x, maxX = f.x, minY = f.y, maxY = f.y
        for q in p { minX = min(minX, q.x); maxX = max(maxX, q.x); minY = min(minY, q.y); maxY = max(maxY, q.y) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Rect needing redraw / selection outline, including stroke width and arrow head.
    var visualBounds: CGRect {
        switch kind {
        case .marker: return frame.insetBy(dx: -Self.markerWidth(for: width) / 2, dy: -Self.markerWidth(for: width) / 2)
        case .arrow: return frame.insetBy(dx: -AnnotationMath.arrowHeadLength(width: width), dy: -AnnotationMath.arrowHeadLength(width: width))
        case .pen, .line, .rectangle, .ellipse: return frame.insetBy(dx: -width / 2 - 1, dy: -width / 2 - 1)
        default: return frame.insetBy(dx: -1, dy: -1)
        }
    }

    func hit(_ p: CGPoint) -> Bool {
        switch kind {
        case .pen(let pts): return AnnotationMath.distanceToPolyline(p, pts) <= width / 2 + 4
        case .marker(let pts): return AnnotationMath.distanceToPolyline(p, pts) <= Self.markerWidth(for: width) / 2 + 2
        case .line(let a, let b), .arrow(let a, let b): return AnnotationMath.distanceToSegment(p, a, b) <= width / 2 + 5
        case .rectangle(let r, let filled):
            if filled { return r.insetBy(dx: -4, dy: -4).contains(p) }
            return AnnotationMath.distanceToRectOutline(p, r) <= width / 2 + 5
        case .ellipse(let r, let filled):
            if filled { return AnnotationMath.ellipseContains(p, r.insetBy(dx: -4, dy: -4)) }
            return AnnotationMath.distanceToEllipseOutline(p, r) <= width / 2 + 5
        case .text, .region: return frame.contains(p)
        case .step(let c): return hypot(p.x - c.x, p.y - c.y) <= Self.stepDiameter(for: fontSize) / 2 + 2
        }
    }

    func translated(by d: CGSize) -> Annotation {
        var a = self
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.width, y: p.y + d.height) }
        switch kind {
        case .pen(let p): a.kind = .pen(points: p.map(t))
        case .marker(let p): a.kind = .marker(points: p.map(t))
        case .line(let p, let q): a.kind = .line(a: t(p), b: t(q))
        case .arrow(let p, let q): a.kind = .arrow(a: t(p), b: t(q))
        case .rectangle(let r, let f): a.kind = .rectangle(r.offsetBy(dx: d.width, dy: d.height), filled: f)
        case .ellipse(let r, let f): a.kind = .ellipse(r.offsetBy(dx: d.width, dy: d.height), filled: f)
        case .text(let o, let s, let c): a.kind = .text(origin: t(o), string: s, chip: c)
        case .step(let c): a.kind = .step(center: t(c))
        case .region(let r, let m): a.kind = .region(r.offsetBy(dx: d.width, dy: d.height), mode: m)
        }
        return a
    }

    /// Scales the geometry as `old` is stretched to `new`.
    func transformed(from old: CGRect, to new: CGRect) -> Annotation {
        var a = self
        func m(_ p: CGPoint) -> CGPoint { AnnotationMath.map(p, from: old, to: new) }
        func mr(_ r: CGRect) -> CGRect { AnnotationMath.rect(from: m(r.origin), to: m(CGPoint(x: r.maxX, y: r.maxY))) }
        let sy = old.height > 0.0001 ? new.height / old.height : 1
        let sx = old.width > 0.0001 ? new.width / old.width : 1
        switch kind {
        case .pen(let p): a.kind = .pen(points: p.map(m))
        case .marker(let p): a.kind = .marker(points: p.map(m))
        case .line(let p, let q): a.kind = .line(a: m(p), b: m(q))
        case .arrow(let p, let q): a.kind = .arrow(a: m(p), b: m(q))
        case .rectangle(let r, let f): a.kind = .rectangle(mr(r), filled: f)
        case .ellipse(let r, let f): a.kind = .ellipse(mr(r), filled: f)
        case .text(let o, let s, let c):
            a.kind = .text(origin: m(o), string: s, chip: c)
            a.fontSize = AnnotationMath.clampFontSize(fontSize * sy)
        case .step(let c):
            a.kind = .step(center: CGPoint(x: new.midX, y: new.midY))
            _ = c
            a.fontSize = AnnotationMath.clampFontSize(fontSize * max(sx, sy))
        case .region(let r, let md): a.kind = .region(mr(r), mode: md)
        }
        return a
    }
}
