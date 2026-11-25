// Settings+Screenshots.swift — screenshot settings (owned by the screenshots agent; Settings.swift is untouched).
import Foundation

/// What happens after a capture (Return, full-screen hotkey, window click).
public enum ScreenshotAction: String, CaseIterable, Sendable {
    case copy, save, upload
    /// Keep (or open) the editor; nothing automatic.
    case editor

    public var title: String {
        switch self {
        case .copy: return "Copy to clipboard"
        case .save: return "Save to file"
        case .upload: return "Upload and copy link"
        case .editor: return "Open the editor"
        }
    }
}

public enum ScreenshotFormat: String, CaseIterable, Sendable {
    case png, jpg, bmp
    public var fileExtension: String { rawValue }
    public var uti: String {
        switch self { case .png: return "public.png"; case .jpg: return "public.jpeg"; case .bmp: return "com.microsoft.bmp" }
    }
    public var mimeType: String {
        switch self { case .png: return "image/png"; case .jpg: return "image/jpeg"; case .bmp: return "image/bmp" }
    }
    public var title: String { rawValue.uppercased() }
}

extension Settings {
    /// Hotkey names registered by the screenshot service.
    public static let screenshotHotkeyNames = ["captureArea", "captureWindow", "captureFullScreen"]

    /// ⌃⇧4 area, ⌃⇧5 window, ⌃⇧3 full screen (avoids the system's ⌘⇧3/4/5).
    public static let screenshotDefaultHotkeys: [String: Int] = [
        "captureArea": KeyCombo(keyCode: 0x15, modifiers: KeyCombo.controlKey | KeyCombo.shiftKey).encoded,
        "captureWindow": KeyCombo(keyCode: 0x17, modifiers: KeyCombo.controlKey | KeyCombo.shiftKey).encoded,
        "captureFullScreen": KeyCombo(keyCode: 0x14, modifiers: KeyCombo.controlKey | KeyCombo.shiftKey).encoded,
    ]

    public static let screenshotDelayChoices = [0, 3, 5, 10]

    public static let screenshotKeys: Set<String> = [
        "screenshotDefaultAction", "screenshotFullScreenAction", "screenshotWindowAction", "screenshotFormat",
        "screenshotJPEGQuality", "screenshotSaveFolder", "screenshotNameTemplate", "screenshotAskWhereToSave",
        "screenshotIncludeCursor", "screenshotDelaySeconds", "screenshotDimOpacity", "screenshotShowMagnifier",
        "screenshotPlaySound", "screenshotAddToHistory", "screenshotRememberTool", "screenshotLastTool",
        "screenshotLastColor", "screenshotLastLineWidth", "screenshotLastFontSize",
    ]

    /// Effective capture hotkey: the stored value when the user set one (0 = explicitly disabled),
    /// otherwise the default above.
    public func screenshotHotkey(_ name: String) -> Int {
        if let stored = defaults.dictionary(forKey: "hotkeys"), let v = stored[name] {
            if let n = v as? Int { return n }
            if let n = (v as? NSNumber)?.intValue { return n }
        }
        return Self.screenshotDefaultHotkeys[name] ?? 0
    }

    // MARK: private helpers (Settings' own helpers are private to Settings.swift)

    private func ssBool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k) }
    private func ssDouble(_ k: String, _ d: Double, _ r: ClosedRange<Double>) -> Double {
        let v = defaults.object(forKey: k) == nil ? d : defaults.double(forKey: k)
        guard v.isFinite else { return d }
        return min(max(v, r.lowerBound), r.upperBound)
    }
    private func ssAction(_ k: String, _ d: ScreenshotAction) -> ScreenshotAction {
        defaults.string(forKey: k).flatMap(ScreenshotAction.init(rawValue:)) ?? d
    }

    // MARK: actions

    /// Return in the editor.
    public var screenshotDefaultAction: ScreenshotAction {
        get { ssAction("screenshotDefaultAction", .copy) }
        set { defaults.set(newValue.rawValue, forKey: "screenshotDefaultAction") }
    }
    /// Full-screen hotkey (`.editor` opens the overlay with the whole display selected).
    public var screenshotFullScreenAction: ScreenshotAction {
        get { ssAction("screenshotFullScreenAction", .copy) }
        set { defaults.set(newValue.rawValue, forKey: "screenshotFullScreenAction") }
    }
    /// Clicking a window in window mode (`.editor` keeps the selection editable).
    public var screenshotWindowAction: ScreenshotAction {
        get { ssAction("screenshotWindowAction", .editor) }
        set { defaults.set(newValue.rawValue, forKey: "screenshotWindowAction") }
    }

    // MARK: output

    public var screenshotFormat: ScreenshotFormat {
        get { defaults.string(forKey: "screenshotFormat").flatMap(ScreenshotFormat.init(rawValue:)) ?? .png }
        set { defaults.set(newValue.rawValue, forKey: "screenshotFormat") }
    }
    public var screenshotJPEGQuality: Double {
        get { ScreenshotGeometry.clampJPEGQuality(defaults.object(forKey: "screenshotJPEGQuality") == nil ? 0.9 : defaults.double(forKey: "screenshotJPEGQuality")) }
        set { defaults.set(ScreenshotGeometry.clampJPEGQuality(newValue), forKey: "screenshotJPEGQuality") }
    }
    public static var defaultScreenshotFolder: String {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        return pics.appendingPathComponent("DittoMac Screenshots", isDirectory: true).path
    }
    /// Absolute folder path ("~" is expanded on read).
    public var screenshotSaveFolder: String {
        get {
            let v = (defaults.string(forKey: "screenshotSaveFolder") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? Self.defaultScreenshotFolder : (v as NSString).expandingTildeInPath
        }
        set { defaults.set(newValue, forKey: "screenshotSaveFolder") }
    }
    public var screenshotNameTemplate: String {
        get {
            let v = defaults.string(forKey: "screenshotNameTemplate") ?? ""
            return v.trimmingCharacters(in: .whitespaces).isEmpty ? ScreenshotFileName.defaultTemplate : v
        }
        set { defaults.set(String(newValue.prefix(200)), forKey: "screenshotNameTemplate") }
    }
    /// Show a save panel (true) or save straight into the folder (false).
    public var screenshotAskWhereToSave: Bool {
        get { ssBool("screenshotAskWhereToSave", true) } set { defaults.set(newValue, forKey: "screenshotAskWhereToSave") }
    }

    // MARK: capture

    public var screenshotIncludeCursor: Bool {
        get { ssBool("screenshotIncludeCursor", false) } set { defaults.set(newValue, forKey: "screenshotIncludeCursor") }
    }
    /// 0, 3, 5 or 10 seconds.
    public var screenshotDelaySeconds: Int {
        get {
            let v = defaults.integer(forKey: "screenshotDelaySeconds")
            return Self.screenshotDelayChoices.contains(v) ? v : 0
        }
        set { defaults.set(Self.screenshotDelayChoices.contains(newValue) ? newValue : 0, forKey: "screenshotDelaySeconds") }
    }

    // MARK: overlay

    /// Darkening outside the selection, 0…0.85.
    public var screenshotDimOpacity: Double {
        get { ssDouble("screenshotDimOpacity", 0.45, 0...0.85) }
        set { defaults.set(min(max(newValue.isFinite ? newValue : 0.45, 0), 0.85), forKey: "screenshotDimOpacity") }
    }
    public var screenshotShowMagnifier: Bool {
        get { ssBool("screenshotShowMagnifier", true) } set { defaults.set(newValue, forKey: "screenshotShowMagnifier") }
    }
    public var screenshotPlaySound: Bool {
        get { ssBool("screenshotPlaySound", true) } set { defaults.set(newValue, forKey: "screenshotPlaySound") }
    }
    /// Also add every finished screenshot to the clip history (Quick Paste).
    public var screenshotAddToHistory: Bool {
        get { ssBool("screenshotAddToHistory", true) } set { defaults.set(newValue, forKey: "screenshotAddToHistory") }
    }

    // MARK: annotation tool memory (read/written by the annotation UI)

    public var screenshotRememberTool: Bool {
        get { ssBool("screenshotRememberTool", true) } set { defaults.set(newValue, forKey: "screenshotRememberTool") }
    }
    // screenshotLastTool / screenshotLastColor / screenshotLastLineWidth / screenshotLastFontSize are declared by the
    // annotation agent in Settings+Annotation.swift (their keys are listed in `screenshotKeys` so a reset clears them).

    // MARK: beautify (declared by the beautify agent; read here without redeclaring)

    /// Reads the beautify agent's "beautifyAutoApply" flag.
    public var screenshotBeautifyAutoApplyFlag: Bool { defaults.bool(forKey: "beautifyAutoApply") }

    /// Restores every screenshot setting to its default (not the hotkeys).
    public func resetScreenshotSettings() {
        for k in Self.screenshotKeys { defaults.removeObject(forKey: k) }
    }
}
