// Upload.swift — pure, testable logic for "upload a screenshot and get a link" (no AppKit, no Keychain).
// The app target wraps this with consent UI, Keychain access and history (Services/Upload/ImageUploader.swift).
// See docs/kb/upload-share.md.
import Foundation

public enum UploadProviderKind: String, Codable, CaseIterable, Sendable {
    case custom, imgur, zeroX0
    public var title: String {
        switch self {
        case .custom: return "Custom HTTPS endpoint"
        case .imgur: return "Imgur (your own Client-ID)"
        case .zeroX0: return "0x0.st"
        }
    }
}

public enum UploadFailure: Error, Equatable, Sendable {
    case notConfigured
    case invalidEndpoint
    case invalidConfiguration(String)
    case unsupportedType
    case tooLarge
    case cancelled
    case badResponse
    case server(Int)
    case network(String)
}

public enum UploadLimits {
    /// Largest request body we will build or send.
    public static let maxRequestBytes = 25 * 1024 * 1024
    /// Largest response body we keep; the task is cancelled when a server sends more.
    public static let maxResponseBytes = 64 * 1024
    public static let timeout: TimeInterval = 30
    public static let maxURLLength = 2048
    public static let maxHistory = 200
    public static let maxKeyPathDepth = 16
}

// MARK: - URL validation

public enum UploadURLRules {
    public static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h == "127.0.0.1" || h == "::1"
    }

    /// Endpoint the user typed: https only (http only for loopback, so tests and local servers work), host present,
    /// no user:password@, ≤ 2048 characters, no control characters or whitespace.
    public static func validateEndpoint(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= UploadLimits.maxURLLength, !hasControlOrSpace(t),
              let c = URLComponents(string: t), let scheme = c.scheme?.lowercased(),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil, c.fragment == nil,
              let url = c.url else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", isLoopbackHost(host) { return url }
        return nil
    }

    /// A link the server returned: https only, host present, no userinfo, ≤ 2048 characters, parses as URLComponents.
    public static func validateLink(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= UploadLimits.maxURLLength, !hasControlOrSpace(t),
              let c = URLComponents(string: t), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              let url = c.url else { return nil }
        return url
    }

    private static func hasControlOrSpace(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x21 || $0.value == 0x7F }
    }
}

/// What to do when the server answers with a redirect.
public enum RedirectPolicy {
    public enum Decision: Equatable, Sendable { case follow, followStrippingCredentials, refuse }

    /// Never follow to a non-https URL or one with userinfo. A different host is followed only without the
    /// Authorization/custom header (those belong to the original host).
    public static func decide(from: URL?, to: URL?) -> Decision {
        guard let to, let c = URLComponents(url: to, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, to.absoluteString.count <= UploadLimits.maxURLLength else { return .refuse }
        if let fromHost = from?.host?.lowercased(), fromHost == host.lowercased() { return .follow }
        return .followStrippingCredentials
    }

    /// Same as `decide(from:to:)`, but a redirect to a different host that would re-send the request body (any method
    /// other than GET/HEAD, i.e. a 307/308 answer to the upload POST) is refused: the user agreed to send the image to
    /// the configured host only.
    public static func decide(from: URL?, to: URL?, method: String?) -> Decision {
        let d = decide(from: from, to: to)
        guard d == .followStrippingCredentials else { return d }
        let m = (method ?? "GET").uppercased()
        return (m == "GET" || m == "HEAD") ? d : .refuse
    }
}

// MARK: - Multipart

public enum MultipartForm {
    public static let allowedMimeTypes: Set<String> = ["image/png", "image/jpeg", "image/bmp"]

    public static func fileExtension(forMime mime: String) -> String? {
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/bmp": return "bmp"
        default: return nil
        }
    }

    public static func randomBoundary() -> String {
        var g = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &g) }
        return "DittoMac-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Last path component only, `[A-Za-z0-9._-]` only, no leading dot, ≤ 64 characters, extension forced to the MIME type.
    public static func sanitizeFilename(_ name: String, mimeType: String) -> String {
        let ext = fileExtension(forMime: mimeType) ?? "png"
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var stem = last
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex { stem = String(stem[..<dot]) }
        let mapped = String(stem.unicodeScalars.map { s -> Character in
            let ok = (s.value >= 0x30 && s.value <= 0x39) || (s.value >= 0x41 && s.value <= 0x5A)
                || (s.value >= 0x61 && s.value <= 0x7A) || s == "-" || s == "_" || s == "."
            return ok ? Character(s) : "_"
        })
        var cleaned = String(mapped.drop(while: { $0 == "." }))
        cleaned = String(cleaned.prefix(48))
        if cleaned.isEmpty || cleaned.allSatisfy({ $0 == "_" || $0 == "." }) { cleaned = "screenshot" }
        return cleaned + "." + ext
    }

    /// Builds a `multipart/form-data` body: plain `fields` first, then the file part. Field names and values are
    /// restricted so a user-configured name can never inject headers (see `isSafeToken`).
    public static func build(boundary: String, fields: [(String, String)], fileField: String, filename: String,
                             mimeType: String, data: Data) -> Data? {
        guard allowedMimeTypes.contains(mimeType.lowercased()), isSafeToken(fileField),
              boundary.range(of: "^[A-Za-z0-9-]{8,70}$", options: .regularExpression) != nil else { return nil }
        for (k, v) in fields where !isSafeToken(k) || v.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return nil }
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        for (k, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(sanitizeFilename(filename, mimeType: mimeType))\"\r\n")
        add("Content-Type: \(mimeType.lowercased())\r\n\r\n")
        body.append(data)
        add("\r\n--\(boundary)--\r\n")
        return body
    }

    /// `[A-Za-z0-9_.-]{1,64}` — safe inside a quoted header parameter.
    public static func isSafeToken(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 64 && s.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A)
                || ($0.value >= 0x61 && $0.value <= 0x7A) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }
}

// MARK: - Response parsing

public enum UploadResponse {
    /// Follows a dotted key path through JSON objects; numeric components index arrays (`data.0.link`).
    /// Returns the string at the path, or nil for a missing key, wrong type, too-deep path or invalid JSON.
    public static func string(inJSON body: Data, keyPath: String) -> String? {
        let parts = keyPath.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= UploadLimits.maxKeyPathDepth, !parts.contains(""),
              body.count <= UploadLimits.maxResponseBytes,
              let root = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { return nil }
        var cur: Any = root
        for p in parts {
            if let d = cur as? [String: Any], let v = d[p] { cur = v }
            else if let a = cur as? [Any], let i = Int(p), i >= 0, i < a.count { cur = a[i] }
            else { return nil }
        }
        return cur as? String
    }

    /// First non-empty line of a plain-text body.
    public static func firstLine(of body: Data) -> String? {
        guard body.count <= UploadLimits.maxResponseBytes, let s = String(data: body, encoding: .utf8) else { return nil }
        return s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}

/// Collects a response and refuses to grow past the cap.
public struct CappedBuffer: Sendable {
    public private(set) var data = Data()
    public private(set) var exceeded = false
    public let limit: Int
    public init(limit: Int = UploadLimits.maxResponseBytes) { self.limit = limit }
    /// Returns false (and keeps nothing more) once the cap is passed; the caller cancels the task.
    @discardableResult public mutating func append(_ chunk: Data) -> Bool {
        if exceeded { return false }
        if data.count + chunk.count > limit { exceeded = true; return false }
        data.append(chunk)
        return true
    }
}

// MARK: - Provider configuration → request plan

/// Everything needed to build a request. Secrets (`headerValue`, `imgurClientID`) are passed in by the caller
/// (read from the Keychain) and never stored by this layer.
public struct UploadConfig: Equatable, Sendable {
    public var kind: UploadProviderKind
    public var endpoint = ""
    public var fieldName = "file"
    public var responseKeyPath = ""
    public var headerName = ""
    public var headerValue = ""
    public var imgurClientID = ""
    public var zeroExpiresHours = 0
    public var zeroSecret = false
    public var userAgent = "DittoMac/1.0"
    public init(kind: UploadProviderKind) { self.kind = kind }
}

public struct UploadPlan: Equatable, Sendable {
    public enum Format: Equatable, Sendable { case plainText, json(linkPath: String, deletePath: String?) }
    public var url: URL
    public var headers: [String: String]
    public var secretHeaderNames: [String]
    public var fieldName: String
    public var extraFields: [(String, String)]
    public var format: Format
    public var kind: UploadProviderKind
    public var host: String { url.host ?? "" }
    public var displayName: String {
        switch kind {
        case .imgur: return "Imgur"
        case .zeroX0: return "0x0.st"
        case .custom: return host.isEmpty ? "Custom" : "Custom (\(host))"
        }
    }
    public static func == (a: UploadPlan, b: UploadPlan) -> Bool {
        a.url == b.url && a.headers == b.headers && a.fieldName == b.fieldName && a.format == b.format
            && a.kind == b.kind && a.extraFields.map { "\($0.0)=\($0.1)" } == b.extraFields.map { "\($0.0)=\($0.1)" }
    }
}

public struct UploadOutcome: Equatable, Sendable {
    public var link: URL
    public var deleteToken: String?
}

public enum UploadPlanner {
    public static let imgurUploadURL = URL(string: "https://api.imgur.com/3/image")!
    public static let zeroX0URL = URL(string: "https://0x0.st")!
    static let forbiddenHeaders: Set<String> = ["host", "content-length", "content-type", "transfer-encoding", "connection",
                                                "cookie", "set-cookie", "user-agent", "expect", "upgrade", "te", "trailer"]

    public static func plan(_ c: UploadConfig) -> Result<UploadPlan, UploadFailure> {
        let ua = sanitizedUserAgent(c.userAgent)
        switch c.kind {
        case .imgur:
            let id = c.imgurClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return .failure(.notConfigured) }
            guard id.count <= 64, id.unicodeScalars.allSatisfy({ ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) }) else {
                return .failure(.invalidConfiguration("The Imgur Client-ID should be letters and digits only."))
            }
            return .success(UploadPlan(url: imgurUploadURL, headers: ["Authorization": "Client-ID \(id)", "User-Agent": ua],
                                       secretHeaderNames: ["Authorization"], fieldName: "image", extraFields: [],
                                       format: .json(linkPath: "data.link", deletePath: "data.deletehash"), kind: .imgur))
        case .zeroX0:
            var extra: [(String, String)] = []
            if c.zeroExpiresHours > 0 { extra.append(("expires", String(min(c.zeroExpiresHours, 24 * 365)))) }
            if c.zeroSecret { extra.append(("secret", "")) }
            return .success(UploadPlan(url: zeroX0URL, headers: ["User-Agent": ua], secretHeaderNames: [], fieldName: "file",
                                       extraFields: extra, format: .plainText, kind: .zeroX0))
        case .custom:
            let trimmed = c.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.notConfigured) }
            guard let url = UploadURLRules.validateEndpoint(trimmed) else { return .failure(.invalidEndpoint) }
            let field = c.fieldName.trimmingCharacters(in: .whitespaces).isEmpty ? "file" : c.fieldName.trimmingCharacters(in: .whitespaces)
            guard MultipartForm.isSafeToken(field) else {
                return .failure(.invalidConfiguration("The form field name may use letters, digits, “.”, “-” and “_” only."))
            }
            var headers = ["User-Agent": ua]
            var secret: [String] = []
            let hn = c.headerName.trimmingCharacters(in: .whitespaces)
            if !hn.isEmpty || !c.headerValue.isEmpty {
                guard isHeaderToken(hn), !forbiddenHeaders.contains(hn.lowercased()) else {
                    return .failure(.invalidConfiguration("That header name is not allowed."))
                }
                guard !c.headerValue.isEmpty, c.headerValue.utf8.count <= 4096,
                      !c.headerValue.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F }) else {
                    return .failure(.invalidConfiguration("The header value is empty or contains control characters."))
                }
                headers[hn] = c.headerValue
                secret.append(hn)
            }
            let key = c.responseKeyPath.trimmingCharacters(in: .whitespaces)
            let fmt: UploadPlan.Format = key.isEmpty ? .plainText : .json(linkPath: key, deletePath: nil)
            return .success(UploadPlan(url: url, headers: headers, secretHeaderNames: secret, fieldName: field,
                                       extraFields: [], format: fmt, kind: .custom))
        }
    }

    /// Link (and delete token) from a response body, or nil when the body does not contain a valid https link.
    public static func parse(body: Data, format: UploadPlan.Format) -> UploadOutcome? {
        switch format {
        case .plainText:
            guard let line = UploadResponse.firstLine(of: body), let url = UploadURLRules.validateLink(line) else { return nil }
            return UploadOutcome(link: url, deleteToken: nil)
        case .json(let linkPath, let deletePath):
            guard let s = UploadResponse.string(inJSON: body, keyPath: linkPath), let url = UploadURLRules.validateLink(s) else { return nil }
            var token: String?
            if let deletePath, let t = UploadResponse.string(inJSON: body, keyPath: deletePath), isSafeDeleteToken(t) { token = t }
            return UploadOutcome(link: url, deleteToken: token)
        }
    }

    public static func isSafeDeleteToken(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 64 && s.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A)
        }
    }

    /// Imgur anonymous delete: `DELETE https://api.imgur.com/3/image/<deletehash>`.
    public static func imgurDeleteURL(deleteToken: String) -> URL? {
        isSafeDeleteToken(deleteToken) ? URL(string: "https://api.imgur.com/3/image/\(deleteToken)") : nil
    }

    static func isHeaderToken(_ s: String) -> Bool {
        let extra = Set("!#$%&'*+-.^_`|~".unicodeScalars)
        return !s.isEmpty && s.utf8.count <= 64 && s.unicodeScalars.allSatisfy {
            ($0.value >= 0x30 && $0.value <= 0x39) || ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x61 && $0.value <= 0x7A) || extra.contains($0)
        }
    }

    static func sanitizedUserAgent(_ s: String) -> String {
        let t = String(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }.map(Character.init).prefix(100))
        return t.isEmpty ? "DittoMac" : t
    }
}

// MARK: - History file

/// Last-N upload history stored as JSON (newest first), file mode 0600, directory 0700.
public enum UploadHistoryFile {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, limit: Int = UploadLimits.maxHistory) -> [T] {
        // Check the size before reading (the file is user-writable).
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size < 8 * 1024 * 1024,
              let data = try? Data(contentsOf: url), data.count < 8 * 1024 * 1024 else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return Array(((try? dec.decode([T].self, from: data)) ?? []).prefix(limit))
    }

    @discardableResult
    public static func save<T: Encodable>(_ items: [T], to url: URL, limit: Int = UploadLimits.maxHistory) -> Bool {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(Array(items.prefix(limit))) else { return false }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { return false }
        let tmp = dir.appendingPathComponent(".uploads-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        if rename(tmp.path, url.path) != 0 { try? fm.removeItem(at: tmp); return false }
        return true
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("DittoMac/uploads.json")
    }
}
