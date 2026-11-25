// Theme.swift — maps DittoCore ThemeData (upstream Ditto theme keys, "#RRGGBB") to NSColor.
// The "System" theme has no colours: every lookup returns the native fallback colour.

import AppKit
import DittoCore

struct AppTheme {
    let spec: ThemeSpec
    /// Selection colour override ("#RRGGBB", "" = theme / system selection colour). Preferences › Appearance › Accent.
    var accentHex: String = ""

    private static var cached: AppTheme?
    private static var override: AppTheme?

    /// The theme selected in Settings (built-in or custom; re-read whenever the theme name or accent changes).
    /// Assigning pins a theme (offscreen proofs).
    static var current: AppTheme {
        get {
            if let o = override { return o }
            let name = Settings.shared.themeName
            let accent = Settings.shared.accentColorHex
            if let c = cached, c.spec.name == name || (c.spec.name == ThemeData.systemName && !Self.exists(name)),
               c.accentHex == accent { return c }
            let t = AppTheme(spec: Self.spec(named: name), accentHex: accent)
            cached = t
            return t
        }
        set { override = newValue }
    }

    /// Drops the cached theme (after a custom theme was saved / deleted).
    static func invalidate() { cached = nil }

    /// Built-in theme by name, else a custom theme, else System.
    static func spec(named name: String) -> ThemeSpec {
        if let b = ThemeData.all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return b }
        return CustomThemes.shared.spec(named: name) ?? ThemeData.system
    }

    private static func exists(_ name: String) -> Bool {
        ThemeData.all.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            || CustomThemes.shared.spec(named: name) != nil
    }

    var isSystem: Bool { spec.colors.isEmpty || spec.name == ThemeData.systemName }

    /// Theme colour for an upstream key; the fallback for "System" or missing / malformed keys.
    func color(_ key: String, fallback: NSColor) -> NSColor {
        guard !isSystem, let hex = spec.colors[key], let c = Self.parseHex(hex) else { return fallback }
        return c
    }

    /// Appearance matching the theme (nil = follow the system).
    var appearance: NSAppearance? {
        guard !isSystem else { return nil }
        return NSAppearance(named: spec.isDark ? .darkAqua : .aqua)
    }

    // MARK: Common roles

    var windowBackground: NSColor { color("MainWindowBG", fallback: .windowBackgroundColor) }
    var listBackground: NSColor { color("ListBoxEvenRowsBG", fallback: .controlBackgroundColor) }

    func rowBackground(odd: Bool) -> NSColor {
        // Row 0 is the first ("odd" in upstream 1-based terms).
        let alts = NSColor.alternatingContentBackgroundColors
        return odd ? color("ListBoxOddRowsBG", fallback: alts[0])
                   : color("ListBoxEvenRowsBG", fallback: alts.count > 1 ? alts[1] : alts[0])
    }

    func rowText(odd: Bool) -> NSColor {
        odd ? color("ListBoxOddRowsText", fallback: .labelColor) : color("ListBoxEvenRowsText", fallback: .labelColor)
    }

    private var accent: HexColor? { accentHex.isEmpty ? nil : HexColor(accentHex) }

    func selectionBackground(emphasized: Bool) -> NSColor {
        if let a = accent {
            let c = NSColor(srgbRed: a.r, green: a.g, blue: a.b, alpha: 1)
            return emphasized ? c : c.withAlphaComponent(0.45)
        }
        let fb: NSColor = emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        return color("ListBoxSelectedBG", fallback: fb)
    }

    func selectionText(emphasized: Bool) -> NSColor {
        if let a = accent {
            let t = a.contrastingText
            return emphasized ? NSColor(srgbRed: t.r, green: t.g, blue: t.b, alpha: 1) : rowText(odd: true)
        }
        return color("ListBoxSelectedText", fallback: emphasized ? .alternateSelectedControlTextColor : .labelColor)
    }

    var pastedColor: NSColor { color("ClipPastedColor", fallback: .systemGreen) }
    var searchHighlight: NSColor { color("SearchTextHighlight", fallback: .systemRed) }
    var groupTreeBackground: NSColor { color("GroupTreeBG", fallback: .clear) }
    var groupTreeText: NSColor { color("GroupTreeText", fallback: .labelColor) }
    var captionText: NSColor { color("CaptionTextColor", fallback: .secondaryLabelColor) }
    var border: NSColor { color("Border", fallback: .separatorColor) }

    // MARK: Parsing

    /// Parses "#RGB", "#RRGGBB" or "#RRGGBBAA".
    static func parseHex(_ s: String) -> NSColor? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let r, g, b, a: Double
        if h.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255; a = 1
        } else {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Popup list font from Settings (fontName empty → system font).
    static func listFont(_ settings: Settings) -> NSFont {
        let size = CGFloat(settings.fontSize)
        if !settings.fontName.isEmpty, let f = NSFont(name: settings.fontName, size: size) { return f }
        return NSFont.systemFont(ofSize: size)
    }
}
