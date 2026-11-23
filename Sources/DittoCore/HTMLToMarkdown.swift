// HTMLToMarkdown.swift — HTML → GitHub-flavoured Markdown (and → plain text), in pure Swift.
//
// No WebKit, no network, no XML parser: a small forgiving tokenizer builds a bounded tree (depth ≤ 200, node count
// capped) that is rendered to Markdown. Links are kept only when `LinkPolicy` allows them (http/https/mailto), images
// only for http/https sources — nothing is ever fetched. Input above `maxInputBytes` is truncated first.
// Hostile or malformed markup never crashes: unknown constructs degrade to text.

import Foundation

public enum HTMLToMarkdown {
    /// Larger inputs are truncated to this many UTF-8 bytes before conversion.
    public static let maxInputBytes = 2 * 1024 * 1024
    static let maxDepth = 200
    static let maxNodes = 200_000

    /// HTML → GitHub-flavoured Markdown.
    public static func convert(_ html: String) -> String {
        render(html, markdown: true)
    }

    public static func convert(data: Data) -> String { convert(decode(data)) }

    /// HTML → readable plain text (block structure kept as line breaks, list bullets, tab-separated table cells).
    public static func plainText(_ html: String) -> String {
        render(html, markdown: false)
    }

    public static func plainText(data: Data) -> String { plainText(decode(data)) }

    /// Decodes HTML bytes from the pasteboard: BOM-aware, UTF-8 by default, Windows-1252 if the bytes aren't UTF-8.
    public static func decode(_ data: Data) -> String {
        let d = data.count > maxInputBytes ? data.prefix(maxInputBytes) : data
        let bytes = [UInt8](d.prefix(3))
        if bytes.count >= 2, (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            return String(data: d, encoding: .utf16) ?? String(decoding: d, as: UTF8.self)
        }
        if bytes.count == 3, bytes == [0xEF, 0xBB, 0xBF] { return String(decoding: d.dropFirst(3), as: UTF8.self) }
        if let s = String(data: d, encoding: .utf8) { return s }
        // Truncation may have cut a multi-byte sequence: repair rather than switching encodings.
        if data.count > maxInputBytes { return String(decoding: d, as: UTF8.self) }
        return String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
    }

    // MARK: Sentinels (private-use scalars, stripped from all input)

    static let hardBreak: Unicode.Scalar = "\u{E001}"
    static let preMark: Unicode.Scalar = "\u{E002}"
    static let indentMark: Unicode.Scalar = "\u{E003}"
    static let quoteMark: Unicode.Scalar = "\u{E004}"
    static func isSentinel(_ u: Unicode.Scalar) -> Bool { (0xE000...0xE00F).contains(u.value) }

    private static func render(_ html: String, markdown: Bool) -> String {
        var input = html
        if input.utf8.count > maxInputBytes {
            input = String(decoding: Array(input.utf8.prefix(maxInputBytes)), as: UTF8.self)
        }
        let job = ConversionJob(input: input, markdown: markdown)
        // The renderer recurses once per nesting level (≤ maxDepth). Secondary threads (GCD, test runners) have
        // 512 KB stacks, so run on a thread with a known-large stack instead of depending on the caller's.
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            job.run()
            done.signal()
        }
        thread.stackSize = 16 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
        done.wait()
        return job.output
    }

    private final class ConversionJob: @unchecked Sendable {
        let input: String
        let markdown: Bool
        var output = ""
        init(input: String, markdown: Bool) { self.input = input; self.markdown = markdown }
        func run() {
            let root = HTMLTreeBuilder(input).build()
            let raw = MarkdownRenderer(markdown: markdown).render(root, MarkdownRenderer.Ctx())
            output = MarkdownRenderer.postProcess(raw, markdown: markdown)
        }
    }

    // MARK: Escaping

    /// Backslash-escapes Markdown punctuation in literal text so it renders as typed (and inline HTML stays inert).
    public static func escapeMarkdown(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        let scalars = Array(s.unicodeScalars)
        // Line-start markers: escape the first non-space character when it would start a heading/quote/list.
        var firstNonSpace = 0
        while firstNonSpace < scalars.count, scalars[firstNonSpace] == " " { firstNonSpace += 1 }
        var escapeAt = -1
        if firstNonSpace < scalars.count {
            let c = scalars[firstNonSpace]
            let next: Unicode.Scalar? = firstNonSpace + 1 < scalars.count ? scalars[firstNonSpace + 1] : nil
            if c == "#" || c == ">" || c == "=" { escapeAt = firstNonSpace }
            else if (c == "-" || c == "+"), next == nil || next == " " { escapeAt = firstNonSpace }
            else if ("0"..."9").contains(c) {
                var j = firstNonSpace
                while j < scalars.count, ("0"..."9").contains(scalars[j]) { j += 1 }
                if j < scalars.count, scalars[j] == "." || scalars[j] == ")",
                   j + 1 == scalars.count || scalars[j + 1] == " " { escapeAt = j }
            }
        }
        for (i, c) in scalars.enumerated() {
            switch c {
            case "\\", "`", "*", "_", "[", "]", "<", "~", "|": out.append("\\")
            default: if i == escapeAt { out.append("\\") }
            }
            out.append(c)
        }
        return String(out)
    }

    // MARK: Entities

    /// Decodes named (common set) and numeric character references. Invalid code points become U+FFFD.
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            if u[i] == "&", let (scalar, len) = entity(u, at: i) {
                out.append(scalar)
                i += len
                continue
            }
            out.append(u[i])
            i += 1
        }
        return String(out)
    }

    private static func entity(_ u: [Unicode.Scalar], at start: Int) -> (Unicode.Scalar, Int)? {
        var i = start + 1
        guard i < u.count else { return nil }
        if u[i] == "#" {
            i += 1
            var hex = false
            if i < u.count, u[i] == "x" || u[i] == "X" { hex = true; i += 1 }
            var value: UInt32 = 0
            var digits = 0
            while i < u.count, digits < 10 {
                let c = u[i]
                let d: UInt32?
                if ("0"..."9").contains(c) { d = c.value - 48 }
                else if hex, ("a"..."f").contains(c) { d = c.value - 87 }
                else if hex, ("A"..."F").contains(c) { d = c.value - 55 }
                else { d = nil }
                guard let d else { break }
                value = value &* (hex ? 16 : 10) &+ d
                if value > 0x10FFFF { value = 0x110000 }     // saturate: stays invalid
                digits += 1
                i += 1
            }
            guard digits > 0 else { return nil }
            while i < u.count, ("0"..."9").contains(u[i]) || (hex && u[i].properties.isASCIIHexDigit) { i += 1 }  // overlong
            if i < u.count, u[i] == ";" { i += 1 }
            let scalar: Unicode.Scalar
            if value == 0 || value > 0x10FFFF || (0xD800...0xDFFF).contains(value) { scalar = "\u{FFFD}" }
            else if let w = windows1252[value] { scalar = w }
            else { scalar = Unicode.Scalar(value) ?? "\u{FFFD}" }
            return (isSentinel(scalar) ? "\u{FFFD}" : scalar, i - start)
        }
        var name = ""
        while i < u.count, name.unicodeScalars.count < 32, u[i].properties.isAlphabetic || ("0"..."9").contains(u[i]) {
            name.unicodeScalars.append(u[i])
            i += 1
        }
        guard !name.isEmpty else { return nil }
        if i < u.count, u[i] == ";", let v = namedEntities[name] { return (v, i + 1 - start) }
        // Legacy references that browsers accept without the semicolon.
        if let v = namedEntities[name], ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg", "AMP", "LT", "GT"].contains(name) {
            return (v, i - start)
        }
        return nil
    }

    /// C1 control references that browsers map to Windows-1252 characters.
    private static let windows1252: [UInt32: Unicode.Scalar] = [
        0x80: "\u{20AC}", 0x82: "\u{201A}", 0x83: "\u{0192}", 0x84: "\u{201E}", 0x85: "\u{2026}", 0x86: "\u{2020}",
        0x87: "\u{2021}", 0x88: "\u{02C6}", 0x89: "\u{2030}", 0x8A: "\u{0160}", 0x8B: "\u{2039}", 0x8C: "\u{0152}",
        0x8E: "\u{017D}", 0x91: "\u{2018}", 0x92: "\u{2019}", 0x93: "\u{201C}", 0x94: "\u{201D}", 0x95: "\u{2022}",
        0x96: "\u{2013}", 0x97: "\u{2014}", 0x98: "\u{02DC}", 0x99: "\u{2122}", 0x9A: "\u{0161}", 0x9B: "\u{203A}",
        0x9C: "\u{0153}", 0x9E: "\u{017E}", 0x9F: "\u{0178}",
    ]

    static let namedEntities: [String: Unicode.Scalar] = [
        "amp": "&", "AMP": "&", "lt": "<", "LT": "<", "gt": ">", "GT": ">", "quot": "\"", "QUOT": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}",
        "zwj": "\u{200D}", "shy": "\u{00AD}", "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—",
        "ndash": "–", "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "bull": "•", "middot": "·", "deg": "°",
        "plusmn": "±", "times": "×", "divide": "÷", "frac12": "½", "frac14": "¼", "frac34": "¾", "sup1": "¹",
        "sup2": "²", "sup3": "³", "micro": "µ", "para": "¶", "sect": "§", "euro": "€", "pound": "£", "yen": "¥",
        "cent": "¢", "curren": "¤", "iexcl": "¡", "iquest": "¿", "not": "¬", "macr": "¯", "acute": "´",
        "cedil": "¸", "uml": "¨", "ordf": "ª", "ordm": "º", "brvbar": "¦", "dagger": "†", "Dagger": "‡",
        "permil": "‰", "prime": "′", "Prime": "″", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓",
        "harr": "↔", "lArr": "⇐", "rArr": "⇒", "hArr": "⇔", "minus": "−", "le": "≤", "ge": "≥", "ne": "≠",
        "asymp": "≈", "infin": "∞", "sum": "∑", "prod": "∏", "radic": "√", "check": "✓", "hearts": "♥",
        "spades": "♠", "clubs": "♣", "diams": "♦", "loz": "◊", "star": "☆", "alpha": "α", "beta": "β",
        "gamma": "γ", "delta": "δ", "pi": "π", "sigma": "σ", "omega": "ω", "mu": "μ", "lambda": "λ",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ",
        "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë", "Igrave": "Ì", "Iacute": "Í",
        "Icirc": "Î", "Iuml": "Ï", "ETH": "Ð", "Ntilde": "Ñ", "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô",
        "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø", "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü",
        "Yacute": "Ý", "THORN": "Þ", "szlig": "ß", "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã",
        "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê",
        "euml": "ë", "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï", "eth": "ð", "ntilde": "ñ",
        "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø", "ugrave": "ù",
        "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý", "thorn": "þ", "yuml": "ÿ", "OElig": "Œ",
        "oelig": "œ", "Scaron": "Š", "scaron": "š", "Yuml": "Ÿ", "fnof": "ƒ", "circ": "ˆ", "tilde": "˜",
    ]
}

// MARK: - Tree

final class HTMLNode {
    let name: String                 // lower-case tag name, "#text" or "#root"
    var attrs: [String: String]
    var children: [HTMLNode] = []
    var text: String

    init(name: String, attrs: [String: String] = [:], text: String = "") {
        self.name = name
        self.attrs = attrs
        self.text = text
    }
}

/// Forgiving HTML tokenizer + tree builder with the handful of implied-end-tag rules that matter for structure.
final class HTMLTreeBuilder {
    private let s: [Unicode.Scalar]
    private var i = 0
    private let root = HTMLNode(name: "#root")
    private var stack: [HTMLNode]
    private var nodeCount = 0
    private var text = String.UnicodeScalarView()

    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
        "keygen", "image",
    ]
    /// Elements whose content is raw text; they are skipped entirely.
    static let rawTextElements: Set<String> = [
        "script", "style", "title", "textarea", "xmp", "iframe", "noembed", "noframes", "noscript", "plaintext",
    ]
    /// Elements dropped from the output together with their content.
    static let droppedElements: Set<String> = [
        "head", "template", "svg", "math", "object", "embed", "applet", "canvas", "video", "audio", "select",
        "button", "input", "option", "datalist", "map", "frameset", "frame", "dialog", "meta", "link", "base",
        "picture", "source", "track", "param", "form-hidden",
    ]
    private static let closesP: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "main",
        "menu", "nav", "ol", "p", "pre", "section", "summary", "table", "ul", "li", "dd", "dt",
    ]
    private static let scopeBoundaries: Set<String> = ["table", "td", "th", "caption", "button", "object", "template", "applet"]
    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    private static let headContent: Set<String> = ["meta", "link", "base", "title", "style", "script", "noscript", "template"]

    init(_ html: String) {
        s = Array(html.unicodeScalars)
        stack = [root]
    }

    func build() -> HTMLNode {
        while i < s.count {
            if s[i] == "<", parseMarkup() { continue }
            text.append(s[i])
            i += 1
        }
        flushText()
        return root
    }

    // MARK: Text

    private func flushText() {
        guard !text.isEmpty else { return }
        let decoded = HTMLToMarkdown.decodeEntities(String(text))
        text = String.UnicodeScalarView()
        let clean = String(String.UnicodeScalarView(decoded.unicodeScalars.filter { !HTMLToMarkdown.isSentinel($0) }))
        guard !clean.isEmpty else { return }
        let top = stack[stack.count - 1]
        // A body-level text run while <head> is still open ends the head (as browsers do).
        if top.name == "head", clean.unicodeScalars.contains(where: { !$0.properties.isWhitespace }) {
            stack.removeLast()
            appendText(clean)
            return
        }
        appendText(clean)
    }

    private func appendText(_ t: String) {
        let top = stack[stack.count - 1]
        if let last = top.children.last, last.name == "#text" { last.text += t; return }
        guard nodeCount < HTMLToMarkdown.maxNodes else { return }
        nodeCount += 1
        top.children.append(HTMLNode(name: "#text", text: t))
    }

    // MARK: Markup

    private static func isLetter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) || ("A"..."Z").contains(c) }
    private static func isSpace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\u{0C}" }

    private func starts(with lit: String, at j: Int) -> Bool {
        var k = j
        for c in lit.unicodeScalars {
            guard k < s.count, s[k] == c else { return false }
            k += 1
        }
        return true
    }

    private func skip(past ch: Unicode.Scalar, from j: Int) -> Int {
        var k = j
        while k < s.count, s[k] != ch { k += 1 }
        return min(k + 1, s.count)
    }

    /// At `<`. Consumes a tag / comment / declaration and returns true, or returns false if `<` is literal text.
    private func parseMarkup() -> Bool {
        let n = i + 1
        guard n < s.count else { return false }
        if s[n] == "!" {
            flushText()
            if starts(with: "--", at: n + 1) {
                var k = n + 3
                while k < s.count, !starts(with: "-->", at: k) { k += 1 }
                i = min(k + 3, s.count)
            } else {
                i = skip(past: ">", from: n)            // <!DOCTYPE …>, <![CDATA[ … ]]> (dropped)
            }
            return true
        }
        if s[n] == "?" {
            flushText()
            i = skip(past: ">", from: n)
            return true
        }
        var j = n
        var isEnd = false
        if s[j] == "/" { isEnd = true; j += 1 }
        guard j < s.count, Self.isLetter(s[j]) else {
            if isEnd, j < s.count {                      // "</ foo>" / "</>": bogus comment
                flushText()
                i = skip(past: ">", from: j)
                return true
            }
            return false
        }
        var nameScalars = String.UnicodeScalarView()
        while j < s.count, !Self.isSpace(s[j]), s[j] != "/", s[j] != ">" {
            if nameScalars.count < 64 { nameScalars.append(s[j]) }
            j += 1
        }
        let name = String(nameScalars).lowercased()
        var attrs: [String: String] = [:]
        var selfClosing = false
        var closed = false
        while j < s.count {
            while j < s.count, Self.isSpace(s[j]) { j += 1 }
            guard j < s.count else { break }
            if s[j] == ">" { j += 1; closed = true; break }
            if s[j] == "/" { selfClosing = true; j += 1; continue }
            selfClosing = false
            var an = String.UnicodeScalarView()
            while j < s.count, !Self.isSpace(s[j]), s[j] != "/", s[j] != ">", s[j] != "=" || an.isEmpty {
                if an.count < 64 { an.append(s[j]) }
                j += 1
            }
            while j < s.count, Self.isSpace(s[j]) { j += 1 }
            var value = String.UnicodeScalarView()
            if j < s.count, s[j] == "=" {
                j += 1
                while j < s.count, Self.isSpace(s[j]) { j += 1 }
                if j < s.count, s[j] == "\"" || s[j] == "'" {
                    let q = s[j]
                    j += 1
                    while j < s.count, s[j] != q {
                        if value.count < 16_384 { value.append(s[j]) }
                        j += 1
                    }
                    if j < s.count { j += 1 }
                } else {
                    while j < s.count, !Self.isSpace(s[j]), s[j] != ">" {
                        if value.count < 16_384 { value.append(s[j]) }
                        j += 1
                    }
                }
            }
            let key = String(an).lowercased()
            if !key.isEmpty, attrs[key] == nil, attrs.count < 64 {
                let v = HTMLToMarkdown.decodeEntities(String(value))
                attrs[key] = String(String.UnicodeScalarView(v.unicodeScalars.filter { !HTMLToMarkdown.isSentinel($0) }))
            }
        }
        flushText()
        i = j
        guard closed else { return true }            // unterminated tag at end of input: dropped
        if isEnd {
            endTag(name)
        } else {
            startTag(name, attrs: attrs, selfClosing: selfClosing)
            if Self.rawTextElements.contains(name) { skipRawText(name) }
        }
        return true
    }

    /// Skips the content of a raw-text element up to and including its end tag.
    private func skipRawText(_ name: String) {
        // The element was pushed by startTag; it is dropped from the tree regardless of its content.
        if let idx = stack.lastIndex(where: { $0.name == name }), idx > 0 { stack.removeSubrange(idx...) }
        if name == "plaintext" { i = s.count; return }
        let target = Array(("</" + name).unicodeScalars)
        var k = i
        while k < s.count {
            if s[k] == "<", k + target.count <= s.count {
                var match = true
                for (o, t) in target.enumerated() where Character(s[k + o]).lowercased() != Character(t).lowercased() {
                    match = false
                    break
                }
                if match {
                    let after = k + target.count
                    if after >= s.count || Self.isSpace(s[after]) || s[after] == ">" || s[after] == "/" {
                        i = skip(past: ">", from: after)
                        return
                    }
                }
            }
            k += 1
        }
        i = s.count
    }

    private func has(_ name: String, untilAny boundaries: Set<String>) -> Int? {
        var k = stack.count - 1
        while k > 0 {
            let n = stack[k].name
            if n == name { return k }
            if boundaries.contains(n) { return nil }
            k -= 1
        }
        return nil
    }

    private func popTo(_ idx: Int) { if idx > 0, idx < stack.count { stack.removeSubrange(idx...) } }

    private func startTag(_ name: String, attrs: [String: String], selfClosing: Bool) {
        if name == "html" { return }
        if name == "body" {
            if let h = stack.lastIndex(where: { $0.name == "head" }), h > 0 { popTo(h) }
            return
        }
        if stack.last?.name == "head", !Self.headContent.contains(name) { stack.removeLast() }

        if Self.closesP.contains(name), let p = has("p", untilAny: Self.scopeBoundaries) { popTo(p) }
        switch name {
        case "li":
            if let li = has("li", untilAny: Self.scopeBoundaries.union(["ul", "ol", "menu", "dir"])) { popTo(li) }
        case "dt", "dd":
            if let d = has("dd", untilAny: Self.scopeBoundaries.union(["dl"])) ?? has("dt", untilAny: Self.scopeBoundaries.union(["dl"])) { popTo(d) }
        case "tr":
            let table = stack.lastIndex(where: { ["table", "thead", "tbody", "tfoot"].contains($0.name) }) ?? 0
            if let tr = stack.lastIndex(where: { $0.name == "tr" }), tr > table { popTo(tr) }
        case "td", "th":
            let row = stack.lastIndex(where: { $0.name == "tr" || $0.name == "table" }) ?? 0
            if let cell = stack.lastIndex(where: { $0.name == "td" || $0.name == "th" }), cell > row { popTo(cell) }
        case "thead", "tbody", "tfoot":
            if let t = stack.lastIndex(where: { $0.name == "table" }), t + 1 < stack.count { popTo(t + 1) }
        case "a":
            if let a = has("a", untilAny: Self.scopeBoundaries) { popTo(a) }
        default:
            if Self.headings.contains(name), let top = stack.last, Self.headings.contains(top.name) { stack.removeLast() }
        }

        guard nodeCount < HTMLToMarkdown.maxNodes else { return }
        nodeCount += 1
        let node = HTMLNode(name: name, attrs: attrs)
        stack[stack.count - 1].children.append(node)
        if Self.voidElements.contains(name) || (selfClosing && !Self.rawTextElements.contains(name)) { return }
        if stack.count < HTMLToMarkdown.maxDepth { stack.append(node) }
    }

    private func endTag(_ name: String) {
        switch name {
        case "br": startTag("br", attrs: [:], selfClosing: true); return
        case "html", "body": return
        default: break
        }
        if let idx = stack.lastIndex(where: { $0.name == name }), idx > 0 { popTo(idx) }
    }
}

// MARK: - Rendering

final class MarkdownRenderer {
    struct Ctx {
        var pre = false
        var table = false
        var inLink = false
        var inItem = false
        var bold = false
        var italic = false
        var strike = false
    }

    let markdown: Bool
    init(markdown: Bool) { self.markdown = markdown }

    private static let blockElements: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "nav", "aside", "figure", "figcaption", "address",
        "details", "summary", "center", "dl", "dt", "dd", "form", "fieldset", "legend", "hgroup", "body", "html",
        "menuitem", "caption", "tr", "frame-body",
    ]

    private var hb: String { String(HTMLToMarkdown.hardBreak) }

    @inline(never) func children(_ n: HTMLNode, _ ctx: Ctx) -> String {
        var out = ""
        for c in n.children { out += render(c, ctx) }
        return out
    }

    func render(_ n: HTMLNode, _ ctx: Ctx) -> String {
        if HTMLTreeBuilder.droppedElements.contains(n.name) || HTMLTreeBuilder.rawTextElements.contains(n.name) { return "" }
        switch n.name {
        case "#text": return textNode(n, ctx)
        case "#root": return children(n, ctx)
        case "h1", "h2", "h3", "h4", "h5", "h6": return heading(n, ctx)
        case "br": return ctx.table ? " " : (markdown ? hb + "\n" : "\n")
        case "hr": return ctx.table ? " " : (markdown ? block("---") : "\n\n")
        case "b", "strong": return emphasis(n, ctx, marker: "**")
        case "i", "em", "cite", "dfn", "var": return emphasis(n, ctx, marker: "*")
        case "s", "del", "strike": return emphasis(n, ctx, marker: "~~")
        case "code", "kbd", "samp", "tt": return inlineCode(n, ctx)
        case "pre": return pre(n, ctx)
        case "a": return link(n, ctx)
        case "img": return image(n)
        case "ul", "ol", "menu", "dir": return list(n, ordered: n.name == "ol", ctx)
        case "li": return orphanItem(n, ctx)
        case "blockquote": return blockquote(n, ctx)
        case "table": return ctx.table ? " " + Self.singleLine(children(n, ctx)) + " " : table(n, ctx)
        case "td", "th": return children(n, ctx) + (ctx.table ? "" : " ")
        default:
            if Self.blockElements.contains(n.name) {
                return ctx.table ? " " + children(n, ctx) + " " : block(children(n, ctx))
            }
            return children(n, ctx)
        }
    }

    @inline(never) private func textNode(_ n: HTMLNode, _ ctx: Ctx) -> String {
        if ctx.pre { return n.text }
        let collapsed = Self.collapse(n.text)
        return markdown ? HTMLToMarkdown.escapeMarkdown(collapsed) : collapsed
    }

    @inline(never) private func heading(_ n: HTMLNode, _ ctx: Ctx) -> String {
        let content = Self.singleLine(children(n, ctx))
        guard !content.isEmpty else { return "" }
        if ctx.table { return content }
        let level = Int(String(n.name.dropFirst())) ?? 1
        return block(markdown ? String(repeating: "#", count: level) + " " + content : content)
    }

    @inline(never) private func emphasis(_ n: HTMLNode, _ ctx: Ctx, marker: String) -> String {
        var c = ctx
        switch marker {
        case "**": if ctx.bold || !markdown { return children(n, ctx) }; c.bold = true
        case "*": if ctx.italic || !markdown { return children(n, ctx) }; c.italic = true
        default: if ctx.strike || !markdown { return children(n, ctx) }; c.strike = true
        }
        return wrap(children(n, c), marker)
    }

    @inline(never) private func inlineCode(_ n: HTMLNode, _ ctx: Ctx) -> String {
        if ctx.pre { return children(n, ctx) }
        let t = Self.collapse(Self.textContent(n))
        guard markdown else { return t }
        let core = t.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return t }
        return (t.hasPrefix(" ") ? " " : "") + Self.codeSpan(core) + (t.hasSuffix(" ") ? " " : "")
    }

    @inline(never) private func orphanItem(_ n: HTMLNode, _ ctx: Ctx) -> String {
        // An item with no enclosing list: render like a one-item bulleted list.
        let wrapper = HTMLNode(name: "ul")
        wrapper.children = [n]
        return list(wrapper, ordered: false, ctx)
    }

    @inline(never) private func blockquote(_ n: HTMLNode, _ ctx: Ctx) -> String {
        var c = ctx
        c.inItem = false
        let content = Self.trimBlock(children(n, c))
        guard !content.isEmpty else { return "" }
        if ctx.table { return Self.singleLine(content) }
        let prefix = markdown ? String(HTMLToMarkdown.quoteMark) + String(HTMLToMarkdown.indentMark)
                              : String(HTMLToMarkdown.indentMark) + String(HTMLToMarkdown.indentMark)
        let lines = content.components(separatedBy: "\n").map { prefix + $0 }
        return "\n\n" + lines.joined(separator: "\n") + "\n\n"
    }

    // MARK: Pieces

    private func block(_ s: String) -> String {
        let t = Self.trimBlock(s)
        return t.isEmpty ? "" : "\n\n" + t + "\n\n"
    }

    private func wrap(_ inner: String, _ marker: String) -> String {
        let core = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty else { return inner }
        let lead = String(inner.prefix(while: { $0.isWhitespace }))
        let trail = String(inner.reversed().prefix(while: { $0.isWhitespace }).reversed())
        return lead + marker + core + marker + trail
    }

    @inline(never) private func pre(_ n: HTMLNode, _ ctx: Ctx) -> String {
        var text = Self.textContent(n)
        if text.hasPrefix("\r\n") { text.removeFirst(2) } else if text.hasPrefix("\n") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        while text.hasSuffix("\n") { text.removeLast() }
        if ctx.table {
            let t = Self.collapse(text).trimmingCharacters(in: .whitespaces)
            return markdown && !t.isEmpty ? Self.codeSpan(t) : t
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        let mark = String(HTMLToMarkdown.preMark)
        var lines = text.components(separatedBy: "\n")
        if markdown {
            var longest = 0, run = 0
            for ch in text { if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
            let fence = String(repeating: "`", count: max(3, longest + 1))
            let lang = Self.language(of: n)
            lines = [fence + lang] + lines + [fence]
        }
        return "\n\n" + lines.map { mark + $0 }.joined(separator: "\n") + "\n\n"
    }

    private static func language(of n: HTMLNode) -> String {
        var classes = (n.attrs["class"] ?? "")
        if let code = n.children.first(where: { $0.name == "code" }) { classes += " " + (code.attrs["class"] ?? "") }
        for c in classes.split(separator: " ") {
            for p in ["language-", "lang-"] where c.hasPrefix(p) {
                let l = c.dropFirst(p.count).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "+-#_.".contains($0)) }
                if !l.isEmpty { return String(l.prefix(32)) }
            }
        }
        return ""
    }

    @inline(never) private func link(_ n: HTMLNode, _ ctx: Ctx) -> String {
        var c = ctx; c.inLink = true
        let inner = children(n, c)
        guard markdown, !ctx.inLink, let raw = n.attrs["href"] else { return inner }
        let href = raw.filter { $0 != "\n" && $0 != "\r" && $0 != "\t" }.trimmingCharacters(in: .whitespaces)
        guard LinkPolicy.isSafeToOpen(href) else { return inner }
        let core = Self.singleLine(inner)
        guard !core.isEmpty else { return inner }
        let lead = inner.hasPrefix(" ") ? " " : ""
        let trail = inner.hasSuffix(" ") ? " " : ""
        return lead + "[" + core + "](" + Self.escapeURL(href) + ")" + trail
    }

    private func image(_ n: HTMLNode) -> String {
        guard markdown else { return "" }
        let alt = Self.collapse(n.attrs["alt"] ?? "").trimmingCharacters(in: .whitespaces)
        let src = (n.attrs["src"] ?? "").filter { $0 != "\n" && $0 != "\r" && $0 != "\t" }.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: src), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           LinkPolicy.isSafeToOpen(src) {
            return "![" + HTMLToMarkdown.escapeMarkdown(alt) + "](" + Self.escapeURL(src) + ")"
        }
        return alt.isEmpty ? "" : HTMLToMarkdown.escapeMarkdown(alt)
    }

    @inline(never) private func list(_ n: HTMLNode, ordered: Bool, _ ctx: Ctx) -> String {
        var items: [String] = []
        var itemCtx = ctx
        itemCtx.inItem = true
        func appendToLast(_ s: String, separator: String) {
            if items.isEmpty { items.append(s) } else { items[items.count - 1] += separator + s }
        }
        for child in n.children {
            switch child.name {
            case "li":
                items.append(Self.collapseNewlines(Self.trimBlock(children(child, itemCtx))))
            case "ul", "ol", "menu", "dir":
                let nested = Self.trimBlock(list(child, ordered: child.name == "ol", itemCtx))
                if !nested.isEmpty { appendToLast(nested, separator: "\n") }
            default:
                let r = Self.trimBlock(render(child, itemCtx))
                if !r.isEmpty { appendToLast(r, separator: " ") }
            }
        }
        items = items.filter { !$0.isEmpty }
        guard !items.isEmpty else { return "" }
        if ctx.table { return " " + items.joined(separator: "; ") + " " }
        var start = 1
        if ordered, let s = n.attrs["start"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
            start = min(max(s, 0), 999_999_999)
        }
        let indent = String(HTMLToMarkdown.indentMark)
        var lines: [String] = []
        for (k, item) in items.enumerated() {
            let marker = ordered ? "\(start + k)." : (markdown ? "-" : "•")
            let prefix = marker + " "
            let pad = String(repeating: indent, count: prefix.count)
            for (li, line) in item.components(separatedBy: "\n").enumerated() {
                if li == 0 { lines.append(prefix + line) } else { lines.append(line.isEmpty ? "" : pad + line) }
            }
        }
        let body = lines.joined(separator: "\n")
        return ctx.inItem ? "\n" + body + "\n" : "\n\n" + body + "\n\n"
    }

    @inline(never) private func table(_ n: HTMLNode, _ ctx: Ctx) -> String {
        var rows: [[String]] = []
        var caption = ""
        var cellCtx = ctx
        cellCtx.table = true
        cellCtx.inItem = false
        func cell(_ c: HTMLNode) -> String {
            var t = Self.singleLine(children(c, cellCtx))
            if !markdown { t = t.replacingOccurrences(of: "\t", with: " ") }
            return t
        }
        func collect(_ node: HTMLNode, depth: Int) {
            guard depth < 8 else { return }
            for c in node.children {
                switch c.name {
                case "tr":
                    let cells = c.children.filter { $0.name == "td" || $0.name == "th" }.prefix(64).map(cell)
                    if !cells.isEmpty, rows.count < 10_000 { rows.append(Array(cells)) }
                case "caption":
                    caption = Self.singleLine(children(c, cellCtx))
                case "#text", "table":
                    continue
                default:
                    collect(c, depth: depth + 1)
                }
            }
        }
        collect(n, depth: 0)
        guard !rows.isEmpty else { return caption.isEmpty ? "" : block(caption) }
        var out = caption.isEmpty ? "" : caption + "\n\n"
        if markdown {
            let cols = rows.map(\.count).max() ?? 1
            func line(_ cells: [String]) -> String {
                let padded = cells + Array(repeating: "", count: max(0, cols - cells.count))
                return "| " + padded.joined(separator: " | ") + " |"
            }
            var lines = [line(rows[0]), "| " + Array(repeating: "---", count: cols).joined(separator: " | ") + " |"]
            lines += rows.dropFirst().map(line)
            out += lines.joined(separator: "\n")
        } else {
            out += rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        }
        return "\n\n" + out + "\n\n"
    }

    // MARK: Helpers

    /// Browser whitespace collapsing: runs of ASCII whitespace become one space (NBSP is kept).
    static func collapse(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var lastSpace = false
        for u in s.unicodeScalars {
            if u == " " || u == "\n" || u == "\t" || u == "\r" || u == "\u{0C}" {
                if !lastSpace { out.append(" ") }
                lastSpace = true
            } else {
                out.append(u)
                lastSpace = false
            }
        }
        return String(out)
    }

    /// Text of a subtree (for code / pre), with `<br>` as a newline and dropped elements skipped.
    static func textContent(_ n: HTMLNode) -> String {
        var out = ""
        func walk(_ x: HTMLNode) {
            if x.name == "#text" { out += x.text; return }
            if x.name == "br" { out += "\n"; return }
            if HTMLTreeBuilder.droppedElements.contains(x.name) || HTMLTreeBuilder.rawTextElements.contains(x.name) { return }
            for c in x.children { walk(c) }
        }
        walk(n)
        return out
    }

    static func trimBlock(_ s: String) -> String {
        var scalars = Substring(s).unicodeScalars[...]
        func trimmable(_ u: Unicode.Scalar) -> Bool {
            u == " " || u == "\n" || u == "\t" || u == "\r" || u == HTMLToMarkdown.hardBreak
        }
        while let f = scalars.first, trimmable(f) { scalars.removeFirst() }
        while let l = scalars.last, trimmable(l) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// One line: newlines / hard breaks / block markers become spaces.
    static func singleLine(_ s: String) -> String {
        let mapped = s.unicodeScalars.map { u -> Unicode.Scalar in
            (u == "\n" || u == "\r" || HTMLToMarkdown.isSentinel(u)) ? " " : u
        }
        return collapse(String(String.UnicodeScalarView(mapped))).trimmingCharacters(in: .whitespaces)
    }

    static func collapseNewlines(_ s: String) -> String {
        var out = ""
        var newlines = 0
        for ch in s {
            if ch == "\n" {
                newlines += 1
                if newlines <= 2 { out.append(ch) }
            } else {
                newlines = 0
                out.append(ch)
            }
        }
        return out
    }

    static func codeSpan(_ t: String) -> String {
        var longest = 0, run = 0
        for ch in t { if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = (t.hasPrefix("`") || t.hasSuffix("`")) ? " " : ""
        return fence + pad + t + pad + fence
    }

    static func escapeURL(_ u: String) -> String {
        var out = ""
        for ch in u {
            switch ch {
            case " ": out += "%20"
            case "(": out += "%28"
            case ")": out += "%29"
            case "<": out += "%3C"
            case ">": out += "%3E"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Line-level clean-up: indentation markers → spaces / `>`, collapsed inner spaces, trailing spaces removed,
    /// hard breaks → two trailing spaces, at most one blank line in a row; preformatted lines are left untouched.
    static func postProcess(_ raw: String, markdown: Bool) -> String {
        var out: [String] = []
        var lastBlankIndent: String?
        for line in raw.components(separatedBy: "\n") {
            let scalars = Array(line.unicodeScalars)
            var k = 0
            var indent = ""
            while k < scalars.count {
                let u = scalars[k]
                if u == HTMLToMarkdown.indentMark { indent += " " }
                else if u == HTMLToMarkdown.quoteMark { indent += ">" }
                else if u != " " { break }
                k += 1
            }
            let restScalars = scalars[k...]
            if restScalars.first == HTMLToMarkdown.preMark {
                out.append(indent + String(String.UnicodeScalarView(restScalars.filter { !HTMLToMarkdown.isSentinel($0) })))
                lastBlankIndent = nil
                continue
            }
            var rest = ""
            var lastWasSpace = false
            var hardBreak = false
            for u in restScalars {
                if u == HTMLToMarkdown.hardBreak { hardBreak = true; continue }
                if HTMLToMarkdown.isSentinel(u) { continue }
                let isSpace = u == " " || u == "\u{00A0}" || (markdown && u == "\t")   // plain tables use tabs
                if isSpace {
                    if !lastWasSpace { rest.unicodeScalars.append(" ") }
                    lastWasSpace = true
                } else {
                    rest.unicodeScalars.append(u)
                    lastWasSpace = false
                }
            }
            while rest.hasSuffix(" ") { rest.removeLast() }
            if rest.isEmpty {
                let blank = indent.contains(">") ? String(indent.reversed().drop(while: { $0 == " " }).reversed()) : ""
                if lastBlankIndent == blank { continue }
                if out.isEmpty && blank.isEmpty { continue }
                out.append(blank)
                lastBlankIndent = blank
                continue
            }
            lastBlankIndent = nil
            out.append(indent + rest + (hardBreak && markdown ? "  " : ""))
        }
        while let l = out.last, l.isEmpty || l == ">" { out.removeLast() }
        return out.joined(separator: "\n")
    }
}
