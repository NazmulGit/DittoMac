import Foundation

public enum PopupPosition: String, Codable, Sendable, CaseIterable { case caret, cursor, previous }

public enum SearchMode: String, Codable, Sendable, CaseIterable { case wildcard, contains, regex }

public struct FriendPeer: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var sendAllCopies: Bool
    public init(id: UUID = UUID(), name: String, host: String, port: Int = 23443, sendAllCopies: Bool = false) {
        self.id = id; self.name = name; self.host = host; self.port = port; self.sendAllCopies = sendAllCopies
    }
}

/// A global/clip shortcut. Encoded as `(keyCode & 0xFFFF) | (carbonModifiers << 16)`.
public struct KeyCombo: Codable, Sendable, Hashable {
    public static let cmdKey: UInt32 = 0x100
    public static let shiftKey: UInt32 = 0x200
    public static let optionKey: UInt32 = 0x800
    public static let controlKey: UInt32 = 0x1000

    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    public init(encoded: Int) {
        let v = UInt64(UInt(bitPattern: encoded))
        self.keyCode = UInt32(v & 0xFFFF)
        self.modifiers = UInt32((v >> 16) & 0xFFFF)
    }

    public var encoded: Int { Int((keyCode & 0xFFFF) | ((modifiers & 0xFFFF) << 16)) }

    public var displayString: String {
        var s = ""
        if modifiers & Self.controlKey != 0 { s += "⌃" }
        if modifiers & Self.optionKey != 0 { s += "⌥" }
        if modifiers & Self.shiftKey != 0 { s += "⇧" }
        if modifiers & Self.cmdKey != 0 { s += "⌘" }
        return s + (Self.keyNames[keyCode] ?? "Key\(keyCode)")
    }

    // Carbon virtual key codes (ANSI layout).
    static let keyNames: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I",
        0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12", 0x69: "F13", 0x6B: "F14", 0x71: "F15",
        0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
        0x7B: "←", 0x7C: "→", 0x7E: "↑", 0x7D: "↓",
        0x31: "Space", 0x24: "Return", 0x35: "Esc", 0x33: "Delete", 0x75: "Fwd Delete", 0x30: "Tab",
        0x32: "`", 0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";", 0x27: "'",
        0x2B: ",", 0x2F: ".", 0x2C: "/", 0x73: "Home", 0x77: "End", 0x74: "Page Up", 0x79: "Page Down",
        0x4C: "Enter",
    ]
}

public final class Settings: @unchecked Sendable {
    public static let shared = Settings()

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static let defaultEnabledTypes = ["public.utf8-plain-text", "public.rtf", "public.html", "public.png", "public.file-url"]
    public static let defaultHotkeys: [String: Int] = [
        "activate": KeyCombo(keyCode: 0x32, modifiers: KeyCombo.controlKey).encoded,
    ]

    // MARK: primitive helpers

    private func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k) }
    private func int(_ k: String, _ d: Int, _ r: ClosedRange<Int>? = nil) -> Int {
        let v = defaults.object(forKey: k) == nil ? d : defaults.integer(forKey: k)
        return r.map { min(max(v, $0.lowerBound), $0.upperBound) } ?? v
    }
    private func set(_ k: String, _ v: Int, _ r: ClosedRange<Int>? = nil) {
        defaults.set(r.map { min(max(v, $0.lowerBound), $0.upperBound) } ?? v, forKey: k)
    }
    private func str(_ k: String, _ d: String) -> String { defaults.string(forKey: k) ?? d }
    private func dbl(_ k: String, _ d: Double) -> Double { defaults.object(forKey: k) == nil ? d : defaults.double(forKey: k) }
    private func optDbl(_ k: String) -> Double? { defaults.object(forKey: k) == nil ? nil : defaults.double(forKey: k) }
    private func setOpt(_ k: String, _ v: Double?) { if let v { defaults.set(v, forKey: k) } else { defaults.removeObject(forKey: k) } }

    // MARK: general

    public var connectedToClipboard: Bool { get { bool("connectedToClipboard", true) } set { defaults.set(newValue, forKey: "connectedToClipboard") } }
    public var showMenuBarIcon: Bool { get { bool("showMenuBarIcon", true) } set { defaults.set(newValue, forKey: "showMenuBarIcon") } }
    public var showDockIcon: Bool { get { bool("showDockIcon", false) } set { defaults.set(newValue, forKey: "showDockIcon") } }
    public var launchAtLogin: Bool { get { bool("launchAtLogin", true) } set { defaults.set(newValue, forKey: "launchAtLogin") } }
    public var showStartupMessage: Bool { get { bool("showStartupMessage", true) } set { defaults.set(newValue, forKey: "showStartupMessage") } }

    // MARK: retention / capture

    public var maxEntries: Int { get { int("maxEntries", 500, 1...1_000_000) } set { set("maxEntries", newValue, 1...1_000_000) } }
    public var checkForMaxEntries: Bool { get { bool("checkForMaxEntries", true) } set { defaults.set(newValue, forKey: "checkForMaxEntries") } }
    public var expiredEntries: Int { get { int("expiredEntries", 5, 1...36_500) } set { set("expiredEntries", newValue, 1...36_500) } }
    public var checkForExpiredEntries: Bool { get { bool("checkForExpiredEntries", false) } set { defaults.set(newValue, forKey: "checkForExpiredEntries") } }
    public var allowDuplicates: Bool { get { bool("allowDuplicates", false) } set { defaults.set(newValue, forKey: "allowDuplicates") } }
    public var allowBackToBackDuplicates: Bool { get { bool("allowBackToBackDuplicates", false) } set { defaults.set(newValue, forKey: "allowBackToBackDuplicates") } }
    public var descTextSize: Int { get { int("descTextSize", 500, 10...100_000) } set { set("descTextSize", newValue, 10...100_000) } }
    public var maxClipSizeBytes: Int { get { int("maxClipSizeBytes", 0, 0...Int.max) } set { set("maxClipSizeBytes", newValue, 0...Int.max) } }
    public var saveClipDelayMS: Int { get { int("saveClipDelayMS", 500, 0...10_000) } set { set("saveClipDelayMS", newValue, 0...10_000) } }
    public var supportAllTypes: Bool { get { bool("supportAllTypes", false) } set { defaults.set(newValue, forKey: "supportAllTypes") } }
    public var enabledTypes: [String] {
        get { defaults.stringArray(forKey: "enabledTypes") ?? Self.defaultEnabledTypes }
        set { defaults.set(newValue, forKey: "enabledTypes") }
    }
    public var copyAppInclude: String { get { str("copyAppInclude", "*") } set { defaults.set(newValue, forKey: "copyAppInclude") } }
    public var copyAppExclude: String { get { str("copyAppExclude", "") } set { defaults.set(newValue, forKey: "copyAppExclude") } }
    public var playSoundOnCopy: String { get { str("playSoundOnCopy", "") } set { defaults.set(newValue, forKey: "playSoundOnCopy") } }
    public var updateTimeOnPaste: Bool { get { bool("updateTimeOnPaste", true) } set { defaults.set(newValue, forKey: "updateTimeOnPaste") } }

    // MARK: popup

    public var linesPerRow: Int { get { int("linesPerRow", 2, 1...5) } set { set("linesPerRow", newValue, 1...5) } }
    public var popupPosition: PopupPosition {
        get { PopupPosition(rawValue: str("popupPosition", "caret")) ?? .caret }
        set { defaults.set(newValue.rawValue, forKey: "popupPosition") }
    }
    public var popupWidth: Int { get { int("popupWidth", 380, 200...4000) } set { set("popupWidth", newValue, 200...4000) } }
    public var popupHeight: Int { get { int("popupHeight", 460, 150...4000) } set { set("popupHeight", newValue, 150...4000) } }
    public var popupX: Double? { get { optDbl("popupX") } set { setOpt("popupX", newValue) } }
    public var popupY: Double? { get { optDbl("popupY") } set { setOpt("popupY", newValue) } }
    public var alwaysOnTop: Bool { get { bool("alwaysOnTop", false) } set { defaults.set(newValue, forKey: "alwaysOnTop") } }
    public var transparencyPercent: Int { get { int("transparencyPercent", 0, 0...40) } set { set("transparencyPercent", newValue, 0...40) } }
    public var themeName: String { get { str("themeName", "System") } set { defaults.set(newValue, forKey: "themeName") } }
    public var fontName: String { get { str("fontName", "") } set { defaults.set(newValue, forKey: "fontName") } }
    public var fontSize: Double { get { min(max(dbl("fontSize", 13), 6), 72) } set { defaults.set(min(max(newValue, 6), 72), forKey: "fontSize") } }

    // MARK: search

    public var findAsYouType: Bool { get { bool("findAsYouType", true) } set { defaults.set(newValue, forKey: "findAsYouType") } }
    public var searchDescription: Bool { get { bool("searchDescription", true) } set { defaults.set(newValue, forKey: "searchDescription") } }
    public var searchFullText: Bool { get { bool("searchFullText", false) } set { defaults.set(newValue, forKey: "searchFullText") } }
    public var searchQuickPaste: Bool { get { bool("searchQuickPaste", false) } set { defaults.set(newValue, forKey: "searchQuickPaste") } }
    public var searchMode: SearchMode {
        get { SearchMode(rawValue: str("searchMode", "wildcard")) ?? .wildcard }
        set { defaults.set(newValue.rawValue, forKey: "searchMode") }
    }
    public var regexCaseInsensitive: Bool { get { bool("regexCaseInsensitive", true) } set { defaults.set(newValue, forKey: "regexCaseInsensitive") } }
    public var maintainSearchView: Bool { get { bool("maintainSearchView", false) } set { defaults.set(newValue, forKey: "maintainSearchView") } }

    public static let maxSearchHistory = 10
    public static let maxSearchHistoryLength = 50
    public var searchHistory: [String] {
        get { Array((defaults.stringArray(forKey: "searchHistory") ?? []).prefix(Self.maxSearchHistory)) }
        set {
            let cleaned = newValue.prefix(Self.maxSearchHistory).map { String($0.prefix(Self.maxSearchHistoryLength)) }
            defaults.set(Array(cleaned), forKey: "searchHistory")
        }
    }
    /// Adds a term at the front (most recent first), de-duplicating and capping.
    public func addSearchHistory(_ term: String) {
        let t = String(term.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxSearchHistoryLength))
        guard !t.isEmpty else { return }
        var h = searchHistory.filter { $0 != t }
        h.insert(t, at: 0)
        searchHistory = h
    }

    // MARK: list / groups

    public var showAllClipsInMainList: Bool { get { bool("showAllClipsInMainList", true) } set { defaults.set(newValue, forKey: "showAllClipsInMainList") } }
    public var showGroupsInMainList: Bool { get { bool("showGroupsInMainList", false) } set { defaults.set(newValue, forKey: "showGroupsInMainList") } }
    public var promptForNewGroupName: Bool { get { bool("promptForNewGroupName", true) } set { defaults.set(newValue, forKey: "promptForNewGroupName") } }
    public var promptWhenDeletingClips: Bool { get { bool("promptWhenDeletingClips", true) } set { defaults.set(newValue, forKey: "promptWhenDeletingClips") } }
    public var drawThumbnails: Bool { get { bool("drawThumbnails", true) } set { defaults.set(newValue, forKey: "drawThumbnails") } }
    public var drawRTF: Bool { get { bool("drawRTF", false) } set { defaults.set(newValue, forKey: "drawRTF") } }
    public var drawCopiedColorCode: Bool { get { bool("drawCopiedColorCode", true) } set { defaults.set(newValue, forKey: "drawCopiedColorCode") } }
    public var showFirstTenIndex: Bool { get { bool("showFirstTenIndex", true) } set { defaults.set(newValue, forKey: "showFirstTenIndex") } }
    public var firstTenHotKeysStart: Int { get { int("firstTenHotKeysStart", 1, 0...9) } set { set("firstTenHotKeysStart", newValue, 0...9) } }
    public var showIfClipWasPasted: Bool { get { bool("showIfClipWasPasted", true) } set { defaults.set(newValue, forKey: "showIfClipWasPasted") } }
    public var revertToTopLevelGroup: Bool { get { bool("revertToTopLevelGroup", false) } set { defaults.set(newValue, forKey: "revertToTopLevelGroup") } }
    public var openToGroupByActiveApp: Bool { get { bool("openToGroupByActiveApp", false) } set { defaults.set(newValue, forKey: "openToGroupByActiveApp") } }

    // MARK: paste

    public var saveMultiPaste: Bool { get { bool("saveMultiPaste", false) } set { defaults.set(newValue, forKey: "saveMultiPaste") } }
    public var multiPasteSeparator: String { get { str("multiPasteSeparator", "[LF]") } set { defaults.set(newValue, forKey: "multiPasteSeparator") } }
    public var multiPasteReverse: Bool { get { bool("multiPasteReverse", true) } set { defaults.set(newValue, forKey: "multiPasteReverse") } }
    public var sendPasteAfterSelection: Bool { get { bool("sendPasteAfterSelection", true) } set { defaults.set(newValue, forKey: "sendPasteAfterSelection") } }
    public var moveSelectionOnOpenHotkey: Bool { get { bool("moveSelectionOnOpenHotkey", true) } set { defaults.set(newValue, forKey: "moveSelectionOnOpenHotkey") } }
    public var hideOnHotKeyIfAlreadyShown: Bool { get { bool("hideOnHotKeyIfAlreadyShown", true) } set { defaults.set(newValue, forKey: "hideOnHotKeyIfAlreadyShown") } }
    public var slugifySeparator: String { get { str("slugifySeparator", "-") } set { defaults.set(newValue, forKey: "slugifySeparator") } }

    // MARK: editor / tools

    public var editorWordWrap: Bool { get { bool("editorWordWrap", true) } set { defaults.set(newValue, forKey: "editorWordWrap") } }
    public var editorFontSize: Double { get { min(max(dbl("editorFontSize", 14), 6), 72) } set { defaults.set(min(max(newValue, 6), 72), forKey: "editorFontSize") } }
    public var webSearchURL: String { get { str("webSearchURL", "https://www.google.com/search?q=%s") } set { defaults.set(newValue, forKey: "webSearchURL") } }
    public var translateURL: String { get { str("translateURL", "https://translate.google.com/?text=%s") } set { defaults.set(newValue, forKey: "translateURL") } }
    public var qrBorderPixels: Int { get { int("qrBorderPixels", 30, 0...500) } set { set("qrBorderPixels", newValue, 0...500) } }
    public var wrapDescriptionText: Bool { get { bool("wrapDescriptionText", false) } set { defaults.set(newValue, forKey: "wrapDescriptionText") } }

    // MARK: friends

    public var friendsEnabled: Bool { get { bool("friendsEnabled", false) } set { defaults.set(newValue, forKey: "friendsEnabled") } }
    public var friendsPort: Int { get { int("friendsPort", 23443, 1024...65535) } set { set("friendsPort", newValue, 1024...65535) } }
    public var friendsDeviceName: String {
        get { defaults.string(forKey: "friendsDeviceName") ?? (Host.current().localizedName ?? "Mac") }
        set { defaults.set(newValue, forKey: "friendsDeviceName") }
    }
    public var friendsPeers: [FriendPeer] {
        get { (defaults.data(forKey: "friendsPeers")).flatMap { try? JSONDecoder().decode([FriendPeer].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "friendsPeers") }
    }
    public var friendsAutoPutOnClipboard: Bool { get { bool("friendsAutoPutOnClipboard", false) } set { defaults.set(newValue, forKey: "friendsAutoPutOnClipboard") } }

    // MARK: rules

    public var copyRules: [CopyRule] {
        get { (defaults.data(forKey: "copyRules")).flatMap { try? JSONDecoder().decode([CopyRule].self, from: $0) } ?? CopyRule.defaultRules() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "copyRules") }
    }

    // MARK: hotkeys

    public var hotkeys: [String: Int] {
        get {
            var d = Self.defaultHotkeys
            if let stored = defaults.dictionary(forKey: "hotkeys") {
                for (k, v) in stored { if let n = v as? Int { d[k] = n } else if let n = (v as? NSNumber)?.intValue { d[k] = n } }
            }
            return d
        }
        set { defaults.set(newValue, forKey: "hotkeys") }
    }
    public func hotkey(_ name: String) -> Int { hotkeys[name] ?? 0 }
    public func setHotkey(_ name: String, _ value: Int) {
        var d = (defaults.dictionary(forKey: "hotkeys") as? [String: Int]) ?? [:]
        d[name] = value
        defaults.set(d, forKey: "hotkeys")
    }

    // MARK: stats

    public var copyCountTotal: Int { get { int("copyCountTotal", 0, 0...Int.max) } set { set("copyCountTotal", newValue, 0...Int.max) } }
    public var pasteCountTotal: Int { get { int("pasteCountTotal", 0, 0...Int.max) } set { set("pasteCountTotal", newValue, 0...Int.max) } }
    public var copyCountTrip: Int { get { int("copyCountTrip", 0, 0...Int.max) } set { set("copyCountTrip", newValue, 0...Int.max) } }
    public var pasteCountTrip: Int { get { int("pasteCountTrip", 0, 0...Int.max) } set { set("pasteCountTrip", newValue, 0...Int.max) } }
    public var tripStartDate: Date {
        get { (defaults.object(forKey: "tripStartDate") as? Date) ?? ensureDate("tripStartDate") }
        set { defaults.set(newValue, forKey: "tripStartDate") }
    }
    public var totalStartDate: Date {
        get { (defaults.object(forKey: "totalStartDate") as? Date) ?? ensureDate("totalStartDate") }
        set { defaults.set(newValue, forKey: "totalStartDate") }
    }
    private func ensureDate(_ key: String) -> Date {
        let d = Date()
        defaults.set(d, forKey: key)
        return d
    }
    public func resetTrip() {
        copyCountTrip = 0
        pasteCountTrip = 0
        tripStartDate = Date()
    }
    public func recordCopy() { copyCountTotal += 1; copyCountTrip += 1 }
    public func recordPaste() { pasteCountTotal += 1; pasteCountTrip += 1 }

    // MARK: reset

    /// Removes every stored setting except stats counters, restoring all defaults.
    public func resetToDefaults() {
        let keep: Set<String> = ["copyCountTotal", "pasteCountTotal", "copyCountTrip", "pasteCountTrip", "tripStartDate", "totalStartDate"]
        for k in defaults.dictionaryRepresentation().keys where Self.allKeys.contains(k) && !keep.contains(k) {
            defaults.removeObject(forKey: k)
        }
    }

    static let allKeys: Set<String> = [
        "connectedToClipboard", "showMenuBarIcon", "showDockIcon", "launchAtLogin", "showStartupMessage", "maxEntries",
        "checkForMaxEntries", "expiredEntries", "checkForExpiredEntries", "allowDuplicates", "allowBackToBackDuplicates",
        "descTextSize", "maxClipSizeBytes", "saveClipDelayMS", "supportAllTypes", "enabledTypes", "copyAppInclude",
        "copyAppExclude", "playSoundOnCopy", "updateTimeOnPaste", "linesPerRow", "popupPosition",
        "popupWidth", "popupHeight", "popupX", "popupY", "alwaysOnTop", "transparencyPercent", "themeName", "fontName",
        "fontSize", "findAsYouType", "searchDescription", "searchFullText", "searchQuickPaste", "searchMode",
        "regexCaseInsensitive", "maintainSearchView", "searchHistory", "showAllClipsInMainList", "showGroupsInMainList",
        "promptForNewGroupName", "promptWhenDeletingClips", "drawThumbnails", "drawRTF", "drawCopiedColorCode",
        "showFirstTenIndex", "firstTenHotKeysStart", "showIfClipWasPasted", "revertToTopLevelGroup", "openToGroupByActiveApp",
        "saveMultiPaste", "multiPasteSeparator", "multiPasteReverse", "sendPasteAfterSelection", "moveSelectionOnOpenHotkey",
        "hideOnHotKeyIfAlreadyShown", "slugifySeparator", "editorWordWrap", "editorFontSize", "webSearchURL", "translateURL",
        "qrBorderPixels", "wrapDescriptionText", "friendsEnabled", "friendsPort",
        "friendsDeviceName", "friendsPeers", "friendsAutoPutOnClipboard", "copyRules", "hotkeys",
    ]
}
