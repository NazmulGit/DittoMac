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
