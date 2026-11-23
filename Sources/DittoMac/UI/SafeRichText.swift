// SafeRichText.swift — rendering untrusted RTF/HTML clip content without remote loads or dangerous links.

import AppKit
import DittoCore

enum SafeRichText {
    /// HTML -> attributed string via the WebKit importer, but only after the allow-list sanitiser
    /// (no remote resources, no script) and with non-http(s)/mailto links removed.
    static func html(_ data: Data, maxBytes: Int = HTMLSanitizer.maxInputBytes) -> NSAttributedString? {
        guard data.count <= maxBytes else { return nil }
        let clean = HTMLSanitizer.sanitize(String(decoding: data, as: UTF8.self))
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let a = try? NSAttributedString(data: Data(clean.utf8), options: opts, documentAttributes: nil) else { return nil }
        return removingUnsafeLinks(a)
    }

    static func rtf(_ data: Data, maxBytes: Int) -> NSAttributedString? {
        guard data.count <= maxBytes, let a = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
        return removingUnsafeLinks(a)
    }

    /// RTFD (rich text with inline images, e.g. from Notes/TextEdit/Pages), parsed locally by AppKit.
    /// Only image attachments are kept: images whose header says they are too large to decode are replaced by a
    /// bounded thumbnail, and every non-image attachment (files, bundles, apps) becomes inert "[name]" text so
    /// nothing in the preview can be opened or executed. Unsafe links are removed as for RTF.
    static func rtfd(_ data: Data, maxBytes: Int) -> NSAttributedString? {
        guard data.count <= maxBytes else { return nil }
        let parsed = NSAttributedString(rtfd: data, documentAttributes: nil)
            ?? (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil))
        guard let parsed else { return nil }
        let m = NSMutableAttributedString(attributedString: removingUnsafeLinks(parsed))
        var replacements: [(NSRange, NSAttributedString)] = []
        m.enumerateAttribute(.attachment, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            guard let att = value as? NSTextAttachment else { return }
            let wrapper = att.fileWrapper
            let contents = (wrapper?.isRegularFile == true ? wrapper?.regularFileContents : nil) ?? att.contents
            let attrs = m.attributes(at: range.location, effectiveRange: nil).filter { $0.key != .attachment }
            if let d = contents, ImageProbe.pixelSize(d) != nil {
                if ImageProbe.isSafeToDecode(d) { return }                                  // keep as-is
                if let cg = ImageProbe.thumbnail(d, maxPixelSize: 2048) {
                    let a = NSTextAttachment()
                    a.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    replacements.append((range, NSAttributedString(attachment: a)))
                    return
                }
            }
            let name = wrapper?.preferredFilename ?? wrapper?.filename ?? "attachment"
            replacements.append((range, NSAttributedString(string: "[\(name)]", attributes: attrs)))
        }
        for (r, rep) in replacements.reversed() { m.replaceCharacters(in: r, with: rep) }
        return m
    }

    /// Drops `.link` attributes whose URL is not http(s) with a host or mailto (RTF HYPERLINK fields can
    /// point at file:// apps/scripts or custom URL schemes that NSTextView would open on click).
    static func removingUnsafeLinks(_ a: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: a)
        m.enumerateAttribute(.link, in: NSRange(location: 0, length: m.length)) { value, range, _ in
            guard let value else { return }
            if !isSafeLinkValue(value) { m.removeAttribute(.link, range: range) }
        }
        return m
    }

    static func isSafeLinkValue(_ value: Any) -> Bool {
        if let u = value as? URL { return LinkPolicy.isSafeToOpen(u) }
        if let s = value as? String { return LinkPolicy.isSafeToOpen(s) }
        return false
    }
}
