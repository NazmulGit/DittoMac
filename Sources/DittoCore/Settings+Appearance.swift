// Appearance, row layout, menu-bar icon and sticky-note preferences (v1.2). Theme name, font and popup size keep
// their original keys in Settings.swift.

import Foundation

extension Settings {
    private func aBool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k) }

    /// System / Light / Dark (applied to NSApp.appearance). Default System.
    public var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearanceMode") }
    }

    /// Selection colour override "#RRGGBB"; "" = the theme's (or the system's) selection colour.
    public var accentColorHex: String {
        get { defaults.string(forKey: "accentColorHex").flatMap { HexColor.normalize($0) } ?? "" }
        set { defaults.set(HexColor.normalize(newValue) ?? "", forKey: "accentColorHex") }
    }

    public var rowDensity: RowDensity {
        get { RowDensity(rawValue: defaults.string(forKey: "rowDensity") ?? "") ?? .comfortable }
        set { defaults.set(newValue.rawValue, forKey: "rowDensity") }
    }

    public static let rowCornerRadiusRange: ClosedRange<Double> = 0...14
    /// Corner radius of the rounded selection (0 = square, edge to edge as in upstream Ditto). Default 7.
    public var rowCornerRadius: Double {
        get {
            let v = defaults.object(forKey: "rowCornerRadius") == nil ? 7 : defaults.double(forKey: "rowCornerRadius")
            return v.isFinite ? min(max(v, Self.rowCornerRadiusRange.lowerBound), Self.rowCornerRadiusRange.upperBound) : 7
        }
        set {
            let v = newValue.isFinite ? newValue : 7
            defaults.set(min(max(v, Self.rowCornerRadiusRange.lowerBound), Self.rowCornerRadiusRange.upperBound), forKey: "rowCornerRadius")
        }
    }

    /// "5m", "3h", "Yesterday" at the right of each row. Default on.
    public var showRelativeTimestamps: Bool {
        get { aBool("showRelativeTimestamps", true) }
        set { defaults.set(newValue, forKey: "showRelativeTimestamps") }
    }

    /// Icon of the app a clip was copied from. Default off.
    public var showSourceAppIcon: Bool {
        get { aBool("showSourceAppIcon", false) }
        set { defaults.set(newValue, forKey: "showSourceAppIcon") }
    }

    /// Small "keeps formatting" / "has image" symbols. Default on.
    public var showFormatBadges: Bool {
        get { aBool("showFormatBadges", true) }
        set { defaults.set(newValue, forKey: "showFormatBadges") }
    }

    /// Subtle hairline between rows. Default on.
    public var showRowDividers: Bool {
        get { aBool("showRowDividers", true) }
        set { defaults.set(newValue, forKey: "showRowDividers") }
    }

    public var popupMaterial: PopupMaterial {
        get { PopupMaterial(rawValue: defaults.string(forKey: "popupMaterial") ?? "") ?? .opaque }
        set { defaults.set(newValue.rawValue, forKey: "popupMaterial") }
    }

    public var firstTenStyle: FirstTenStyle {
        get { FirstTenStyle(rawValue: defaults.string(forKey: "firstTenStyle") ?? "") ?? .badge }
        set { defaults.set(newValue.rawValue, forKey: "firstTenStyle") }
    }

    /// SF Symbol name for the menu-bar icon (validated against `MenuBarIcon.symbols`).
    public var menuBarIconSymbol: String {
        get { MenuBarIcon.sanitize(defaults.string(forKey: "menuBarIconSymbol") ?? MenuBarIcon.defaultSymbol) }
        set { defaults.set(MenuBarIcon.sanitize(newValue), forKey: "menuBarIconSymbol") }
    }

    /// Dim the menu-bar icon while disconnected from the clipboard. Default on.
    public var menuBarDimWhenDisconnected: Bool {
        get { aBool("menuBarDimWhenDisconnected", true) }
        set { defaults.set(newValue, forKey: "menuBarDimWhenDisconnected") }
    }

    /// Show the number of clips copied since Quick Paste was last opened next to the menu-bar icon. Default off.
    public var menuBarShowRecentCount: Bool {
        get { aBool("menuBarShowRecentCount", false) }
        set { defaults.set(newValue, forKey: "menuBarShowRecentCount") }
    }

    /// `copyCountTotal` when Quick Paste was last opened (badge baseline).
    public var menuBarCountBaseline: Int {
        get { defaults.integer(forKey: "menuBarCountBaseline") }
        set { defaults.set(max(0, newValue), forKey: "menuBarCountBaseline") }
    }

    // MARK: Sticky notes

    /// Reopen desktop notes that were open when DittoMac quit. Default on.
    public var restoreDesktopNotes: Bool {
        get { aBool("restoreDesktopNotes", true) }
        set { defaults.set(newValue, forKey: "restoreDesktopNotes") }
    }

    /// Clip ids of open desktop notes (at most 50).
    public var openDesktopNoteIDs: [Int64] {
        get { (defaults.array(forKey: "stickyNoteOpenIDs") ?? []).compactMap { ($0 as? NSNumber)?.int64Value }.prefix(50).map { $0 } }
        set { defaults.set(Array(newValue.prefix(50)).map { NSNumber(value: $0) }, forKey: "stickyNoteOpenIDs") }
    }

    /// Colour of a note (stored per clip in "stickyNoteColors").
    public func noteColor(for clipID: Int64) -> NoteColor? {
        (defaults.dictionary(forKey: "stickyNoteColors")?["\(clipID)"] as? String).map { NoteColor.named($0) }
    }

    public func setNoteColor(_ color: NoteColor?, for clipID: Int64) {
        var d = (defaults.dictionary(forKey: "stickyNoteColors") as? [String: String]) ?? [:]
        d["\(clipID)"] = color?.rawValue
        defaults.set(d, forKey: "stickyNoteColors")
    }

    /// Remembered note window frame ("{{x, y}, {w, h}}") per clip in "stickyNoteFrames".
    public func noteFrame(for clipID: Int64) -> String? {
        defaults.dictionary(forKey: "stickyNoteFrames")?["\(clipID)"] as? String
    }

    public func setNoteFrame(_ frame: String?, for clipID: Int64) {
        var d = (defaults.dictionary(forKey: "stickyNoteFrames") as? [String: String]) ?? [:]
        d["\(clipID)"] = frame
        defaults.set(d, forKey: "stickyNoteFrames")
    }

    /// Notes float above other windows unless turned off per note ("stickyNoteNotFloating", clip ids).
    public func noteFloats(_ clipID: Int64) -> Bool {
        !(defaults.array(forKey: "stickyNoteNotFloating") ?? []).contains { ($0 as? NSNumber)?.int64Value == clipID }
    }

    public func setNoteFloats(_ on: Bool, for clipID: Int64) {
        var ids = Set((defaults.array(forKey: "stickyNoteNotFloating") ?? []).compactMap { ($0 as? NSNumber)?.int64Value })
        if on { ids.remove(clipID) } else { ids.insert(clipID) }
        defaults.set(ids.sorted().map { NSNumber(value: $0) }, forKey: "stickyNoteNotFloating")
    }

    /// Forget everything stored for a deleted note.
    public func forgetNote(_ clipID: Int64) {
        setNoteColor(nil, for: clipID)
        setNoteFrame(nil, for: clipID)
        setNoteFloats(true, for: clipID)
        openDesktopNoteIDs = openDesktopNoteIDs.filter { $0 != clipID }
    }

    // MARK: Keys

    /// Appearance preference keys (reset by "Restore Appearance Defaults").
    public static let appearanceKeys: Set<String> = [
        "appearanceMode", "accentColorHex", "rowDensity", "rowCornerRadius", "showRelativeTimestamps",
        "showSourceAppIcon", "showFormatBadges", "showRowDividers", "popupMaterial", "firstTenStyle",
        "menuBarIconSymbol", "menuBarDimWhenDisconnected", "menuBarShowRecentCount", "restoreDesktopNotes",
    ]

    /// Per-note state (colours, frames, open ids); kept by an appearance reset.
    public static let stickyNoteStateKeys: Set<String> = [
        "stickyNoteColors", "stickyNoteFrames", "stickyNoteOpenIDs", "stickyNoteNotFloating",
        "menuBarCountBaseline",
    ]

    /// Restores the appearance defaults (plus theme and list font), keeping notes and everything else.
    public func resetAppearance() {
        for k in Self.appearanceKeys.union(["themeName", "fontName", "fontSize"]) { defaults.removeObject(forKey: k) }
    }
}
