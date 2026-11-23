import Foundation

public struct CopyRule: Codable, Sendable, Equatable, Identifiable {
    public enum Action: String, Codable, Sendable, CaseIterable {
        case ignore, makeTopSticky, makeLastSticky, replaceTopSticky, neverAutoDelete, stripToPlainText, replaceRegex, moveToGroup
    }
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var appPattern: String
    public var textRegex: String
    public var action: Action
    public var replacement: String
    public var groupName: String

    public init(id: UUID = UUID(), name: String = "", enabled: Bool = true, appPattern: String = "*",
                textRegex: String = "", action: Action = .ignore, replacement: String = "", groupName: String = "") {
        self.id = id; self.name = name; self.enabled = enabled; self.appPattern = appPattern
        self.textRegex = textRegex; self.action = action; self.replacement = replacement; self.groupName = groupName
    }

    public static func defaultRules() -> [CopyRule] { [] }

    public static func encode(_ rules: [CopyRule]) -> Data? { try? JSONEncoder().encode(rules) }
    public static func decode(_ data: Data) -> [CopyRule]? { try? JSONDecoder().decode([CopyRule].self, from: data) }
}

public struct CopyRuleOutcome: Sendable {
    public var ignore = false
    public var text: String?
    public var stripToPlain = false
    public var makeTopSticky = false
    public var makeLastSticky = false
    public var replaceTopSticky = false
    public var neverAutoDelete = false
    public var groupName: String?
    public init() {}
}

public enum CopyRuleEngine {
    public static let maxRegexInput = 100_000

    public static func defaultRules() -> [CopyRule] { [] }

    public static func evaluate(rules: [CopyRule], text: String?, appBundleID: String, appName: String) -> CopyRuleOutcome {
        var outcome = CopyRuleOutcome()
        var current = text
        for rule in rules where rule.enabled {
            guard appMatches(rule.appPattern, bundleID: appBundleID, appName: appName) else { continue }
            var regex: NSRegularExpression?
            if !rule.textRegex.isEmpty {
                guard let t = current, !t.isEmpty,
                      let re = try? NSRegularExpression(pattern: rule.textRegex, options: [.caseInsensitive]) else { continue }
                regex = re
                if re.firstMatch(in: t, options: [], range: limitedRange(t)) == nil { continue }
            }
            switch rule.action {
            case .ignore:
                outcome.ignore = true
                outcome.text = current
                return outcome
            case .makeTopSticky: outcome.makeTopSticky = true
            case .makeLastSticky: outcome.makeLastSticky = true
            case .replaceTopSticky: outcome.replaceTopSticky = true
            case .neverAutoDelete: outcome.neverAutoDelete = true
            case .stripToPlainText: outcome.stripToPlain = true
            case .moveToGroup: if !rule.groupName.isEmpty { outcome.groupName = rule.groupName }
            case .replaceRegex:
                guard let t = current else { break }
                let re: NSRegularExpression
                if let r = regex { re = r }
                else if !rule.textRegex.isEmpty { break }
                else { break } // nothing to replace without a pattern
                let ns = t as NSString
                let n = min(ns.length, maxRegexInput)
                let head = ns.substring(to: n), tail = ns.substring(from: n)
                let replaced = re.stringByReplacingMatches(in: head, options: [], range: NSRange(location: 0, length: n),
                                                           withTemplate: rule.replacement)
                current = replaced + tail
            }
        }
        outcome.text = current
        return outcome
    }

    private static func limitedRange(_ s: String) -> NSRange {
        NSRange(location: 0, length: min((s as NSString).length, maxRegexInput))
    }

    private static func appMatches(_ pattern: String, bundleID: String, appName: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || p == "*" { return true }
        for part in p.split(separator: ";", omittingEmptySubsequences: true) {
            let pat = part.trimmingCharacters(in: .whitespaces)
            if pat.isEmpty { continue }
            if wildcardMatch(pat, bundleID) || wildcardMatch(pat, appName) { return true }
        }
        return false
    }

    /// Case-insensitive glob match. Supports `;`-separated alternatives, `*` and `?`. Empty or "*" matches anything.
    public static func wildcardMatch(_ pattern: String, _ s: String) -> Bool {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        if p.isEmpty || p == "*" { return true }
        let alternatives = p.split(separator: ";", omittingEmptySubsequences: true)
        let str = Array(s.lowercased())
        for alt in alternatives {
            let pat = Array(alt.trimmingCharacters(in: .whitespaces).lowercased())
            if globMatch(pat, str) { return true }
        }
        return false
    }

    private static func globMatch(_ p: [Character], _ s: [Character]) -> Bool {
        var pi = 0, si = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) && p[pi] != "*" { pi += 1; si += 1 }
            else if pi < p.count && p[pi] == "*" { star = pi; mark = si; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; si = mark }
            else { return false }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
