// Appearance.swift — pure appearance logic (no AppKit): hex colours, row density metrics, relative timestamps,
// sticky-note colour palette, menu-bar icon choices, custom theme files (import/export/validation), and lock-selection
// planning for the popup. The UI layer (Sources/DittoMac/UI) maps these values to AppKit.

import Foundation

// MARK: - Hex colours

/// Appearance helpers on `HexColor` (the struct itself lives in BeautifyLayout.swift: "#RGB", "#RRGGBB", "#RRGGBBAA").
extension HexColor {
    private static func byte(_ v: Double) -> Int { v.isFinite ? Int((min(max(v, 0), 1) * 255).rounded()) : 0 }

    /// "#RRGGBB" (upper case; alpha dropped).
    public var rgbHex: String { String(format: "#%02X%02X%02X", Self.byte(r), Self.byte(g), Self.byte(b)) }

    /// Perceived luminance 0…1 (same weights as `ThemeSpec.luminance`).
    public var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }

    public var isDark: Bool { luminance < 0.5 }

    /// Black or white, whichever reads better on this colour.
    public var contrastingText: HexColor { luminance > 0.6 ? HexColor(r: 0, g: 0, b: 0) : HexColor(r: 1, g: 1, b: 1) }

    /// Linear mix towards `other` (t = 0 → self, 1 → other).
    public func mixed(with other: HexColor, _ t: Double) -> HexColor {
        let t = min(max(t, 0), 1)
        return HexColor(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t, a: a + (other.a - a) * t)
    }

    /// Normalises any accepted spelling ("#abc", " #AABBCC ", "#AABBCCDD") to "#RRGGBB"; nil when invalid.
    public static func normalize(_ s: String) -> String? {
        guard s.count <= 16 else { return nil }
        return HexColor(s.trimmingCharacters(in: .whitespacesAndNewlines))?.rgbHex
    }
}

// MARK: - Appearance mode / accent

public enum AppearanceMode: String, Sendable, CaseIterable, Codable {
    case system, light, dark
    public var title: String { self == .system ? "System" : (self == .light ? "Light" : "Dark") }
}

/// The accent palette offered in Preferences › Appearance (selection colour override). "" = theme / system default.
public enum AccentPalette {
    public static let colors: [(name: String, hex: String)] = [
        ("Blue", "#0A84FF"), ("Purple", "#9F5AF2"), ("Pink", "#FF4F8B"), ("Red", "#FF453A"), ("Orange", "#FF9F0A"),
        ("Yellow", "#E6B800"), ("Green", "#30B158"), ("Teal", "#21A6C0"), ("Indigo", "#5E5CE6"), ("Graphite", "#8E8E93"),
    ]
}

// MARK: - Row density

public enum RowDensity: String, Sendable, CaseIterable, Codable {
    case compact, comfortable, spacious

    public var title: String { rawValue.capitalized }

    /// Spacing used by the popup rows. All values in points.
    public struct Metrics: Sendable, Equatable {
        /// Padding between the row edge and the text block, top and bottom.
        public var verticalPadding: Double
        /// Padding between the selection edge and the content, left and right.
        public var horizontalPadding: Double
        /// Inset of the rounded selection from the row edge (left/right, top/bottom).
        public var selectionInsetX: Double
        public var selectionInsetY: Double
        /// Gap between leading accessories (badge, icons, thumbnail) and the text.
        public var accessoryGap: Double
        /// Minimum row height.
        public var minimumHeight: Double
    }

    public var metrics: Metrics {
        switch self {
        case .compact:
            return Metrics(verticalPadding: 2, horizontalPadding: 6, selectionInsetX: 3, selectionInsetY: 1, accessoryGap: 5, minimumHeight: 20)
        case .comfortable:
            return Metrics(verticalPadding: 5, horizontalPadding: 9, selectionInsetX: 5, selectionInsetY: 1.5, accessoryGap: 7, minimumHeight: 26)
        case .spacious:
            return Metrics(verticalPadding: 9, horizontalPadding: 11, selectionInsetX: 6, selectionInsetY: 2, accessoryGap: 9, minimumHeight: 34)
        }
    }

    /// Row height for `lines` text lines of `lineHeight` points each (lines clamped to 1…5).
    public func rowHeight(lineHeight: Double, lines: Int) -> Double {
        let m = metrics
        let n = Double(min(max(lines, 1), 5))
        let lh = lineHeight.isFinite ? max(lineHeight, 1) : 16
        return max((lh * n + 2 * (m.verticalPadding + m.selectionInsetY)).rounded(.up), m.minimumHeight)
    }
}

/// How the first ten rows show their ⌘-number.
public enum FirstTenStyle: String, Sendable, CaseIterable, Codable {
    case plain, badge, keycap
    public var title: String {
        switch self {
        case .plain: return "Plain number"
        case .badge: return "Rounded badge"
        case .keycap: return "Key cap (⌘1)"
        }
    }
    /// Text drawn for a digit.
    public func label(_ digit: Int) -> String { self == .keycap ? "⌘\(digit)" : "\(digit)" }
}

public enum PopupMaterial: String, Sendable, CaseIterable, Codable {
    case opaque, translucent
    public var title: String { self == .opaque ? "Opaque" : "Translucent (vibrancy)" }
}

// MARK: - Relative time

public enum RelativeTime {
    /// Compact relative timestamp for list rows: "now", "5m", "3h", "Yesterday", "4d", "12 Nov", "12 Nov 2024".
    public static func short(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = .current) -> String {
        let secs = now.timeIntervalSince(date)
        if secs < 0 { return secs > -60 ? "now" : dayMonth(date, now: now, calendar: calendar, locale: locale) }
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) || secs < 6 * 3600 { return "\(Int(secs / 3600))h" }
        let startNow = calendar.startOfDay(for: now), startThen = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startThen, to: startNow).day ?? Int(secs / 86400)
        if days <= 1 { return "Yesterday" }
        if days < 7 { return "\(days)d" }
        return dayMonth(date, now: now, calendar: calendar, locale: locale)
    }

    private static func dayMonth(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "dMMM" : "dMMMyyyy")
        return f.string(from: date)
    }
}

// MARK: - Sticky note colours

public enum NoteColor: String, Sendable, CaseIterable, Codable {
    case yellow, green, pink, blue, purple, grey

    public var title: String { rawValue.capitalized }

    /// Paper, title-bar strip and text colours ("#RRGGBB"). Dark variants are deeper so notes don't glare at night.
    public func paper(dark: Bool) -> String {
        switch self {
        case .yellow: return dark ? "#5C5321" : "#FFF3A6"
        case .green: return dark ? "#2E4D2E" : "#CDEFC4"
        case .pink: return dark ? "#5A2E43" : "#FFD3E2"
        case .blue: return dark ? "#28405C" : "#CFE5FF"
        case .purple: return dark ? "#44315C" : "#E3D6FF"
        case .grey: return dark ? "#3A3A3C" : "#E9E9EB"
        }
    }

    public func bar(dark: Bool) -> String {
        switch self {
        case .yellow: return dark ? "#6E6328" : "#FFE873"
        case .green: return dark ? "#385C38" : "#AEE3A1"
        case .pink: return dark ? "#6B3752" : "#FFB6CE"
        case .blue: return dark ? "#304D6E" : "#A9D0FF"
        case .purple: return dark ? "#523B6E" : "#CDB8FF"
        case .grey: return dark ? "#48484A" : "#D5D5D8"
        }
    }

    public func text(dark: Bool) -> String { dark ? "#F2F2F2" : "#2B2B2B" }

    /// Lenient lookup used for stored values: unknown → yellow.
    public static func named(_ s: String?) -> NoteColor {
        guard let s else { return .yellow }
        let k = s.trimmingCharacters(in: .whitespaces).lowercased()
        if k == "gray" { return .grey }
        return NoteColor(rawValue: k) ?? .yellow
    }
}

/// Source-app marker stored on clips created with "New Sticky Note" (plaintext metadata, like any source app).
public enum StickyNoteMarker {
    public static let sourceApp = "io.github.dittomac.note"
}

// MARK: - Menu-bar icon

public enum MenuBarIcon {
    /// SF Symbols offered for the status item (all clipboard/list-like, no scissors).
    public static let symbols: [(symbol: String, title: String)] = [
        ("doc.on.clipboard", "Clipboard"), ("list.clipboard", "List clipboard"), ("clipboard", "Plain clipboard"),
        ("paperclip", "Paperclip"), ("tray.full", "Tray"), ("text.badge.plus", "Text badge"),
        ("square.stack.3d.up", "Stack"), ("doc.on.doc", "Documents"), ("note.text", "Note"),
    ]
    public static let defaultSymbol = "doc.on.clipboard"

    /// Only symbols from the list are accepted; anything else falls back to the default.
    public static func sanitize(_ s: String) -> String {
        symbols.contains { $0.symbol == s } ? s : defaultSymbol
    }

    /// Badge text for a count of new clips ("" for 0, "99+" above 99).
    public static func badgeText(_ n: Int) -> String { n <= 0 ? "" : (n > 99 ? "99+" : "\(n)") }
}

// MARK: - Custom theme files

/// A theme file (import / export / "Save as custom theme"). JSON:
/// `{ "format": "dittomac-theme", "version": 1, "name": "…", "colors": { "MainWindowBG": "#RRGGBB", … } }`
public struct ThemeFile: Codable, Sendable, Equatable {
    public static let formatID = "dittomac-theme"
    public static let currentVersion = 1
    public static let maxFileBytes = 64 * 1024
    public static let maxNameLength = 40
    public static let maxColors = 64

    public var format: String
    public var version: Int
    public var name: String
    public var colors: [String: String]

    public init(name: String, colors: [String: String]) {
        self.format = Self.formatID
        self.version = Self.currentVersion
        self.name = name
        self.colors = colors
    }

    /// Every colour key a theme may set (the upstream Ditto keys; see docs/kb/themes.md).
    public static let allowedKeys: Set<String> = [
        "CaptionLeft", "CaptionRight", "Border", "BorderTopMost", "BorderNotConnected", "CaptionLeftTopMost",
        "CaptionRightTopMost", "CaptionLeftNotConnected", "CaptionRightNotConnected", "CaptionTextColor",
        "ListBoxOddRowsBG", "ListBoxEvenRowsBG", "ListBoxOddRowsText", "ListBoxEvenRowsText", "ListBoxSelectedBG",
        "ListBoxSelectedNoFocusBG", "ListBoxSelectedText", "ListBoxSelectedNoFocusText", "ClipPastedColor",
        "MainWindowBG", "SearchTextBoxFocusBG", "SearchTextBoxFocusText", "SearchTextBoxFocusBorder",
        "SearchTextHighlight", "GroupTreeBG", "GroupTreeText", "DescriptionWindowBG", "DescriptionWindowText",
    ]

    /// The 12 colours the theme editor exposes, with labels.
    public static let editorKeys: [(key: String, title: String)] = [
        ("MainWindowBG", "Window background"), ("ListBoxOddRowsBG", "Row background"),
        ("ListBoxEvenRowsBG", "Alternate row"), ("ListBoxOddRowsText", "Row text"),
        ("ListBoxEvenRowsText", "Alternate row text"), ("ListBoxSelectedBG", "Selection"),
        ("ListBoxSelectedText", "Selected text"), ("SearchTextHighlight", "Search highlight"),
        ("ClipPastedColor", "Pasted dot"), ("CaptionTextColor", "Status text"),
        ("GroupTreeBG", "Groups sidebar"), ("GroupTreeText", "Groups text"),
    ]

    public enum ValidationError: Error, Equatable, LocalizedError {
        case tooLarge, notJSON, wrongFormat, unsupportedVersion, noColors, tooManyColors

        public var errorDescription: String? {
            switch self {
            case .tooLarge: return "The theme file is larger than 64 KB."
            case .notJSON: return "The file isn’t a valid DittoMac theme (JSON)."
            case .wrongFormat: return "The file isn’t a DittoMac theme."
            case .unsupportedVersion: return "The theme was made by a newer DittoMac."
            case .noColors: return "The theme has no valid colours."
            case .tooManyColors: return "The theme has too many colours."
            }
        }
    }

    /// Cleans a user- or file-supplied theme name: no control characters, path separators or leading dots;
    /// whitespace collapsed; at most 40 characters; never empty.
    public static func sanitizeName(_ raw: String) -> String {
        var out = ""
        var lastSpace = false
        for scalar in raw.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar) { continue }
            if "/\\:*?\"<>|".unicodeScalars.contains(scalar) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastSpace, !out.isEmpty { out.append(" ") }
                lastSpace = true
                continue
            }
            lastSpace = false
            out.unicodeScalars.append(scalar)
        }
        while out.hasPrefix(".") { out.removeFirst() }
        out = out.trimmingCharacters(in: .whitespaces)
        if out.count > maxNameLength { out = String(out.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces) }
        return out.isEmpty ? "Custom Theme" : out
    }

    /// File name for a theme ("My-Theme.json"): ASCII letters, digits, "-" and "_" only.
    public static func fileName(for name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var slug = ""
        for ch in sanitizeName(name) {
            if allowed.contains(ch) { slug.append(ch) } else if !slug.hasSuffix("-") { slug.append("-") }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "Custom-Theme" }
        return String(slug.prefix(48)) + ".json"
    }

    /// Parses and validates file bytes. Unknown keys and malformed colours are dropped; colours are normalised to
    /// "#RRGGBB"; the name is sanitised. Throws when the file is too large, not a theme, or has no usable colour.
    public static func parse(_ data: Data) throws -> ThemeFile {
        guard data.count <= maxFileBytes else { throw ValidationError.tooLarge }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []), let dict = obj as? [String: Any] else {
            throw ValidationError.notJSON
        }
        if let f = dict["format"] as? String, f != formatID { throw ValidationError.wrongFormat }
        if let v = dict["version"] as? Int, v > currentVersion { throw ValidationError.unsupportedVersion }
        guard let rawColors = dict["colors"] as? [String: Any] else { throw ValidationError.wrongFormat }
        guard rawColors.count <= maxColors * 2 else { throw ValidationError.tooManyColors }
        var colors: [String: String] = [:]
        for (k, v) in rawColors {
            guard allowedKeys.contains(k), let s = v as? String, s.count <= 16, let hex = HexColor.normalize(s) else { continue }
            colors[k] = hex
        }
        guard !colors.isEmpty else { throw ValidationError.noColors }
        let name = sanitizeName((dict["name"] as? String).map { String($0.prefix(200)) } ?? "")
        return ThemeFile(name: name, colors: colors)
    }

    /// Fills keys the file doesn't set from the 12 editor keys, so a partial theme still renders sensibly.
    public func completed() -> [String: String] {
        var c = colors
        let bg = c["MainWindowBG"] ?? c["ListBoxOddRowsBG"] ?? "#FFFFFF"
        let dark = HexColor(bg)?.isDark ?? false
        let text = c["ListBoxOddRowsText"] ?? (dark ? "#EEEEEE" : "#1E1E1E")
        func fill(_ k: String, _ v: String) { if c[k] == nil { c[k] = v } }
        fill("MainWindowBG", bg)
        fill("ListBoxOddRowsBG", bg)
        fill("ListBoxEvenRowsBG", c["ListBoxOddRowsBG"]!)
        fill("ListBoxOddRowsText", text)
        fill("ListBoxEvenRowsText", text)
        fill("ListBoxSelectedBG", dark ? "#3A5A8C" : "#2F6FDB")
        fill("ListBoxSelectedText", HexColor(c["ListBoxSelectedBG"]!)?.contrastingText.rgbHex ?? "#FFFFFF")
        fill("ListBoxSelectedNoFocusBG", c["ListBoxSelectedBG"]!)
        fill("ListBoxSelectedNoFocusText", c["ListBoxSelectedText"]!)
        fill("ClipPastedColor", "#34C759")
        fill("SearchTextHighlight", dark ? "#FF6B5E" : "#D70015")
        fill("CaptionTextColor", text)
        fill("GroupTreeBG", bg)
        fill("GroupTreeText", text)
        fill("Border", c["ListBoxSelectedBG"]!)
        fill("DescriptionWindowBG", bg)
        fill("DescriptionWindowText", text)
        fill("SearchTextBoxFocusBG", bg)
        fill("SearchTextBoxFocusText", text)
        return c
    }

    /// A `ThemeSpec` for rendering (missing keys completed).
    public var spec: ThemeSpec {
        let c = completed()
        let lum = c["MainWindowBG"].flatMap { ThemeSpec.luminance(hex: $0) } ?? 1
        return ThemeSpec(name: name, colors: c, isDark: lum < 0.5)
    }

    /// Pretty-printed, key-sorted JSON.
    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// Theme file for an existing spec (export of a built-in or custom theme). System → nil (no colours).
    public static func from(_ spec: ThemeSpec) -> ThemeFile? {
        guard !spec.colors.isEmpty else { return nil }
        var c: [String: String] = [:]
        for (k, v) in spec.colors where allowedKeys.contains(k) { if let h = HexColor.normalize(v) { c[k] = h } }
        return c.isEmpty ? nil : ThemeFile(name: sanitizeName(spec.name), colors: c)
    }
}

// MARK: - Lock-selection planning

/// Minimal description of a selected row for planning lock-related actions.
public struct LockItem: Sendable, Equatable {
    public var id: Int64
    public var isLocked: Bool
    public var isGroup: Bool
    public init(id: Int64, isLocked: Bool, isGroup: Bool = false) { self.id = id; self.isLocked = isLocked; self.isGroup = isGroup }
}

/// Decides what lock / delete / export actions do for a popup selection.
public struct LockPlan: Sendable, Equatable {
    public enum Toggle: Sendable, Equatable {
        case none
        case lock([Int64])          // lock these (unlocked, non-group) clips
        case removeLock([Int64])    // every selected clip is locked: remove the lock (requires unlock)
    }

    public let lockedIDs: [Int64]
    public let unlockedIDs: [Int64]   // non-group clips without a lock
    public let groupIDs: [Int64]

    public init(_ items: [LockItem]) {
        lockedIDs = items.filter { !$0.isGroup && $0.isLocked }.map(\.id)
        unlockedIDs = items.filter { !$0.isGroup && !$0.isLocked }.map(\.id)
        groupIDs = items.filter(\.isGroup).map(\.id)
    }

    public var hasLocked: Bool { !lockedIDs.isEmpty }
    public var allLocked: Bool { !lockedIDs.isEmpty && unlockedIDs.isEmpty }

    /// ⌘L: lock the unlocked clips; when every selected clip is already locked, remove their lock.
    public var toggle: Toggle {
        if !unlockedIDs.isEmpty { return .lock(unlockedIDs) }
        if !lockedIDs.isEmpty { return .removeLock(lockedIDs) }
        return .none
    }

    /// Menu visibility: "Lock" when something can be locked, "Remove Lock…" when something is locked.
    public var canLock: Bool { !unlockedIDs.isEmpty }
    public var canRemoveLock: Bool { !lockedIDs.isEmpty }

    /// Viewing / pasting / editing the selection needs the vault unlocked first.
    public func needsUnlock(vaultUnlocked: Bool) -> Bool { hasLocked && !vaultUnlocked }

    /// Delete: unlocked clips and groups go through the normal delete; locked clips need the deliberate,
    /// authenticated path (`VaultService.deleteLockedClips`), never a silent skip.
    public var plainDeleteIDs: [Int64] { unlockedIDs + groupIDs }
    public var lockedDeleteIDs: [Int64] { lockedIDs }

    /// Export, Send To (friends) and sync never include locked clips.
    public var exportableIDs: [Int64] { unlockedIDs }
}
