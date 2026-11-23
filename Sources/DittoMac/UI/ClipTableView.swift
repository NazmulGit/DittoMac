// ClipTableView.swift — the Quick Paste clip list: themed rows, n-line descriptions, thumbnails,
// colour swatches, row symbols, first-ten index, pasted indicator, sticky pin, search highlight.

import AppKit
import ImageIO
import DittoCore

// MARK: - Table

@MainActor
final class ClipTableView: NSTableView {
    /// ⌘C / Edit › Copy while the list is focused.
    var onCopy: (() -> Void)?
    /// Called before a context menu is shown for a right-clicked row.
    var onWillShowMenu: (() -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedRow >= 0 }
        return super.validateUserInterfaceItem(item)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p)
        if r >= 0, !selectedRowIndexes.contains(r) {
            selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        }
        onWillShowMenu?()
        return super.menu(for: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Row view (themed background + selection)

@MainActor
final class ClipRowView: NSTableRowView {
    var rowIndex = 0 { didSet { if oldValue != rowIndex { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        AppTheme.current.rowBackground(odd: rowIndex % 2 == 0).setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        AppTheme.current.selectionBackground(emphasized: isEmphasized).setFill()
        bounds.fill()
    }

    override var isEmphasized: Bool {
        didSet { needsDisplay = true; subviews.forEach { $0.needsDisplay = true } }
    }

    override var isSelected: Bool {
        didSet { subviews.forEach { $0.needsDisplay = true } }
    }
}

// MARK: - Row model

struct ClipRowModel {
    var clip: Clip
    var row: Int
    var kind: ClipKind
    var thumbnail: NSImage?
    var swatch: NSColor?
    var indexLabel: String?
    var showPasted: Bool
    var showSymbols: Bool     // "!" (in group) only meaningful in history view
    var highlighter: QuickPasteHighlighter?
    /// Rich description (from the clip's RTF) when "Draw rich text" is on; nil falls back to plain text.
    var rich: NSAttributedString?
}

// MARK: - Cell view (custom drawn for speed)

@MainActor
final class ClipCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ClipCell")

    var model: ClipRowModel? { didSet { toolTip = model.map { String($0.clip.text.prefix(300)) }; needsDisplay = true } }
    var font: NSFont = .systemFont(ofSize: 13) { didSet { needsDisplay = true } }
    var linesPerRow = 2

    override var backgroundStyle: NSView.BackgroundStyle { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    private var isRowSelected: Bool { (superview as? NSTableRowView)?.isSelected ?? false }
    private var isRowEmphasized: Bool { (superview as? NSTableRowView)?.isEmphasized ?? true }

    private static let folderImage = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Group")
    private static let pinImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Sticky")

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model else { return }
        let theme = AppTheme.current
        let selected = isRowSelected
        let textColor = selected ? theme.selectionText(emphasized: isRowEmphasized) : theme.rowText(odd: m.row % 2 == 0)
        let secondary = textColor.withAlphaComponent(0.55)
        let lineH = ceil(font.ascender - font.descender + font.leading)
        var rect = bounds.insetBy(dx: 4, dy: 3)

        // Right edge: pasted dot + sticky pin.
        var rightInset: CGFloat = 0
        if m.showPasted {
            let d: CGFloat = 6
            let dot = NSRect(x: rect.maxX - d, y: rect.minY + (lineH - d) / 2, width: d, height: d)
            theme.pastedColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
            rightInset += d + 4
        }
        if m.clip.isSticky, let pin = Self.pinImage {
            let s = min(lineH, 12)
            let r = NSRect(x: rect.maxX - rightInset - s, y: rect.minY + (lineH - s) / 2, width: s, height: s)
            Self.tinted(pin, secondary).draw(in: r)
            rightInset += s + 4
        }
        rect.size.width -= rightInset

        // First-ten index.
        if let idx = m.indexLabel {
            let small = NSFont.monospacedDigitSystemFont(ofSize: max(font.pointSize - 2, 8), weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: secondary]
            let w: CGFloat = small.pointSize * 0.75 + 4
            (idx as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY + (lineH - small.pointSize * 1.2) / 2), withAttributes: attrs)
            rect.origin.x += w
            rect.size.width -= w
        }

        // Group folder icon.
        if m.clip.isGroup, let folder = Self.folderImage {
            let s = min(lineH, 16)
            Self.tinted(folder, selected ? textColor : .systemBlue).draw(in: NSRect(x: rect.minX, y: rect.minY + (lineH - s) / 2, width: s, height: s))
            rect.origin.x += s + 4
            rect.size.width -= s + 4
        }

        // Thumbnail.
        if let img = m.thumbnail, img.size.width > 0, img.size.height > 0 {
            let maxH = rect.height
            let maxW = min(rect.width * 0.4, maxH * 2.5)
            let scale = min(maxH / img.size.height, maxW / img.size.width, 1)
            let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
            let r = NSRect(x: rect.minX, y: rect.minY + (maxH - size.height) / 2, width: size.width, height: size.height)
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            rect.origin.x += size.width + 6
            rect.size.width -= size.width + 6
        }

        // Colour swatch.
        if let c = m.swatch {
            let s = min(lineH, 14)
            let r = NSRect(x: rect.minX, y: rect.minY + (lineH - s) / 2, width: s, height: s)
            c.setFill()
            let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            p.fill()
            secondary.setStroke()
            p.lineWidth = 0.5
            p.stroke()
            rect.origin.x += s + 5
            rect.size.width -= s + 5
        }

        guard rect.width > 4 else { return }

        // Symbols + description text.
        let text = NSMutableAttributedString()
        var symbols = ""
        if m.clip.dontAutoDelete { symbols += "*" }
        if m.clip.shortcut != 0 || m.clip.moveToGroupShortcut != 0 { symbols += "s" }
        if m.clip.isGroup { symbols += "G" }
        if m.showSymbols, !m.clip.isGroup, m.clip.parentID > 0 { symbols += "!" }
        if !symbols.isEmpty {
            text.append(NSAttributedString(string: symbols + " ", attributes: [
                .font: NSFont.boldSystemFont(ofSize: max(font.pointSize - 1, 8)), .foregroundColor: secondary]))
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let bodyAttr: NSMutableAttributedString
        if let rich = m.rich {
            bodyAttr = Self.styledRich(rich, font: font, color: textColor)
        } else {
            bodyAttr = NSMutableAttributedString(string: Self.displayText(m.clip.text, lines: linesPerRow),
                                                 attributes: [.font: font, .foregroundColor: textColor])
        }
        let body = bodyAttr.string
        if let hl = m.highlighter {
            let color = selected && theme.isSystem ? textColor : theme.searchHighlight
            for r in hl.ranges(in: body) {
                bodyAttr.addAttributes([.foregroundColor: color, .underlineStyle: selected ? NSUnderlineStyle.single.rawValue : 0], range: r)
            }
        }
        text.append(bodyAttr)
        text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
        let textRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, lineH * CGFloat(linesPerRow) + 1))
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    /// Restyles RTF-derived text for the list: keeps bold/italic/underline/strike, but uses the list font size and
    /// the row's text colour so it stays legible on any theme or selection.
    static func styledRich(_ src: NSAttributedString, font: NSFont, color: NSColor) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(string: src.string.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\t", with: "    "),
                                            attributes: [.font: font, .foregroundColor: color])
        guard out.length == src.length else { return out }   // replacements changed offsets: keep plain styling
        let full = NSRange(location: 0, length: src.length)
        src.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            if let f = attrs[.font] as? NSFont {
                let traits = f.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
                if !traits.isEmpty {
                    let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    if let styled = NSFont(descriptor: d, size: font.pointSize) { out.addAttribute(.font, value: styled, range: range) }
                }
            }
            for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle] {
                if let v = attrs[key] { out.addAttribute(key, value: v, range: range) }
            }
        }
        return out
    }

    /// Limits the string to the first N lines (and a sane char count) so drawing stays cheap.
    static func displayText(_ s: String, lines: Int) -> String {
        var out = ""
        var count = 0
        for line in s.split(separator: "\n", maxSplits: lines, omittingEmptySubsequences: false).prefix(lines) {
            if count > 0 { out += "\n" }
            out += line.replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: "\r", with: "")
            count += 1
        }
        return String(out.prefix(600))
    }

    private static var tintCache: [String: NSImage] = [:]

    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let key = "\(ObjectIdentifier(image).hashValue)-\(color.description)"
        if let c = tintCache[key] { return c }
        let img = NSImage(size: image.size, flipped: false) { r in
            image.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        if tintCache.count > 64 { tintCache.removeAll() }
        tintCache[key] = img
        return img
    }
}

// MARK: - Search highlight

/// Finds ranges of search terms in a row's text (wildcard / contains terms, or the user's regex).
struct QuickPasteHighlighter {
    private let regex: NSRegularExpression

    init?(query: SearchQuery) {
        var raw = query.raw.trimmingCharacters(in: .whitespaces)
        for p in ["/q ", "\\q ", "/f ", "\\f "] where raw.lowercased().hasPrefix(p) { raw = String(raw.dropFirst(p.count)) }
        guard !raw.isEmpty else { return nil }
        let pattern: String
        var opts: NSRegularExpression.Options = []
        switch query.mode {
        case .regex:
            pattern = raw
            if query.caseInsensitive { opts.insert(.caseInsensitive) }
        case .contains:
            pattern = NSRegularExpression.escapedPattern(for: raw)
            opts.insert(.caseInsensitive)
        case .wildcard:
            var terms: [String] = []
            var current = ""
            var inQuote = false
            for ch in raw {
                if ch == "\"" { inQuote.toggle(); continue }
                if ch.isWhitespace && !inQuote {
                    if !current.isEmpty { terms.append(current) }
                    current = ""
                } else { current.append(ch) }
            }
            if !current.isEmpty { terms.append(current) }
            var parts: [String] = []
            var negateNext = false
            for t in terms {
                if t == "AND" || t == "OR" { continue }
                if t == "NOT" { negateNext = true; continue }
                if negateNext || t.hasPrefix("!") { negateNext = false; continue }
                let pieces = t.split(separator: "*").map { NSRegularExpression.escapedPattern(for: String($0)) }.filter { !$0.isEmpty }
                guard !pieces.isEmpty else { continue }
                parts.append(pieces.joined(separator: ".*?"))
            }
            guard !parts.isEmpty else { return nil }
            pattern = parts.map { "(?:\($0))" }.joined(separator: "|")
            opts.insert(.caseInsensitive)
        }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return nil }
        regex = re
    }

    func ranges(in s: String) -> [NSRange] {
        let n = min((s as NSString).length, 2000)
        return regex.matches(in: s, options: [], range: NSRange(location: 0, length: n)).prefix(50).map(\.range).filter { $0.length > 0 }
    }
}

// MARK: - Colour codes

enum ClipColorCode {
    private static let hexRE = try! NSRegularExpression(pattern: "^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$")
    private static let rgbRE = try! NSRegularExpression(
        pattern: #"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*([0-9]*\.?[0-9]+)\s*)?\)$"#, options: .caseInsensitive)
    private static let hslRE = try! NSRegularExpression(
        pattern: #"^hsla?\(\s*([0-9]*\.?[0-9]+)(?:deg)?\s*,\s*([0-9]*\.?[0-9]+)%\s*,\s*([0-9]*\.?[0-9]+)%\s*(?:,\s*([0-9]*\.?[0-9]+)\s*)?\)$"#,
        options: .caseInsensitive)

    /// Colour for a description that is exactly a colour code (#RGB, #RRGGBB, #RRGGBBAA, rgb()/rgba(), hsl()/hsla()).
    static func color(from description: String) -> NSColor? {
        let s = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 4, s.count <= 48 else { return nil }
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        if hexRE.firstMatch(in: s, range: full) != nil { return AppTheme.parseHex(s) }
        func num(_ m: NSTextCheckingResult, _ i: Int) -> Double? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : Double(ns.substring(with: r))
        }
        if let m = rgbRE.firstMatch(in: s, range: full), let r = num(m, 1), let g = num(m, 2), let b = num(m, 3),
           r <= 255, g <= 255, b <= 255 {
            return NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: min(num(m, 4) ?? 1, 1))
        }
        if let m = hslRE.firstMatch(in: s, range: full), let h = num(m, 1), let sat = num(m, 2), let l = num(m, 3),
           sat <= 100, l <= 100 {
            let (r, g, b) = hslToRGB(h: h.truncatingRemainder(dividingBy: 360) / 360, s: sat / 100, l: l / 100)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: min(num(m, 4) ?? 1, 1))
        }
        return nil
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ tIn: Double) -> Double {
            var t = tIn
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return (hue(h + 1 / 3), hue(h), hue(h - 1 / 3))
    }
}

// MARK: - Rich text cache

/// RTF-derived attributed descriptions keyed by clip id (nil results are cached too). Never touches HTML.
@MainActor
final class ClipRTFCache {
    static let shared = ClipRTFCache()
    private final class Box { let value: NSAttributedString?; init(_ v: NSAttributedString?) { value = v } }
    private let cache = NSCache<NSNumber, Box>()
    static let maxRTFBytes = 1_000_000
    static let maxChars = 2000

    init() { cache.countLimit = 600 }

    func invalidate(_ id: Int64? = nil) {
        if let id { cache.removeObject(forKey: NSNumber(value: id)) } else { cache.removeAllObjects() }
    }

    func attributed(for id: Int64, store: ClipStore) -> NSAttributedString? {
        let key = NSNumber(value: id)
        if let box = cache.object(forKey: key) { return box.value }
        var result: NSAttributedString?
        if let types = try? store.formatTypes(clipID: id),
           let rtf = types.first(where: { $0.type == ClipUTI.rtf }), rtf.size > 0, rtf.size <= Self.maxRTFBytes,
           let data = try? store.data(clipID: id, type: ClipUTI.rtf),
           let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
           attr.length > 0 {
            result = attr.attributedSubstring(from: NSRange(location: 0, length: min(attr.length, Self.maxChars)))
        }
        cache.setObject(Box(result), forKey: key)
        return result
    }
}

// MARK: - Thumbnail cache

/// Downscaled image thumbnails keyed by (clip id, pixel size); generated off the main thread.
/// Invalidating a clip also drops its cached rich-text description, so every edit site only needs one call.
@MainActor
final class ClipThumbnailCache {
    static let shared = ClipThumbnailCache()
    private struct Key: Hashable { let id: Int64; let pixel: Int }
    private final class KeyBox: NSObject {
        let key: Key
        init(_ k: Key) { key = k }
        override var hash: Int { key.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? KeyBox)?.key == key }
    }
    private let cache = NSCache<KeyBox, NSImage>()
    private var pending: Set<Key> = []
    private var missing: Set<Key> = []
    private var sizes: [Int64: Set<Int>] = [:]

    init() { cache.countLimit = 400 }

    func invalidate(_ id: Int64? = nil) {
        ClipRTFCache.shared.invalidate(id)
        if let id {
            for px in sizes[id] ?? [] {
                let k = Key(id: id, pixel: px)
                cache.removeObject(forKey: KeyBox(k))
                missing.remove(k)
            }
            sizes[id] = nil
        } else {
            cache.removeAllObjects()
            missing.removeAll()
            sizes.removeAll()
        }
    }

    /// Returns a cached thumbnail, or nil and starts generating it (calling `ready` on the main thread).
    func thumbnail(for id: Int64, maxPixel: Int, store: ClipStore, ready: @escaping (Int64) -> Void) -> NSImage? {
        let key = Key(id: id, pixel: maxPixel)
        if let img = cache.object(forKey: KeyBox(key)) { return img }
        guard !pending.contains(key), !missing.contains(key) else { return nil }
        pending.insert(key)
        sizes[id, default: []].insert(maxPixel)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = (try? store.data(clipID: id, type: ClipUTI.png)) ?? (try? store.data(clipID: id, type: ClipUTI.tiff))
            var cg: CGImage?
            if let data, let src = CGImageSourceCreateWithData(data as CFData, nil) {
                let opts: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }
            let result = cg
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending.remove(key)
                    if let result {
                        let img = NSImage(cgImage: result, size: NSSize(width: result.width / 2, height: result.height / 2))
                        self.cache.setObject(img, forKey: KeyBox(key))
                        ready(id)
                    } else {
                        self.missing.insert(key)
                    }
                }
            }
        }
        return nil
    }
}
