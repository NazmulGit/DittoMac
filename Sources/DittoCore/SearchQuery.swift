import Foundation

/// Parses the Quick Paste search box into a SQL WHERE fragment with `?` placeholders.
///
/// Wildcard mode (upstream semantics):
/// - whitespace-separated terms are ANDed; `OR` / `AND` (upper case) change the connector before the next term;
/// - `NOT term` or `!term` negates a term; `"double quoted phrases"` are one term (`!"…"` works too);
/// - `*` is a wildcard (→ `%`); user `%`, `_` and `\` are escaped so they match literally;
/// - every term matches as a substring in any enabled scope (description, full text, quick-paste text).
/// Contains mode: the whole string is one literal substring. Regex mode: `col REGEXP ?` (function registered by ClipStore).
/// Prefixes: `/q ` or `\q ` → quick-paste text only; `/f ` or `\f ` → full text only.
///
/// Column names are fixed constants; user text only ever travels in the returned `binds`.
/// Case-insensitive searches use `LIKE … ESCAPE '\'` (ASCII case folding, as upstream);
/// case-sensitive searches use `GLOB ?` with GLOB metacharacters escaped.
public struct SearchQuery: Sendable, Equatable {
    public enum Mode: String, Sendable, CaseIterable { case wildcard, contains, regex }

    public var raw: String
    public var mode: Mode
    public var searchDescription = true, searchFullText = false, searchQuickPaste = false
    public var caseInsensitive = true

    public init(_ raw: String, mode: Mode = .wildcard) {
        self.raw = raw
        self.mode = mode
    }

    // MARK: fixed column expressions (coordinated with ClipStore's query)

    static let descriptionColumn = "Main.mText"
    static let quickPasteColumn = "Main.QuickPasteText"
    /// ClipStore LEFT JOINs one `public.utf8-plain-text` Data row per clip under the alias `ft`.
    static let fullTextAlias = "ft"
    static let fullTextColumn = "COALESCE(CAST(ft.ooData AS TEXT), '')"

    enum Scope: Equatable { case description, fullText, quickPaste }

    /// The search text after the scope prefix is removed, plus the effective scopes.
    var resolved: (body: String, scopes: [Scope]) {
        var body = raw
        while let f = body.first, f.isWhitespace { body.removeFirst() }
        let lower = body.lowercased()
        for (prefix, scope) in [("/q ", Scope.quickPaste), ("\\q ", .quickPaste), ("/f ", .fullText), ("\\f ", .fullText)]
            where lower.hasPrefix(prefix) {
            return (String(body.dropFirst(prefix.count)), [scope])
        }
        var scopes: [Scope] = []
        if searchDescription { scopes.append(.description) }
        if searchFullText { scopes.append(.fullText) }
        if searchQuickPaste { scopes.append(.quickPaste) }
        if scopes.isEmpty { scopes = [.description] }
        return (body, scopes)
    }

    /// True when the query needs the full-text join.
    var usesFullText: Bool { !isEmpty && resolved.scopes.contains(.fullText) }

    /// True when the query matches everything (blank input).
    var isEmpty: Bool { resolved.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: parsing

    enum Connector: Equatable { case and, or }

    struct Term: Equatable {
        var text: String
        var negated: Bool
        var connector: Connector   // connector to the previous term (ignored for the first)
        var quoted: Bool
    }

    /// Tokenises a wildcard-mode query into terms with operators applied.
    static func parseTerms(_ input: String) -> [Term] {
        let chars = Array(input)
        var i = 0
        var terms: [Term] = []
        var pendingConnector = Connector.and
        var pendingNot = false

        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            var negated = false
            if chars[i] == "!" {
                negated = true
                i += 1
                if i >= chars.count || chars[i].isWhitespace { continue }   // bare "!" is ignored
            }
            var text = ""
            var quoted = false
            if chars[i] == "\"" {
                quoted = true
                i += 1
                while i < chars.count, chars[i] != "\"" { text.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }   // closing quote (unterminated → to end)
            } else {
                while i < chars.count, !chars[i].isWhitespace { text.append(chars[i]); i += 1 }
            }
            if !quoted && !negated {
                switch text {
                case "OR": pendingConnector = .or; continue
                case "AND": pendingConnector = .and; continue
                case "NOT": pendingNot.toggle(); continue
                default: break
                }
            }
            if text.isEmpty { pendingNot = false; continue }
            terms.append(Term(text: text, negated: negated != pendingNot, connector: pendingConnector, quoted: quoted))
            pendingConnector = .and
            pendingNot = false
        }
        return terms
    }

    /// Escapes LIKE metacharacters for use with `ESCAPE '\'`.
    static func escapeLike(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            if c == "\\" || c == "%" || c == "_" { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Escapes GLOB metacharacters (`*`, `?`, `[`) by bracketing them.
    static func escapeGlob(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "*": out += "[*]"
            case "?": out += "[?]"
            case "[": out += "[[]"
            default: out.append(c)
            }
        }
        return out
    }

    /// Substring pattern for one term. `wildcards` turns `*` into "any run of characters".
    func pattern(for text: String, wildcards: Bool) -> String {
        if caseInsensitive {
            var p = Self.escapeLike(text)
            if wildcards { p = p.replacingOccurrences(of: "*", with: "%") }
            return "%" + p + "%"
        } else {
            let p = wildcards
                ? text.split(separator: "*", omittingEmptySubsequences: false).map { Self.escapeGlob(String($0)) }.joined(separator: "*")
                : Self.escapeGlob(text)
            return "*" + p + "*"
        }
    }

    static func column(_ scope: Scope) -> String {
        switch scope {
        case .description: return descriptionColumn
        case .fullText: return fullTextColumn
        case .quickPaste: return quickPasteColumn
        }
    }

    // MARK: SQL

    public func sqlWhere() -> (sql: String, binds: [String]) {
        let (body, scopes) = resolved
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("1", []) }
        let columns = scopes.map(Self.column)
        let op = caseInsensitive ? "LIKE ? ESCAPE '\\'" : "GLOB ?"

        func termSQL(_ pattern: String, regex: Bool) -> (String, [String]) {
            let parts = columns.map { regex ? $0 + " REGEXP ?" : $0 + " " + op }
            return ("(" + parts.joined(separator: " OR ") + ")", Array(repeating: pattern, count: columns.count))
        }

        switch mode {
        case .regex:
            let p = caseInsensitive ? "(?i)" + trimmed : trimmed
            let (sql, binds) = termSQL(p, regex: true)
            return ("(" + sql + ")", binds)
        case .contains:
            let (sql, binds) = termSQL(pattern(for: trimmed, wildcards: false), regex: false)
            return ("(" + sql + ")", binds)
        case .wildcard:
            let terms = Self.parseTerms(body)
            guard !terms.isEmpty else { return ("1", []) }
            var sql = ""
            var binds: [String] = []
            for (n, t) in terms.enumerated() {
                if n > 0 { sql += t.connector == .or ? " OR " : " AND " }
                let (s, b) = termSQL(pattern(for: t.text, wildcards: true), regex: false)
                sql += t.negated ? "NOT " + s : s
                binds += b
            }
            return ("(" + sql + ")", binds)
        }
    }
}
