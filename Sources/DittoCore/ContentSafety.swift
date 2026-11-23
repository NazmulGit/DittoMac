// ContentSafety.swift — helpers for rendering untrusted clip content (clipboard, imports, Friends peers).
//
//  HTMLSanitizer : allow-list HTML sanitiser run before the WebKit-based NSAttributedString HTML importer.
//                  Parses with XMLDocument (tidy), re-serialises only known-safe elements/attributes, so no
//                  remote resource can be fetched and no script can run. Regex blacklists are bypassable
//                  (entities, `<img/src=…>`, `xlink:href`, CSS escapes); this is not.
//  LinkPolicy    : which link URLs may be opened from rendered rich text (http/https/mailto only).
//  ImageProbe    : reads image pixel dimensions from the header without decoding, to refuse decompression bombs.

import Foundation
import ImageIO

// MARK: - Links

public enum LinkPolicy {
    /// True for URLs that are safe to hand to NSWorkspace from a click in rendered clip content:
    /// `https`/`http` with a host, or `mailto`. Everything else (`file:`, `javascript:`, custom app schemes,
    /// `smb:`, `x-apple.systempreferences:` …) is refused.
    public static func isSafeToOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "https", "http": return url.host?.isEmpty == false
        case "mailto": return true
        default: return false
        }
    }

    public static func isSafeToOpen(_ string: String) -> Bool {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject control characters and whitespace inside the URL (scheme obfuscation like "java\tscript:").
        guard !t.isEmpty, !t.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F }),
              let url = URL(string: t) else { return false }
        return isSafeToOpen(url)
    }
}

// MARK: - HTML

public enum HTMLSanitizer {
    /// Inputs above this size are not parsed (the result is the escaped, tag-stripped text, truncated).
    public static let maxInputBytes = 2 * 1024 * 1024
    static let maxDepth = 200

    /// Elements kept (with their filtered attributes).
    static let allowedElements: Set<String> = [
        "p", "div", "span", "br", "hr", "b", "strong", "i", "em", "u", "s", "strike", "del", "ins", "sub", "sup",
        "small", "big", "font", "code", "pre", "tt", "kbd", "samp", "var", "blockquote", "q", "cite", "abbr",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot",
        "tr", "td", "th", "caption", "colgroup", "col", "a", "center", "mark", "address", "section", "article",
        "header", "footer", "nav", "aside", "main", "figure", "figcaption", "details", "summary", "wbr",
    ]
    /// Elements removed together with everything inside them.
    static let droppedElements: Set<String> = [
        "head", "title", "script", "style", "iframe", "frame", "frameset", "object", "embed", "applet", "noscript",
        "noframes", "template", "svg", "math", "video", "audio", "canvas", "form", "input", "button", "select",
        "textarea", "option", "link", "meta", "base", "img", "image", "picture", "source", "track", "map", "area",
        "portal", "xml", "param", "dialog", "slot",
    ]
    static let voidElements: Set<String> = ["br", "hr", "col", "wbr"]
    /// Attributes kept on any allowed element. `href` (on `a` only) and `style` are filtered separately.
    static let allowedAttributes: Set<String> = [
        "title", "dir", "lang", "align", "valign", "colspan", "rowspan", "color", "face", "size", "width", "height",
        "border", "cellpadding", "cellspacing", "bgcolor", "class", "id", "start", "type", "reversed", "span", "nowrap",
    ]

    /// Returns HTML containing only allow-listed markup. Never returns markup that can load a resource.
    public static func sanitize(_ html: String) -> String {
        guard html.utf8.count <= maxInputBytes else {
            return wrap(escape(stripTags(String(html.prefix(maxInputBytes)))))
        }
        // xmlString: (not data:) so the parser gets Unicode text; with bytes it guesses Latin-1 and drops non-ASCII.
        guard let doc = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else {
            return wrap(escape(stripTags(html)))
        }
        var out = ""
        for child in doc.children ?? [] { emit(child, depth: 0, into: &out) }
        return wrap(out)
    }

    private static func wrap(_ body: String) -> String {
        "<html><head><meta charset=\"utf-8\"></head><body>" + body + "</body></html>"
    }

    private static func emit(_ node: XMLNode, depth: Int, into out: inout String) {
        switch node.kind {
        case .text:
            out += escape(node.stringValue ?? "")
        case .element:
            guard let el = node as? XMLElement else { return }
            let name = (el.localName ?? el.name ?? "").lowercased()
            if droppedElements.contains(name) { return }
            if depth >= maxDepth {                       // pathological nesting: keep the text only
                out += escape(el.stringValue ?? "")
                return
            }
            let keep = allowedElements.contains(name)
            if keep {
                out += "<" + name
                for attr in el.attributes ?? [] {
                    let an = (attr.name ?? "").lowercased()
                    let value = attr.stringValue ?? ""
                    if let kept = filteredAttribute(element: name, name: an, value: value) {
                        out += " " + an + "=\"" + escape(kept, attribute: true) + "\""
                    }
                }
                out += ">"
                if voidElements.contains(name) { return }
            }
            for child in el.children ?? [] { emit(child, depth: depth + 1, into: &out) }
            if keep { out += "</" + name + ">" }
        default:
            // document / DTD / comments / processing instructions / namespaces: nothing (children handled above)
            if node.kind == .document {
                for child in node.children ?? [] { emit(child, depth: depth + 1, into: &out) }
            }
        }
    }

    static func filteredAttribute(element: String, name: String, value: String) -> String? {
        if name.contains(":") { return nil }                 // xlink:href, xml:base, …
        if name == "href" {
            guard element == "a", LinkPolicy.isSafeToOpen(value) else { return nil }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if name == "style" { return isSafeStyle(value) ? value : nil }
        return allowedAttributes.contains(name) ? value : nil
    }

    /// Inline CSS is kept only if it cannot reference a resource or use escapes to hide one.
    static func isSafeStyle(_ css: String) -> Bool {
        let s = css.lowercased()
        for bad in ["url", "\\", "@", "expression", "image", "src", "behavior", "binding", "&", "/*", "<", "attr("]
            where s.contains(bad) { return false }
        return true
    }

    static func escape(_ s: String, attribute: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "'" where attribute: out += "&#39;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    /// Crude fallback when the document cannot be parsed: drop everything between `<` and `>`.
    static func stripTags(_ s: String) -> String {
        var out = ""
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" && inTag { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out
    }
}

// MARK: - Images

public enum ImageProbe {
    /// Largest image (in pixels) decoded at full size; ~400 MB of RGBA. Bigger images are shown as thumbnails.
    public static let maxDecodePixels = 100_000_000

    /// Pixel size read from the image header (no decode). nil if the data is not a readable image.
    public static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// True when the image header is readable and its full decode stays under `maxPixels`.
    public static func isSafeToDecode(_ data: Data, maxPixels: Int = maxDecodePixels) -> Bool {
        guard let (w, h) = pixelSize(data) else { return false }
        let (product, overflow) = w.multipliedReportingOverflow(by: h)
        return !overflow && product <= maxPixels
    }

    /// Downsampled decode (bounded memory) for display of any image, including oversized ones.
    public static func thumbnail(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
