// PasteFormat.swift — the formats a clip can be pasted / copied / saved in, and the per-app plain-text rule.

import Foundation

public enum PasteFormat: String, CaseIterable, Codable, Sendable {
    /// Every stored format, byte for byte (web archive, RTFD, RTF, HTML, images, …): the target picks the richest.
    case original
    /// Plain text only; all formatting removed.
    case plainText
    /// RTF (+ plain text): headings, bold, links and lists survive; images and HTML are dropped.
    case richText
    /// GitHub-flavoured Markdown as plain text.
    case markdown
    /// The HTML markup itself, pasted as plain text.
    case htmlSource

    public var title: String {
        switch self {
        case .original: return "Original (keep all formatting)"
        case .plainText: return "Plain Text"
        case .richText: return "Rich Text (no images)"
        case .markdown: return "Markdown"
        case .htmlSource: return "HTML Source"
        }
    }

    /// True when `list` (";"-separated wildcards on bundle id or app name) names the app. An empty list matches nothing.
    public static func appMatches(_ list: String, bundleID: String, appName: String) -> Bool {
        let l = list.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, l.contains(where: { $0 != ";" && !$0.isWhitespace }) else { return false }
        if !bundleID.isEmpty, CopyRuleEngine.wildcardMatch(l, bundleID) { return true }
        if !appName.isEmpty, CopyRuleEngine.wildcardMatch(l, appName) { return true }
        return false
    }
}
