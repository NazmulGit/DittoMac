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

// MARK: - Row view (themed background + rounded selection)

@MainActor
final class ClipRowView: NSTableRowView {
    var rowIndex = 0 { didSet { if oldValue != rowIndex { needsDisplay = true } } }
    var style = ClipRowStyle() { didSet { needsDisplay = true } }

    /// Background for this row. With row dividers on, the System theme uses one flat colour (dividers separate the
    /// rows); themes keep their odd / even colours. Translucent popups draw no row background at all.
    private var rowFillColor: NSColor? {
        let theme = AppTheme.current
        if style.translucent { return nil }
        if theme.isSystem && style.showDividers { return theme.listBackground }
        return theme.rowBackground(odd: rowIndex % 2 == 0)
    }

    private var selectionRect: NSRect {
        guard style.cornerRadius > 0 else { return bounds }
        let m = style.metrics
        return bounds.insetBy(dx: CGFloat(m.selectionInsetX), dy: CGFloat(m.selectionInsetY))
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if let bg = rowFillColor {
            bg.setFill()
            bounds.fill()
        }
        guard style.showDividers, !isSelected, !isNextRowSelected else { return }
        let inset = CGFloat(style.metrics.horizontalPadding)
        let line = NSRect(x: bounds.minX + inset, y: bounds.maxY - 0.5, width: max(bounds.width - 2 * inset, 0), height: 0.5)
        let theme = AppTheme.current
        (theme.isSystem ? NSColor.separatorColor.withAlphaComponent(0.55) : theme.border.withAlphaComponent(0.22)).setFill()
        line.fill(using: .sourceOver)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let color = AppTheme.current.selectionBackground(emphasized: isEmphasized)
        color.setFill()
        let r = selectionRect
        if style.cornerRadius > 0 {
            let radius = min(style.cornerRadius, r.height / 2)
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        } else {
            r.fill()
        }
    }

    override var isFlipped: Bool { true }

    override var isEmphasized: Bool {
        didSet { needsDisplay = true; subviews.forEach { $0.needsDisplay = true } }
    }

    override var isSelected: Bool {
        didSet { needsDisplay = true; subviews.forEach { $0.needsDisplay = true } }
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
    /// Clip keeps formatting (RTF / RTFD / HTML / web archive): small "textformat" symbol.
    var richIndicator = false
    /// Clip has an image as well as text: small "photo" symbol.
    var imageIndicator = false
    /// Rich description (from the clip's RTF) when "Draw rich text" is on; nil falls back to plain text.
    var rich: NSAttributedString?
    /// Locked clip (vault). `contentHidden` = locked while the vault is locked: placeholder only, no previews.
    var isLocked = false
    var contentHidden = false
    /// Sticky note ("New Sticky Note" or shown as a desktop note) and its paper colour.
    var isNote = false
    var noteColor: NSColor?
    /// Source-app icon (Appearance › Show source-app icon).
    var appIcon: NSImage?
    /// Relative timestamp ("5m", "Yesterday") or nil.
    var timestamp: String?
    var style = ClipRowStyle()
}

// MARK: - Cell view (custom drawn for speed)

@MainActor
final class ClipCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ClipCell")

    var model: ClipRowModel? {
        didSet {
            if let m = model {
                toolTip = m.contentHidden ? "Locked note — unlock to view (⌘L menu › Unlock Notes…)" : String(m.clip.text.prefix(300))
            } else { toolTip = nil }
            needsDisplay = true
        }
    }
    var font: NSFont = .systemFont(ofSize: 13) { didSet { needsDisplay = true } }
    var linesPerRow = 2

    override var backgroundStyle: NSView.BackgroundStyle { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    private var isRowSelected: Bool { (superview as? NSTableRowView)?.isSelected ?? false }
    private var isRowEmphasized: Bool { (superview as? NSTableRowView)?.isEmphasized ?? true }

    private static func symbol(_ name: String, _ desc: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: desc)
    }
    private static let folderImage = symbol("folder.fill", "Group")
    private static let pinImage = symbol("pin.fill", "Sticky")
    private static let richImage = symbol("textformat", "Keeps formatting")
    private static let photoImage = symbol("photo", "Has image")
    private static let lockImage = symbol("lock.fill", "Locked")
    private static let noteImage = symbol("note.text", "Sticky note")

    /// Draws `img` (template symbol) tinted, `h` points tall, vertically centred on `centerY`, from `x`.
    @discardableResult
    private static func drawSymbol(_ img: NSImage?, color: NSColor, x: CGFloat, centerY: CGFloat, height h: CGFloat) -> CGFloat {
        guard let img, img.size.width > 0, img.size.height > 0 else { return 0 }
        let w = h * img.size.width / img.size.height
        let r = NSRect(x: x, y: centerY - h / 2, width: w, height: h)
        tinted(img, color).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        return w
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = model else { return }
        let theme = AppTheme.current
        let style = m.style
        let metrics = style.metrics
        let selected = isRowSelected
        let textColor = selected ? theme.selectionText(emphasized: isRowEmphasized) : theme.rowText(odd: m.row % 2 == 0)
        let secondary = textColor.withAlphaComponent(selected ? 0.75 : 0.55)
        let lineH = ceil(font.ascender - font.descender + font.leading)
        var rect = bounds.insetBy(dx: CGFloat(metrics.horizontalPadding),
                                  dy: CGFloat(metrics.verticalPadding + metrics.selectionInsetY))
        let firstLineMid = rect.minY + lineH / 2
        let gap = CGFloat(metrics.accessoryGap)
        let smallSize = max(font.pointSize - 2.5, 9)

        // Right edge (first line): timestamp, pasted dot, sticky pin, lock badge, format badges.
        var right = rect.maxX
        if let ts = m.timestamp {
            let f = NSFont.monospacedDigitSystemFont(ofSize: smallSize, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: secondary]
            let size = (ts as NSString).size(withAttributes: attrs)
            (ts as NSString).draw(at: NSPoint(x: right - size.width, y: firstLineMid - size.height / 2), withAttributes: attrs)
            right -= size.width + 6
        }
        if m.showPasted {
            let d: CGFloat = 6
            theme.pastedColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: right - d, y: firstLineMid - d / 2, width: d, height: d)).fill()
            right -= d + 5
        }
        if m.clip.isSticky, !m.isNote {
            let h = min(lineH * 0.78, 11)
            let w = h * 0.8
            Self.drawSymbol(Self.pinImage, color: secondary, x: right - w, centerY: firstLineMid, height: h)
            right -= w + 5
        }
        if m.isLocked, !m.contentHidden {
            let h = min(lineH * 0.72, 10)
            let w = h * 0.8
            Self.drawSymbol(Self.lockImage, color: selected ? secondary : NSColor.systemOrange, x: right - w, centerY: firstLineMid, height: h)
            right -= w + 5
        }
        if style.showBadges, !m.contentHidden {
            for (show, img) in [(m.imageIndicator, Self.photoImage), (m.richIndicator, Self.richImage)] where show {
                guard let img, img.size.height > 0 else { continue }
                let h = min(lineH * 0.7, 10.5)
                let w = h * img.size.width / img.size.height
                Self.drawSymbol(img, color: secondary.withAlphaComponent(0.8), x: right - w, centerY: firstLineMid, height: h)
                right -= w + 5
            }
        }
        rect.size.width = max(right - rect.minX, 0)

        // First-ten index.
        if let idx = m.indexLabel {
            let f = NSFont.monospacedDigitSystemFont(ofSize: smallSize, weight: style.firstTen == .plain ? .regular : .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: secondary]
            let size = (idx as NSString).size(withAttributes: attrs)
            switch style.firstTen {
            case .plain:
                let w = ceil(f.pointSize * 0.62) + 2
                (idx as NSString).draw(at: NSPoint(x: rect.minX + (w - size.width) / 2, y: firstLineMid - size.height / 2), withAttributes: attrs)
                rect.origin.x += w + gap - 2
                rect.size.width -= w + gap - 2
            case .badge, .keycap:
                let h = ceil(size.height + 2)
                let w = max(ceil(size.width + 8), h)
                let box = NSRect(x: rect.minX, y: firstLineMid - h / 2, width: w, height: h)
                let path = NSBezierPath(roundedRect: box, xRadius: style.firstTen == .badge ? h / 2 : 4, yRadius: style.firstTen == .badge ? h / 2 : 4)
                if style.firstTen == .badge {
                    textColor.withAlphaComponent(selected ? 0.22 : 0.08).setFill()
                    path.fill()
                } else {
                    secondary.withAlphaComponent(0.6).setStroke()
                    path.lineWidth = 0.8
                    path.stroke()
                }
                (idx as NSString).draw(at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2), withAttributes: attrs)
                let keycapWidth = style.firstTen == .keycap ? max(w, ceil(("⌘0" as NSString).size(withAttributes: attrs).width + 8)) : w
                rect.origin.x += keycapWidth + gap
                rect.size.width -= keycapWidth + gap
            }
        }

        // Source-app icon.
        if let icon = m.appIcon {
            let s = min(lineH, 16)
            icon.draw(in: NSRect(x: rect.minX, y: firstLineMid - s / 2, width: s, height: s), from: .zero,
                      operation: .sourceOver, fraction: m.contentHidden ? 0.5 : 1, respectFlipped: true,
                      hints: [.interpolation: NSImageInterpolation.high.rawValue])
            rect.origin.x += s + gap - 1
            rect.size.width -= s + gap - 1
        }

        // Leading symbol: lock (hidden locked note), note, group folder.
        if m.contentHidden || m.isNote || m.clip.isGroup {
            let s = min(lineH, 15)
            let img: NSImage?
            let color: NSColor
            if m.contentHidden {
                img = Self.lockImage
                color = selected ? textColor : NSColor.systemOrange
            } else if m.clip.isGroup {
                img = Self.folderImage
                color = selected ? textColor : .systemBlue
            } else {
                img = Self.noteImage
                color = selected ? textColor : (m.noteColor.map { Self.readable($0, on: theme.rowBackground(odd: true)) } ?? .systemYellow)
            }
            let w = Self.drawSymbol(img, color: color, x: rect.minX, centerY: firstLineMid, height: s * 0.92)
            rect.origin.x += max(w, s) + gap - 2
            rect.size.width -= max(w, s) + gap - 2
        }

        // Thumbnail (never for hidden locked notes).
        if !m.contentHidden, let img = m.thumbnail, img.size.width > 0, img.size.height > 0 {
            let maxH = rect.height
            let maxW = min(rect.width * 0.4, maxH * 2.5)
            let scale = min(maxH / img.size.height, maxW / img.size.width, 1)
            let size = NSSize(width: img.size.width * scale, height: img.size.height * scale)
            let r = NSRect(x: rect.minX, y: rect.minY + (maxH - size.height) / 2, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).addClip()
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            secondary.withAlphaComponent(0.25).setStroke()
            let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.25, dy: 0.25), xRadius: 3, yRadius: 3)
            border.lineWidth = 0.5
            border.stroke()
            rect.origin.x += size.width + gap
            rect.size.width -= size.width + gap
        }

        // Colour swatch.
        if !m.contentHidden, let c = m.swatch {
            let s = min(lineH, 14)
            let r = NSRect(x: rect.minX, y: firstLineMid - s / 2, width: s, height: s)
            c.setFill()
            let p = NSBezierPath(roundedRect: r, xRadius: 3.5, yRadius: 3.5)
            p.fill()
            secondary.withAlphaComponent(0.4).setStroke()
            p.lineWidth = 0.5
            p.stroke()
            rect.origin.x += s + gap - 1
            rect.size.width -= s + gap - 1
        }

        guard rect.width > 4 else { return }

        // Hidden locked note: placeholder only.
        if m.contentHidden {
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            let s = NSMutableAttributedString(string: ClipStore.lockedPlaceholder, attributes: [.font: italic, .foregroundColor: secondary])
            s.append(NSAttributedString(string: "  ·  unlock to view", attributes: [
                .font: NSFont.systemFont(ofSize: smallSize), .foregroundColor: secondary.withAlphaComponent(0.7)]))
            s.draw(with: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: lineH + 1),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            return
        }

        // Symbols + description text.
        let text = NSMutableAttributedString()
        var symbols = ""
        if m.clip.dontAutoDelete { symbols += "*" }
        if m.clip.shortcut != 0 || m.clip.moveToGroupShortcut != 0 { symbols += "s" }
        if m.clip.isGroup { symbols += "G" }
        if m.showSymbols, !m.clip.isGroup, m.clip.parentID > 0 { symbols += "!" }
        if !symbols.isEmpty {
            text.append(NSAttributedString(string: symbols + " ", attributes: [
                .font: NSFont.systemFont(ofSize: max(font.pointSize - 1, 8), weight: .semibold), .foregroundColor: secondary]))
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let bodyAttr: NSMutableAttributedString
        if let rich = m.rich {
            bodyAttr = Self.styledRich(rich, font: font, color: textColor)
        } else {
            let bodyFont = m.isNote || m.clip.isGroup ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
            bodyAttr = NSMutableAttributedString(string: Self.displayText(m.clip.text, lines: linesPerRow),
                                                 attributes: [.font: bodyFont, .foregroundColor: textColor])
        }
        let body = bodyAttr.string
        if let hl = m.highlighter {
            let color = selected && (theme.isSystem || !theme.accentHex.isEmpty) ? textColor : theme.searchHighlight
            for r in hl.ranges(in: body) {
                bodyAttr.addAttributes([.foregroundColor: color, .underlineStyle: selected ? NSUnderlineStyle.single.rawValue : 0], range: r)
            }
        }
        text.append(bodyAttr)
        text.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: text.length))
        let textRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, lineH * CGFloat(linesPerRow) + 1))
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    /// A note colour darkened / lightened until it reads on `background` (note paper colours are pale).
    static func readable(_ c: NSColor, on background: NSColor) -> NSColor {
        let bg = background.usingColorSpace(.sRGB) ?? background
        let lumBG = 0.299 * bg.redComponent + 0.587 * bg.greenComponent + 0.114 * bg.blueComponent
        return lumBG > 0.5 ? (c.blended(withFraction: 0.45, of: .black) ?? c) : c
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
            let data = PasteContent.imageData(clipID: id, store: store)
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
