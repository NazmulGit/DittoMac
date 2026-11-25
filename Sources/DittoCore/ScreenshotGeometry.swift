// ScreenshotGeometry.swift — pure geometry / naming helpers for the screenshot overlay (no AppKit).
//
// Conventions
// - "View space": the per-display overlay view is *flipped* (origin top-left, y grows downwards), in points.
//   `ResizeHandle.top` therefore means the edge at `minY`.
// - "AppKit global": NSScreen coordinates, origin bottom-left of the primary display, y up, points.
// - "Quartz global": CGWindowList / CGDisplayBounds coordinates, origin top-left of the primary display, y down.
// - Pixels: rows top-down, `pixel = point * scale` relative to the display's top-left corner.

import Foundation
import CoreGraphics

public enum ResizeHandle: Int, CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesMinX: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesMaxX: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesMinY: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesMaxY: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    public var isCorner: Bool { self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight }
}

/// Where a floating panel is put relative to an anchor rectangle.
public enum PanelSide: Sendable, Equatable {
    case below, above, right, left
    /// Inside the anchor, along its bottom / right edge (used when no outside side fits).
    case insideBottom, insideRight
}

public enum PanelAlignment: Sendable, Equatable { case leading, center, trailing }

public enum ScreenshotGeometry {

    // MARK: selection basics

    /// Rectangle spanned by two drag points (any order).
    public static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Clips `r` to `bounds` (intersection; zero-size rect at the nearest bounds point when disjoint).
    public static func clamp(_ r: CGRect, to bounds: CGRect) -> CGRect {
        let r = r.standardized
        let minX = min(max(r.minX, bounds.minX), bounds.maxX)
        let minY = min(max(r.minY, bounds.minY), bounds.maxY)
        let maxX = min(max(r.maxX, bounds.minX), bounds.maxX)
        let maxY = min(max(r.maxY, bounds.minY), bounds.maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Shifts `r` (keeping its size, shrinking only if larger than `bounds`) so it lies inside `bounds`.
    public static func keepInside(_ r: CGRect, bounds: CGRect) -> CGRect {
        var o = r.standardized
        o.size.width = min(o.width, bounds.width)
        o.size.height = min(o.height, bounds.height)
        o.origin.x = min(max(o.minX, bounds.minX), bounds.maxX - o.width)
        o.origin.y = min(max(o.minY, bounds.minY), bounds.maxY - o.height)
        return o
    }

    /// Moves the selection by (dx, dy) without leaving `bounds` (arrow-key nudge, drag-to-move).
    public static func nudge(_ r: CGRect, dx: CGFloat, dy: CGFloat, bounds: CGRect) -> CGRect {
        keepInside(r.offsetBy(dx: dx, dy: dy), bounds: bounds)
    }

    /// ⌘A: the whole display.
    public static func wholeDisplay(_ bounds: CGRect) -> CGRect { bounds.standardized }

    /// Rounds a point-space rect outwards to whole points (keeps crops pixel-aligned at integer scales).
    public static func integral(_ r: CGRect) -> CGRect { r.standardized.integral }

    // MARK: handles

    /// Centre points of the eight resize handles.
    public static func handleCenter(_ h: ResizeHandle, of r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    public static func handleRect(_ h: ResizeHandle, of r: CGRect, size: CGFloat) -> CGRect {
        let c = handleCenter(h, of: r)
        return CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)
    }

    /// The handle under `p` (within `tolerance` of its centre). Corners win over edges; for tiny selections
    /// the edge handles are skipped so corners stay reachable.
    public static func hitHandle(at p: CGPoint, in r: CGRect, tolerance: CGFloat) -> ResizeHandle? {
        let r = r.standardized
        guard r.width > 0 || r.height > 0 else { return nil }
        func near(_ h: ResizeHandle) -> CGFloat? {
            let c = handleCenter(h, of: r)
            let d = max(abs(c.x - p.x), abs(c.y - p.y))
            return d <= tolerance ? d : nil
        }
        let corners: [ResizeHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        if let best = corners.compactMap({ h in near(h).map { (h, $0) } }).min(by: { $0.1 < $1.1 }) { return best.0 }
        let small = min(r.width, r.height) < tolerance * 3
        if !small, let best = [ResizeHandle.top, .right, .bottom, .left].compactMap({ h in near(h).map { (h, $0) } }).min(by: { $0.1 < $1.1 }) {
            return best.0
        }
        return nil
    }

    /// True when `p` lies on the selection border band (not on a handle): grabbing it moves the selection.
    public static func isOnBorder(_ p: CGPoint, of r: CGRect, band: CGFloat) -> Bool {
        let outer = r.insetBy(dx: -band, dy: -band)
        let inner = r.insetBy(dx: band, dy: band)
        return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
    }

    /// Drags `handle` of `r` to `p`. Keeps at least `minSize`, stays within `bounds`, and with `aspect`
    /// (width / height, e.g. from ⇧) keeps that ratio (corners only; edges adjust the other dimension symmetrically).
    public static func resize(_ r: CGRect, handle: ResizeHandle, to p: CGPoint, minSize: CGSize = CGSize(width: 4, height: 4),
                              bounds: CGRect, aspect: CGFloat? = nil) -> CGRect {
        let r = r.standardized
        let px = min(max(p.x, bounds.minX), bounds.maxX)
        let py = min(max(p.y, bounds.minY), bounds.maxY)
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if handle.movesMinX { minX = min(px, maxX - minSize.width) }
        if handle.movesMaxX { maxX = max(px, minX + minSize.width) }
        if handle.movesMinY { minY = min(py, maxY - minSize.height) }
        if handle.movesMaxY { maxY = max(py, minY + minSize.height) }
        var out = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        if let a = aspect, a.isFinite, a > 0 {
            if handle.isCorner {
                // Use the dominant dimension, then anchor the opposite corner.
                var w = out.width, h = out.height
                if w / h > a { h = w / a } else { w = h * a }
                let anchorX = handle.movesMinX ? r.maxX : r.minX
                let anchorY = handle.movesMinY ? r.maxY : r.minY
                // Fit inside bounds from the anchor.
                let maxW = handle.movesMinX ? anchorX - bounds.minX : bounds.maxX - anchorX
                let maxH = handle.movesMinY ? anchorY - bounds.minY : bounds.maxY - anchorY
                let s = min(1, maxW / max(w, 0.0001), maxH / max(h, 0.0001))
                w *= s; h *= s
                w = max(w, minSize.width); h = max(h, minSize.height)
                out = CGRect(x: handle.movesMinX ? anchorX - w : anchorX, y: handle.movesMinY ? anchorY - h : anchorY, width: w, height: h)
            } else if handle == .left || handle == .right {
                let h = max(out.width / a, minSize.height)
                out = CGRect(x: out.minX, y: r.midY - h / 2, width: out.width, height: h)
            } else {
                let w = max(out.height * a, minSize.width)
                out = CGRect(x: r.midX - w / 2, y: out.minY, width: w, height: out.height)
            }
            out = keepInside(out, bounds: bounds)
        }
        return out
    }

    // MARK: coordinate spaces

    /// AppKit global point → flipped view point of a display whose AppKit frame is `displayFrame`.
    public static func globalToView(_ p: CGPoint, displayFrame f: CGRect) -> CGPoint {
        CGPoint(x: p.x - f.minX, y: f.maxY - p.y)
    }

    /// Flipped view point → AppKit global point.
    public static func viewToGlobal(_ p: CGPoint, displayFrame f: CGRect) -> CGPoint {
        CGPoint(x: p.x + f.minX, y: f.maxY - p.y)
    }

    /// AppKit global rect → flipped view rect of a display.
    public static func globalRectToView(_ r: CGRect, displayFrame f: CGRect) -> CGRect {
        let r = r.standardized
        return CGRect(x: r.minX - f.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Quartz global rect (top-left origin; CGWindowList bounds) ↔ AppKit global rect. `primaryHeight` = height of
    /// the primary display (the one whose AppKit origin is 0,0). The conversion is its own inverse.
    public static func flipQuartzAppKit(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        let r = r.standardized
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Flipped view rect (points) → pixel rect in the display image (rows top-down), rounded outwards and clipped to
    /// the image. `scale` = image pixels per point for that display (may differ between displays).
    public static func viewRectToPixels(_ r: CGRect, scale: CGFloat, imageSize: CGSize) -> CGRect {
        let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
        let snapped = CGRect(x: (px.minX + 0.001).rounded(.down), y: (px.minY + 0.001).rounded(.down),
                             width: 0, height: 0)
        let maxX = (px.maxX - 0.001).rounded(.up), maxY = (px.maxY - 0.001).rounded(.up)
        let full = CGRect(x: snapped.minX, y: snapped.minY, width: max(0, maxX - snapped.minX), height: max(0, maxY - snapped.minY))
        return clamp(full, to: CGRect(origin: .zero, size: imageSize))
    }

    /// AppKit global point → pixel coordinate inside the display's image.
    public static func globalToPixel(_ p: CGPoint, displayFrame f: CGRect, scale: CGFloat) -> CGPoint {
        let v = globalToView(p, displayFrame: f)
        return CGPoint(x: v.x * scale, y: v.y * scale)
    }

    /// Pixel coordinate inside a display image → AppKit global point.
    public static func pixelToGlobal(_ p: CGPoint, displayFrame f: CGRect, scale: CGFloat) -> CGPoint {
        viewToGlobal(CGPoint(x: p.x / scale, y: p.y / scale), displayFrame: f)
    }

    /// Index of the display (by AppKit frame) containing `p`; the nearest one when the point is in a gap.
    public static func displayIndex(containing p: CGPoint, frames: [CGRect]) -> Int? {
        guard !frames.isEmpty else { return nil }
        if let i = frames.firstIndex(where: { $0.contains(p) }) { return i }
        func dist(_ f: CGRect) -> CGFloat {
            let dx = max(f.minX - p.x, 0, p.x - f.maxX), dy = max(f.minY - p.y, 0, p.y - f.maxY)
            return dx * dx + dy * dy
        }
        return frames.indices.min(by: { dist(frames[$0]) < dist(frames[$1]) })
    }

    // MARK: panel placement

    /// Places a panel of `size` next to `anchor` inside `bounds` (all in the same, flipped space). Tries `sides` in
    /// order and takes the first that fits completely; otherwise uses the last side clamped into `bounds`.
    /// Returns the frame and the side used.
    public static func placePanel(size: CGSize, anchor: CGRect, bounds: CGRect, sides: [PanelSide],
                                  alignment: PanelAlignment = .trailing, gap: CGFloat = 8) -> (frame: CGRect, side: PanelSide) {
        let a = anchor.standardized
        func frame(for side: PanelSide) -> CGRect {
            var x: CGFloat, y: CGFloat
            switch side {
            case .below, .above, .insideBottom:
                switch alignment {
                case .leading: x = a.minX
                case .center: x = a.midX - size.width / 2
                case .trailing: x = a.maxX - size.width
                }
                y = side == .below ? a.maxY + gap : side == .above ? a.minY - gap - size.height : a.maxY - gap - size.height
            case .right, .left, .insideRight:
                switch alignment {
                case .leading: y = a.minY
                case .center: y = a.midY - size.height / 2
                case .trailing: y = a.maxY - size.height
                }
                x = side == .right ? a.maxX + gap : side == .left ? a.minX - gap - size.width : a.maxX - gap - size.width
            }
            return CGRect(x: x, y: y, width: size.width, height: size.height)
        }
        func fitsAcross(_ f: CGRect, _ side: PanelSide) -> Bool {
            // The axis away from the anchor must fit as-is; the other axis may slide.
            switch side {
            case .below, .above, .insideBottom: return f.minY >= bounds.minY && f.maxY <= bounds.maxY && size.width <= bounds.width
            case .right, .left, .insideRight: return f.minX >= bounds.minX && f.maxX <= bounds.maxX && size.height <= bounds.height
            }
        }
        let list = sides.isEmpty ? [PanelSide.below] : sides
        for s in list {
            let f = frame(for: s)
            if fitsAcross(f, s) { return (keepInside(f, bounds: bounds), s) }
        }
        let last = list[list.count - 1]
        return (keepInside(frame(for: last), bounds: bounds), last)
    }

    // MARK: export

    /// JPEG quality limited to 0.6…1.0 (non-finite → 0.9).
    /// Whether a window frame (AppKit global, y up) can still be grabbed: its top `grabHeight` points (the title bar)
    /// must lie fully on one of `visibleFrames` for at least `minWidth` points. A frame that merely touches a screen
    /// by a pixel, or hangs mostly above the menu bar, is unreachable.
    public static func isTitleBarReachable(_ frame: CGRect, visibleFrames: [CGRect],
                                           grabHeight: CGFloat = 40, minWidth: CGFloat = 60) -> Bool {
        let f = frame.standardized
        guard f.width > 0, f.height > 0 else { return false }
        let h = min(grabHeight, f.height)
        let strip = CGRect(x: f.minX, y: f.maxY - h, width: f.width, height: h)
        return visibleFrames.contains { v in
            let i = v.intersection(strip)
            return !i.isNull && i.height >= h - 0.5 && i.width >= min(minWidth, f.width) - 0.5
        }
    }

    /// Whether the displays a capture was taken from are still the displays on the desk (same count, same frames,
    /// order-insensitive, 0.5 pt tolerance). False means displays were added / removed / rearranged mid-capture.
    public static func displaysMatch(captured: [CGRect], current: [CGRect]) -> Bool {
        guard captured.count == current.count else { return false }
        var remaining = current
        for c in captured {
            guard let i = remaining.firstIndex(where: {
                abs($0.minX - c.minX) < 0.5 && abs($0.minY - c.minY) < 0.5
                    && abs($0.width - c.width) < 0.5 && abs($0.height - c.height) < 0.5
            }) else { return false }
            remaining.remove(at: i)
        }
        return true
    }

    public static func clampJPEGQuality(_ q: Double) -> Double {
        guard q.isFinite else { return 0.9 }
        return min(max(q, 0.6), 1.0)
    }
}

// MARK: - File names

public enum ScreenshotFileName {
    public static let defaultTemplate = "Screenshot yyyy-MM-dd 'at' HH.mm.ss"
    static let maxLength = 180

    /// Date tokens recognised in templates (longest first). Everything else is literal; text in 'single quotes' is
    /// always literal ('' = a quote). So "Screenshot yyyy-MM-dd 'at' HH.mm.ss" → "Screenshot 2025-11-24 at 16.00.00".
    public static let tokens = ["yyyy", "EEEE", "MMMM", "MMM", "EEE", "SSS", "yy", "MM", "dd", "HH", "hh", "mm", "ss", "a"]

    /// Formats a template (en_US_POSIX, local time zone unless given), then sanitises it.
    public static func format(template: String, date: Date, timeZone: TimeZone = .current) -> String {
        var t = template.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { t = defaultTemplate }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        func fmt(_ token: String) -> String { f.dateFormat = token; return f.string(from: date) }

        let chars = Array(t)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" {
                if i + 1 < chars.count, chars[i + 1] == "'" { out.append("'"); i += 2; continue }
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "'" {
                        if j + 1 < chars.count, chars[j + 1] == "'" { out.append("'"); j += 2; continue }
                        break
                    }
                    out.append(chars[j]); j += 1
                }
                i = j + 1
                continue
            }
            if let tok = tokens.first(where: { tok in
                i + tok.count <= chars.count && String(chars[i..<(i + tok.count)]) == tok
            }) {
                out += fmt(tok)
                i += tok.count
                continue
            }
            out.append(c)
            i += 1
        }
        return sanitize(out)
    }

    /// Makes a safe single path component: no "/" or ":" (both separators on macOS), no control characters, no leading
    /// dots (hidden files / "..") or "~", trimmed, length-limited; empty → "Screenshot".
    public static func sanitize(_ name: String) -> String {
        var out = ""
        for u in name.unicodeScalars {
            if u == "/" || u == ":" || u == "\\" || u.properties.generalCategory == .control
                || u.properties.generalCategory == .format || u.value == 0 {
                out.unicodeScalars.append("-")
            } else {
                out.unicodeScalars.append(u)
            }
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while let c = out.first, c == "." || c == "~" || c == " " { out.removeFirst() }
        if out.count > maxLength { out = String(out.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return out.isEmpty ? "Screenshot" : out
    }

    /// First non-existing "<base>.<ext>", "<base> 2.<ext>", "<base> 3.<ext>", … in `directory`. Never overwrites.
    public static func uniqueURL(in directory: URL, base: String, ext: String,
                                 exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let b = sanitize(base)
        let e = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        func url(_ n: Int) -> URL {
            let name = n <= 1 ? b : "\(b) \(n)"
            return directory.appendingPathComponent(e.isEmpty ? name : "\(name).\(e)", isDirectory: false)
        }
        var n = 1
        while exists(url(n)) && n < 100_000 { n += 1 }
        if n >= 100_000 { return url(Int(Date().timeIntervalSince1970)) }
        return url(n)
    }
}
