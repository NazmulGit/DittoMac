// HotkeyClash.swift — duplicate-shortcut detection across every assigned hotkey (pure, testable).
import Foundation

public enum HotkeyClash {
    /// Name of another hotkey in `assignments` that already uses `value` (0 = unassigned never clashes).
    /// Deterministic: the alphabetically first clashing name.
    public static func firstClash(name: String, value: Int, in assignments: [String: Int]) -> String? {
        guard value != 0 else { return nil }
        return assignments.filter { $0.key != name && $0.value == value }.keys.sorted().first
    }
}

extension Settings {
    /// Every hotkey that is effectively assigned: the general ones plus the screenshot capture hotkeys, including
    /// their built-in defaults when the user never set them (`hotkeys` alone omits those).
    public var effectiveHotkeys: [String: Int] {
        var d = hotkeys
        for name in Self.screenshotHotkeyNames { d[name] = screenshotHotkey(name) }
        return d
    }
}
