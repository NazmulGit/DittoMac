// WebArchive.swift — reads the main HTML document out of a `com.apple.webarchive` (a property list) without WebKit.
// Used to derive plain text / Markdown / HTML source from Safari copies. Sub-resources are never loaded or fetched.

import Foundation

public enum WebArchive {
    /// Archives larger than this are not parsed.
    public static let maxBytes = 64 * 1024 * 1024

    /// The main resource's markup when it is HTML/XHTML (nil for anything else or malformed data).
    public static func mainHTML(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maxBytes,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let main = root["WebMainResource"] as? [String: Any],
              let body = main["WebResourceData"] as? Data else { return nil }
        let mime = (main["WebResourceMIMEType"] as? String)?.lowercased() ?? "text/html"
        guard mime.contains("html") else { return nil }
        let enc = (main["WebResourceTextEncodingName"] as? String)?.lowercased() ?? "utf-8"
        let slice = body.count > HTMLToMarkdown.maxInputBytes ? body.prefix(HTMLToMarkdown.maxInputBytes) : body
        if enc.contains("16"), let s = String(data: slice, encoding: .utf16) { return s }
        if enc.contains("1252") || enc.contains("latin") || enc.contains("8859-1"),
           let s = String(data: slice, encoding: .windowsCP1252) { return s }
        return HTMLToMarkdown.decode(slice)
    }

    /// Number of embedded sub-resources (images, stylesheets …) — informational only.
    public static func subresourceCount(_ data: Data) -> Int {
        guard !data.isEmpty, data.count <= maxBytes,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any] else { return 0 }
        return (root["WebSubresources"] as? [Any])?.count ?? 0
    }
}
