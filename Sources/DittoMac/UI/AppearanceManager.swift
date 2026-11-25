// AppearanceManager.swift — applies appearance preferences live (NSApp.appearance, custom themes, row style),
// stores custom themes (~/Library/Application Support/DittoMac/Themes/*.json, 0600) and caches source-app icons.

import AppKit
import DittoCore

extension Notification.Name {
    /// The menu-bar "new clips" badge should be recomputed (Quick Paste opened, clips captured).
    static let dittoMenuBarBadgeChanged = Notification.Name("io.github.dittomac.menuBarBadgeChanged")
}

// MARK: - Live application of appearance settings

enum AppearanceManager {
    /// Applies NSApp.appearance from Settings.appearanceMode. Called at launch and on `.dittoSettingsChanged`.
    @MainActor static func apply(_ settings: DittoCore.Settings) {
        let target: NSAppearance?
        switch settings.appearanceMode {
        case .system: target = nil
        case .light: target = NSAppearance(named: .aqua)
        case .dark: target = NSAppearance(named: .darkAqua)
        }
        if NSApp.appearance?.name != target?.name { NSApp.appearance = target }
    }

    /// NSColor from a "#RRGGBB" string.
    static func color(_ hex: String, fallback: NSColor = .systemGray) -> NSColor {
        guard let c = HexColor(hex) else { return fallback }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return HexColor(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent)).rgbHex
    }

    /// True when the given appearance (or the app's effective one) is dark.
    @MainActor static func isDark(_ appearance: NSAppearance? = nil) -> Bool {
        let a = appearance ?? NSApp.effectiveAppearance
        return a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Row style (popup list)

/// Everything the list rows need from the appearance settings, captured once per reload.
struct ClipRowStyle {
    var density: RowDensity = .comfortable
    var cornerRadius: CGFloat = 7
    var showTimestamp = true
    var showAppIcon = false
    var showBadges = true
    var showDividers = true
    var firstTen: FirstTenStyle = .badge
    var translucent = false

    var metrics: RowDensity.Metrics { density.metrics }

    static func from(_ s: DittoCore.Settings) -> ClipRowStyle {
        ClipRowStyle(density: s.rowDensity, cornerRadius: CGFloat(s.rowCornerRadius), showTimestamp: s.showRelativeTimestamps,
                     showAppIcon: s.showSourceAppIcon, showBadges: s.showFormatBadges, showDividers: s.showRowDividers,
                     firstTen: s.firstTenStyle, translucent: s.popupMaterial == .translucent)
    }
}

// MARK: - Custom themes

/// Custom themes saved by the theme editor or imported from JSON. Files are validated on every load
/// (`ThemeFile.parse`: ≤ 64 KB, known keys, hex colours only, sanitised names). Used from the main thread only.
final class CustomThemes: @unchecked Sendable {
    static let shared = CustomThemes()

    private(set) var themes: [ThemeFile] = []
    private var loaded = false
    /// Directory override (tests / offscreen proofs).
    var directoryOverride: URL?

    var directory: URL {
        if let d = directoryOverride { return d }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DittoMac/Themes", isDirectory: true)
    }

    func reload() {
        loaded = true
        var out: [ThemeFile] = []
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(200) where url.pathExtension.lowercased() == "json" {
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard vals?.isRegularFile == true, (vals?.fileSize ?? Int.max) <= ThemeFile.maxFileBytes,
                  let data = try? Data(contentsOf: url), let t = try? ThemeFile.parse(data) else { continue }
            if !out.contains(where: { $0.name.caseInsensitiveCompare(t.name) == .orderedSame }) { out.append(t) }
        }
        themes = out
    }

    var all: [ThemeFile] {
        if !loaded { reload() }
        return themes
    }

    var names: [String] { all.map(\.name) }

    func spec(named name: String) -> ThemeSpec? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.spec
    }

    /// A name that doesn't collide with a built-in theme ("Nord" → "Nord (Custom)").
    static func safeName(_ raw: String) -> String {
        var n = ThemeFile.sanitizeName(raw)
        if ThemeData.all.contains(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            n = ThemeFile.sanitizeName(String(n.prefix(ThemeFile.maxNameLength - 9)) + " (Custom)")
        }
        return n
    }

    /// Writes (or replaces) a theme file with mode 0600 in a 0700 directory. Returns the stored theme.
    @discardableResult
    func save(_ theme: ThemeFile) throws -> ThemeFile {
        var t = theme
        t.name = Self.safeName(theme.name)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Replace an existing theme with the same name (its file name may differ).
        for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            if let d = try? Data(contentsOf: url), d.count <= ThemeFile.maxFileBytes, let old = try? ThemeFile.parse(d),
               old.name.caseInsensitiveCompare(t.name) == .orderedSame {
                try? fm.removeItem(at: url)
            }
        }
        let url = directory.appendingPathComponent(ThemeFile.fileName(for: t.name))
        let data = try t.encoded()
        guard data.count <= ThemeFile.maxFileBytes else { throw ThemeFile.ValidationError.tooLarge }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        reload()
        return t
    }

    func delete(named name: String) {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            if let d = try? Data(contentsOf: url), d.count <= ThemeFile.maxFileBytes, let t = try? ThemeFile.parse(d),
               t.name.caseInsensitiveCompare(name) == .orderedSame {
                try? fm.removeItem(at: url)
            }
        }
        reload()
    }
}

// MARK: - Source-app icons

/// App icons by bundle id (16 pt), cached including misses. Only installed apps resolve; nothing is loaded
/// from clip data.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage] = [:]
    private var misses: Set<String> = []

    func icon(for bundleID: String) -> NSImage? {
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id.count < 200, !id.hasPrefix("friend:"), !id.contains("/") else { return nil }
        if let i = cache[id] { return i }
        if misses.contains(id) { return nil }
        if id == StickyNoteMarker.sourceApp || id == Bundle.main.bundleIdentifier || id == "DittoMac" {
            misses.insert(id)
            return nil
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            misses.insert(id)
            return nil
        }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        img.size = NSSize(width: 32, height: 32)
        if cache.count > 300 { cache.removeAll() }
        cache[id] = img
        return img
    }
}
