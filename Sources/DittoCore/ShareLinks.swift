// ShareLinks.swift — web-intent share URLs for an uploaded image link. Pure; the app opens them via NSWorkspace on click.
import Foundation

public enum ShareNetwork: String, CaseIterable, Sendable {
    case x, facebook, pinterest, vk, reddit, linkedin, whatsapp, telegram, email
    public var title: String {
        switch self {
        case .x: return "X (Twitter)"; case .facebook: return "Facebook"; case .pinterest: return "Pinterest"
        case .vk: return "VK"; case .reddit: return "Reddit"; case .linkedin: return "LinkedIn"
        case .whatsapp: return "WhatsApp"; case .telegram: return "Telegram"; case .email: return "Email"
        }
    }
}

public enum ShareLinks {
    /// Web-intent URL that shares `link` on `network`. `link` must be https. Built with URLComponents (fully encoded).
    public static func url(for network: ShareNetwork, link: URL, title: String? = nil) -> URL? {
        guard let l = checkedLink(link) else { return nil }
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (t?.isEmpty == false) ? t : nil
        switch network {
        case .x:
            return make("https", "x.com", "/intent/post", [("url", l), ("text", text)])
        case .facebook:
            return make("https", "www.facebook.com", "/sharer/sharer.php", [("u", l)])
        case .pinterest:
            return make("https", "www.pinterest.com", "/pin/create/button/", [("url", l), ("media", l), ("description", text)])
        case .vk:
            return make("https", "vk.com", "/share.php", [("url", l), ("title", text)])
        case .reddit:
            return make("https", "www.reddit.com", "/submit", [("url", l), ("title", text)])
        case .linkedin:
            return make("https", "www.linkedin.com", "/sharing/share-offsite/", [("url", l)])
        case .whatsapp:
            return make("https", "wa.me", "/", [("text", [text, l].compactMap { $0 }.joined(separator: " "))])
        case .telegram:
            return make("https", "t.me", "/share/url", [("url", l), ("text", text)])
        case .email:
            // Opened only by the user's click via NSWorkspace (mail client); never fetched by the app.
            return make("mailto", nil, "", [("subject", text ?? "Screenshot"), ("body", [text, l].compactMap { $0 }.joined(separator: "\n"))])
        }
    }

    /// Reverse image search for an uploaded image (Google Lens by URL).
    public static func similarImageSearch(link: URL) -> URL? {
        guard let l = checkedLink(link) else { return nil }
        return make("https", "lens.google.com", "/uploadbyurl", [("url", l)])
    }

    // MARK: helpers

    /// https only, host present, no userinfo, ≤ 2048 characters.
    static func checkedLink(_ link: URL) -> String? {
        let s = link.absoluteString
        guard s.count <= 2048, let c = URLComponents(url: link, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty, c.user == nil, c.password == nil else { return nil }
        return s
    }

    /// RFC 3986 unreserved characters stay; everything else (including `&`, `=`, `#`, `+`, space, unicode) is %-encoded.
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func make(_ scheme: String, _ host: String?, _ path: String, _ items: [(String, String?)]) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        if let host { c.host = host }
        c.path = path
        let q = items.compactMap { k, v in v.map { "\(k)=\(encode($0))" } }.joined(separator: "&")
        if !q.isEmpty { c.percentEncodedQuery = q }
        return c.url
    }
}
