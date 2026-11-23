// RichFormats.swift — converting stored clip formats into each PasteFormat (and for Save As / capture).
//
// Security: HTML (incl. a web archive's main HTML) only reaches WebKit's importer through SafeRichText (allow-list
// sanitiser, no remote loads); Markdown / plain text from HTML use DittoCore's pure-Swift HTMLToMarkdown. RTF/RTFD
// are parsed locally by AppKit; web archives are never rendered or converted with WebKit.

import AppKit
import DittoCore

extension PasteContent {
    /// Parse caps (bytes). Larger formats are not converted (the Original format still pastes them byte for byte).
    static let maxRTFParseBytes = 16 * 1024 * 1024
    static let maxRTFDParseBytes = 64 * 1024 * 1024

    static func data(_ formats: [ClipFormat], _ type: String) -> Data? {
        formats.first { $0.type == type && !$0.data.isEmpty }?.data
    }

    /// The clip's HTML markup: `public.html`, else the main resource of a stored web archive.
    static func htmlSource(from formats: [ClipFormat]) -> String? {
        if let d = data(formats, ClipUTI.html) { return HTMLToMarkdown.decode(d) }
        if let d = data(formats, ClipUTI.webArchive), let html = WebArchive.mainHTML(d) { return html }
        return nil
    }

    static func rtfdData(from formats: [ClipFormat]) -> Data? {
        data(formats, ClipUTI.flatRTFD) ?? data(formats, ClipUTI.rtfd)
    }

    /// RTFD (rich text with attachments) as stored, parsed locally. nil when absent / too large / unreadable.
    static func rtfdAttributed(from formats: [ClipFormat]) -> NSAttributedString? {
        guard let d = rtfdData(from: formats), d.count <= maxRTFDParseBytes else { return nil }
        if let a = NSAttributedString(rtfd: d, documentAttributes: nil) { return a }
        return try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil)
    }

    static func rtfAttributed(from formats: [ClipFormat]) -> NSAttributedString? {
        guard let d = data(formats, ClipUTI.rtf), d.count <= maxRTFParseBytes else { return nil }
        return NSAttributedString(rtf: d, documentAttributes: nil)
    }

    /// Styled text for the clip without images: RTF, else RTFD minus attachments, else sanitised HTML.
    static func styledTextWithoutImages(from formats: [ClipFormat]) -> NSAttributedString? {
        if let a = rtfAttributed(from: formats) { return SafeRichText.removingUnsafeLinks(strippingAttachments(a)) }
        if let a = rtfdAttributed(from: formats) { return SafeRichText.removingUnsafeLinks(strippingAttachments(a)) }
        if let html = htmlSource(from: formats), let a = SafeRichText.html(Data(html.utf8)) { return strippingAttachments(a) }
        return nil
    }

    static func hasAttachments(_ a: NSAttributedString) -> Bool {
        var found = false
        a.enumerateAttribute(.attachment, in: NSRange(location: 0, length: a.length)) { v, _, stop in
            if v != nil { found = true; stop.pointee = true }
        }
        return found
    }

    static func strippingAttachments(_ a: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: a)
        var ranges: [NSRange] = []
        m.enumerateAttribute(.attachment, in: NSRange(location: 0, length: m.length)) { v, r, _ in
            if v != nil { ranges.append(r) }
        }
        for r in ranges.reversed() { m.deleteCharacters(in: r) }
        // Stray object-replacement characters (attachment lost on import).
        let s = m.string as NSString
        var i = s.length - 1
        while i >= 0 {
            if s.character(at: i) == 0xFFFC { m.deleteCharacters(in: NSRange(location: i, length: 1)) }
            i -= 1
        }
        return m
    }

    static func rtfData(_ a: NSAttributedString) -> Data? {
        a.rtf(from: NSRange(location: 0, length: a.length), documentAttributes: [:])
    }

    static func htmlData(_ a: NSAttributedString) -> Data? {
        try? a.data(from: NSRange(location: 0, length: a.length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                         .characterEncoding: String.Encoding.utf8.rawValue])
    }

    /// Plain text derived from rich formats only (capture: RTFD-/HTML-only sources). No WebKit involved.
    static func derivedPlainText(from formats: [ClipFormat]) -> String? {
        var text: String?
        if let a = rtfAttributed(from: formats) { text = a.string }
        else if let a = rtfdAttributed(from: formats) { text = strippingAttachments(a).string }
        else if let d = data(formats, ClipUTI.html) { text = HTMLToMarkdown.plainText(data: d) }
        else if let d = data(formats, ClipUTI.webArchive), let html = WebArchive.mainHTML(d) { text = HTMLToMarkdown.plainText(html) }
        guard let t = text?.replacingOccurrences(of: "\u{FFFC}", with: ""),
              !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return t
    }

    // MARK: Paste formats

    /// Markdown for one clip: HTML source → HTMLToMarkdown, else RTF/RTFD → RTFToMarkdown, else plain text.
    static func markdown(from formats: [ClipFormat]) -> String? {
        if let html = htmlSource(from: formats) {
            let md = HTMLToMarkdown.convert(html)
            if !md.isEmpty { return md }
        }
        if let a = rtfAttributed(from: formats) ?? rtfdAttributed(from: formats) {
            let md = RTFToMarkdown.convert(a)
            if !md.isEmpty { return md }
        }
        return text(from: formats)
    }

    /// HTML markup for one clip: stored HTML / web archive HTML, else generated locally from RTF/RTFD, else escaped text.
    static func htmlMarkup(from formats: [ClipFormat]) -> String? {
        if let html = htmlSource(from: formats) { return html }
        if let a = rtfAttributed(from: formats) ?? rtfdAttributed(from: formats),
           let d = htmlData(strippingAttachments(a)) { return String(decoding: d, as: UTF8.self) }
        guard let t = text(from: formats) else { return nil }
        let escaped = t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>\n")
        return "<p>" + escaped + "</p>"
    }

    /// Text payload for the text-only paste formats.
    static func string(for format: PasteFormat, from formats: [ClipFormat]) -> String? {
        switch format {
        case .original, .plainText, .richText: return text(from: formats)
        case .markdown: return markdown(from: formats)
        case .htmlSource: return htmlMarkup(from: formats)
        }
    }

    /// Pasteboard formats for one clip in `format`. nil when the clip has nothing usable.
    static func formats(for format: PasteFormat, from formats: [ClipFormat]) -> [ClipFormat]? {
        switch format {
        case .original:
            return formats.isEmpty ? nil : formats
        case .plainText, .markdown, .htmlSource:
            guard let s = string(for: format, from: formats) else { return nil }
            return [ClipFormat(type: ClipUTI.plainText, data: Data(s.utf8))]
        case .richText:
            let plain = text(from: formats)
            var out: [ClipFormat] = []
            if let a = styledTextWithoutImages(from: formats), let rtf = rtfData(a) {
                out.append(ClipFormat(type: ClipUTI.rtf, data: rtf))
                out.append(ClipFormat(type: ClipUTI.plainText, data: Data((plain ?? a.string).utf8)))
            } else if let plain {
                out.append(ClipFormat(type: ClipUTI.plainText, data: Data(plain.utf8)))
            }
            return out.isEmpty ? nil : out
        }
    }

    /// Rich-text (no images) attributed string for multi-clip joins; plain text when the clip has no styles.
    static func attributedForRichText(from formats: [ClipFormat]) -> NSAttributedString? {
        if let a = styledTextWithoutImages(from: formats) { return a }
        return text(from: formats).map { NSAttributedString(string: $0) }
    }
}

// MARK: - RTF / RTFD → Markdown

/// Attributed string (from RTF/RTFD) → Markdown. Bold/italic/monospace from font traits, strikethrough, safe links,
/// headings by font size relative to the body size (≥1.6× `#`, ≥1.3× `##`, ≥1.15× `###`), lists from NSTextList.
enum RTFToMarkdown {
    static let maxChars = 2_000_000

    static func convert(_ src: NSAttributedString) -> String {
        let a = src.length > maxChars ? src.attributedSubstring(from: NSRange(location: 0, length: maxChars)) : src
        guard a.length > 0 else { return "" }
        let ns = a.string as NSString
        let body = bodyFontSize(a)
        var lines: [String] = []
        var lastWasList = false
        var counters: [Int] = []
        var markerWidths: [Int] = []

        func blankLine() { if let l = lines.last, !l.isEmpty { lines.append("") } }

        var pos = 0
        while pos < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: pos, length: 0))
            guard pr.length > 0 else { break }
            pos = NSMaxRange(pr)
            var cr = pr
            while cr.length > 0, [0x0A, 0x0D, 0x2029].contains(ns.character(at: NSMaxRange(cr) - 1)) { cr.length -= 1 }

            let style = a.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
            let textLists = style?.textLists ?? []
            if !textLists.isEmpty { cr = strippingListMarker(ns, cr) }

            let raw = ns.substring(with: cr).replacingOccurrences(of: "\u{FFFC}", with: "")
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !lastWasList || textLists.isEmpty { blankLine() }
                if textLists.isEmpty { counters = []; markerWidths = []; lastWasList = false }
                continue
            }

            if !textLists.isEmpty {
                let level = min(textLists.count, 12)
                if counters.count < level { counters += Array(repeating: 0, count: level - counters.count) }
                counters = Array(counters.prefix(level))
                counters[level - 1] += 1
                let list = textLists[level - 1]
                let marker = isOrdered(list) ? "\(max(1, list.startingItemNumber) + counters[level - 1] - 1)." : "-"
                if markerWidths.count < level { markerWidths += Array(repeating: 2, count: level - markerWidths.count) }
                markerWidths = Array(markerWidths.prefix(level))
                markerWidths[level - 1] = marker.count + 1
                let indent = String(repeating: " ", count: markerWidths.prefix(level - 1).reduce(0, +))
                if !lastWasList { blankLine() }
                lines.append(indent + marker + " " + inline(a, cr, plainStyle: false))
                lastWasList = true
                continue
            }

            counters = []
            markerWidths = []
            lastWasList = false
            blankLine()
            let level = headingLevel(a, cr, body: body)
            if level > 0 {
                let t = inline(a, cr, plainStyle: true).replacingOccurrences(of: "  \n", with: " ")
                lines.append(String(repeating: "#", count: level) + " " + t)
            } else {
                lines.append(inline(a, cr, plainStyle: false))
            }
        }
        while let l = lines.last, l.isEmpty { lines.removeLast() }
        while let f = lines.first, f.isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    /// Most common font size, weighted by character count.
    static func bodyFontSize(_ a: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            let size = ((v as? NSFont)?.pointSize ?? 12)
            counts[(size * 2).rounded() / 2, default: 0] += r.length
        }
        return max(counts.max { $0.value < $1.value }?.key ?? 12, 1)
    }

    static func headingLevel(_ a: NSAttributedString, _ r: NSRange, body: CGFloat) -> Int {
        guard r.length > 0, r.length <= 300 else { return 0 }
        let ns = a.string as NSString
        var maxSize: CGFloat = 0
        a.enumerateAttribute(.font, in: r) { v, rr, _ in
            let t = ns.substring(with: rr)
            guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            maxSize = max(maxSize, (v as? NSFont)?.pointSize ?? body)
        }
        let ratio = maxSize / body
        if ratio >= 1.6 { return 1 }
        if ratio >= 1.3 { return 2 }
        if ratio >= 1.15 { return 3 }
        return 0
    }

    static func isOrdered(_ list: NSTextList) -> Bool {
        let f = list.markerFormat.rawValue.lowercased()
        return f.contains("decimal") || f.contains("alpha") || f.contains("roman") || f.contains("octal") || f.contains("hex")
    }

    /// RTF list paragraphs start with the rendered marker, e.g. "\t•\t" or "\t1.\t": drop it.
    static func strippingListMarker(_ ns: NSString, _ r: NSRange) -> NSRange {
        var i = r.location
        let end = NSMaxRange(r)
        if i < end, ns.character(at: i) == 0x09 { i += 1 }
        var j = i
        while j < end, j - i <= 12, ns.character(at: j) != 0x09 { j += 1 }
        guard j < end, ns.character(at: j) == 0x09, j - i <= 12 else { return r }
        return NSRange(location: j + 1, length: end - j - 1)
    }

    private struct Run {
        var text: String
        var bold = false, italic = false, strike = false, code = false
        var link: String?
        func sameStyle(_ o: Run) -> Bool {
            bold == o.bold && italic == o.italic && strike == o.strike && code == o.code && link == o.link
        }
    }

    /// Markdown for one paragraph's inline content. `plainStyle` (headings) drops bold/italic markers.
    static func inline(_ a: NSAttributedString, _ r: NSRange, plainStyle: Bool) -> String {
        let ns = a.string as NSString
        var runs: [Run] = []
        a.enumerateAttributes(in: r, options: []) { attrs, rr, _ in
            var t = ns.substring(with: rr).replacingOccurrences(of: "\u{FFFC}", with: "")
            t = t.replacingOccurrences(of: "\r", with: "")
            guard !t.isEmpty else { return }
            var run = Run(text: t)
            if let f = attrs[.font] as? NSFont {
                let traits = f.fontDescriptor.symbolicTraits
                run.bold = traits.contains(.bold)
                run.italic = traits.contains(.italic)
                run.code = traits.contains(.monoSpace)
            }
            if let s = attrs[.strikethroughStyle] as? Int, s != 0 { run.strike = true }
            if let v = attrs[.link] {
                let s = (v as? URL)?.absoluteString ?? (v as? String)
                if let s, LinkPolicy.isSafeToOpen(s) { run.link = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if plainStyle { run.bold = false; run.italic = false }
            if let last = runs.last, last.sameStyle(run) { runs[runs.count - 1].text += t } else { runs.append(run) }
        }
        var out = ""
        for run in runs {
            let lead = String(run.text.prefix(while: { $0 == " " || $0 == "\t" }))
            let trail = String(run.text.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed())
            var core = run.text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard !core.isEmpty else { out += run.text; continue }
            if run.code {
                core = codeSpan(core.replacingOccurrences(of: "\u{2028}", with: " "))
            } else {
                core = core.components(separatedBy: "\u{2028}").map(HTMLToMarkdown.escapeMarkdown).joined(separator: "  \n")
                if run.strike { core = "~~" + core + "~~" }
                if run.italic { core = "*" + core + "*" }
                if run.bold { core = "**" + core + "**" }
            }
            if let link = run.link {
                let url = link.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                core = "[" + core + "](" + url + ")"
            }
            out += lead + core + trail
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
}
