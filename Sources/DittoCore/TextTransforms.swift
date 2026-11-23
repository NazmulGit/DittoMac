import Foundation

/// Special-paste text transforms, matching upstream Ditto (OleClipSource.cpp).
public enum TextTransform: String, CaseIterable, Sendable {
    case plainText, upperCase, lowerCase, capitalize, sentenceCase, invertCase, trimWhiteSpace, camelCase,
         asciiOnly, removeLineFeeds, addOneLineFeed, addTwoLineFeeds, addCurrentTime, typoglycemia, slugify

    public var title: String {
        switch self {
        case .plainText: return "Plain Text Only"
        case .upperCase: return "UPPER CASE"
        case .lowerCase: return "lower case"
        case .capitalize: return "Capitalize Case"
        case .sentenceCase: return "Sentence case"
        case .invertCase: return "Invert Case"
        case .trimWhiteSpace: return "Trim White Space"
        case .camelCase: return "CamelCase"
        case .asciiOnly: return "ASCII Text Only"
        case .removeLineFeeds: return "Remove Line Feeds"
        case .addOneLineFeed: return "Paste + One Line Feed"
        case .addTwoLineFeeds: return "Paste + Two Line Feeds"
        case .addCurrentTime: return "Paste + Current Time"
        case .typoglycemia: return "Typoglycemia"
        case .slugify: return "Slugify"
        }
    }

    public func apply(_ s: String, slugSeparator: String = "-", now: Date = Date(),
                      rng: inout some RandomNumberGenerator) -> String {
        switch self {
        case .plainText:
            return s
        case .upperCase:
            return s.uppercased(with: .current)
        case .lowerCase:
            return s.lowercased(with: .current)
        case .capitalize:
            return Self.capitalizeWords(s.lowercased(with: .current))
        case .sentenceCase:
            return Self.sentenceCase(s.lowercased(with: .current))
        case .invertCase:
            var out = ""
            for ch in s {
                let str = String(ch)
                let up = str.uppercased(), low = str.lowercased()
                if str == up && str != low { out += low }
                else if str == low && str != up { out += up }
                else { out += str }
            }
            return out
        case .trimWhiteSpace:
            return s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        case .camelCase:
            let lowered = s.lowercased(with: .current)
            var out = ""
            var capNext = true
            for ch in lowered {
                if ch == " " { capNext = true; continue }
                if capNext { out += String(ch).uppercased(); capNext = false } else { out.append(ch) }
            }
            return out
        case .asciiOnly:
            var scalars = String.UnicodeScalarView()
            for u in s.unicodeScalars where u.value <= 0x7F { scalars.append(u) }
            return String(scalars)
        case .removeLineFeeds:
            return Self.collapseLineBreaks(s)
        case .addOneLineFeed:
            return s + "\n"
        case .addTwoLineFeeds:
            return s + "\n\n"
        case .addCurrentTime:
            let f = DateFormatter()
            f.locale = .current
            f.dateStyle = .medium
            f.timeStyle = .medium
            return s + "\n" + f.string(from: now)
        case .typoglycemia:
            return Self.typoglycemia(s, rng: &rng)
        case .slugify:
            return Self.slugify(s, separator: slugSeparator)
        }
    }

    public func apply(_ s: String) -> String {
        var rng = SystemRandomNumberGenerator()
        return apply(s, rng: &rng)
    }

    // MARK: helpers

    private static func capitalizeWords(_ s: String) -> String {
        var out = ""
        var atStart = true
        for ch in s {
            if ch.isWhitespace { atStart = true; out.append(ch); continue }
            if atStart { out += String(ch).uppercased(); atStart = false } else { out.append(ch) }
        }
        return out
    }

    private static func sentenceCase(_ lowered: String) -> String {
        var out = ""
        var capNext = true
        for ch in lowered {
            if ch == "." || ch == "!" || ch == "?" { capNext = true; out.append(ch); continue }
            if ch.isWhitespace { out.append(ch); continue }
            if capNext && ch.isLetter { out += String(ch).uppercased(); capNext = false }
            else { capNext = false; out.append(ch) }
        }
        return out
    }

    private static func collapseLineBreaks(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var prevCR = false
        for u in s.unicodeScalars {
            if u == "\r" { out.append(" "); prevCR = true; continue }
            if u == "\n" { if !prevCR { out.append(" ") } }
            else { out.append(u) }
            prevCR = false
        }
        return String(out)
    }

    private static func typoglycemia(_ s: String, rng: inout some RandomNumberGenerator) -> String {
        var out = ""
        var word: [Character] = []
        func flush(_ rng: inout some RandomNumberGenerator) {
            if word.count > 3 {
                let first = word[0], last = word[word.count - 1]
                let interior = Array(word[1..<(word.count - 1)])
                var shuffled = interior
                shuffled.shuffle(using: &rng)
                if shuffled == interior && Set(interior).count > 1 {
                    for _ in 0..<4 {
                        shuffled.shuffle(using: &rng)
                        if shuffled != interior { break }
                    }
                }
                out.append(first); out.append(contentsOf: shuffled); out.append(last)
            } else {
                out.append(contentsOf: word)
            }
            word.removeAll(keepingCapacity: true)
        }
        for ch in s {
            if ch.isLetter { word.append(ch) } else { flush(&rng); out.append(ch) }
        }
        flush(&rng)
        return out
    }

    private static func slugify(_ s: String, separator: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var out = ""
        var pendingSep = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                if pendingSep && !out.isEmpty { out += separator }
                pendingSep = false
                out.append(ch)
            } else {
                pendingSep = true
            }
        }
        return out
    }
}

public enum MultiPaste {
    /// Joins parts with a separator; "[LF]", "[CR]", "[TAB]" tokens are expanded.
    public static func join(_ parts: [String], separator: String, reverse: Bool) -> String {
        let sep = separator
            .replacingOccurrences(of: "[LF]", with: "\n")
            .replacingOccurrences(of: "[CR]", with: "\r")
            .replacingOccurrences(of: "[TAB]", with: "\t")
        return (reverse ? Array(parts.reversed()) : parts).joined(separator: sep)
    }
}

public enum RTFTransform {
    /// Replaces `\par` control words (followed by an optional space/newline) with a single space.
    public static func removeLineFeeds(_ rtf: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"\\par(?![A-Za-z0-9])(?:\r\n|[ \r\n])?"#) else { return rtf }
        let range = NSRange(rtf.startIndex..., in: rtf)
        return re.stringByReplacingMatches(in: rtf, options: [], range: range, withTemplate: " ")
    }
}
