// Settings+Upload.swift — upload preferences. Secrets (Imgur Client-ID, custom header value) are NOT here: they live
// in the Keychain (accounts `upload.imgurClientID`, `upload.customHeader`).
import Foundation

extension Settings {
    public static let uploadKeys: Set<String> = [
        "uploadProvider", "uploadEndpoint", "uploadFieldName", "uploadResponseKey", "uploadHeaderName",
        "uploadZeroExpiresHours", "uploadZeroSecret", "uploadConsentHosts",
    ]

    /// Nil = uploading is off (the default).
    public var uploadProvider: UploadProviderKind? {
        get { defaults.string(forKey: "uploadProvider").flatMap(UploadProviderKind.init(rawValue:)) }
        set { if let v = newValue { defaults.set(v.rawValue, forKey: "uploadProvider") } else { defaults.removeObject(forKey: "uploadProvider") } }
    }
    public var uploadEndpoint: String {
        get { defaults.string(forKey: "uploadEndpoint") ?? "" }
        set { defaults.set(newValue, forKey: "uploadEndpoint") }
    }
    public var uploadFieldName: String {
        get { defaults.string(forKey: "uploadFieldName") ?? "file" }
        set { defaults.set(newValue, forKey: "uploadFieldName") }
    }
    /// Empty = the response body is the plain-text URL. Otherwise a dotted JSON path such as `data.link`.
    public var uploadResponseKey: String {
        get { defaults.string(forKey: "uploadResponseKey") ?? "" }
        set { defaults.set(newValue, forKey: "uploadResponseKey") }
    }
    /// Name of the optional extra header for the custom endpoint (its value is in the Keychain).
    public var uploadHeaderName: String {
        get { defaults.string(forKey: "uploadHeaderName") ?? "Authorization" }
        set { defaults.set(newValue, forKey: "uploadHeaderName") }
    }
    /// 0x0.st: hours until the file expires; 0 = the server's default.
    public var uploadZeroExpiresHours: Int {
        get { defaults.object(forKey: "uploadZeroExpiresHours") == nil ? 0 : min(max(defaults.integer(forKey: "uploadZeroExpiresHours"), 0), 24 * 365) }
        set { defaults.set(min(max(newValue, 0), 24 * 365), forKey: "uploadZeroExpiresHours") }
    }
    /// 0x0.st: ask for a longer, hard-to-guess URL.
    public var uploadZeroSecret: Bool {
        get { defaults.object(forKey: "uploadZeroSecret") == nil ? true : defaults.bool(forKey: "uploadZeroSecret") }
        set { defaults.set(newValue, forKey: "uploadZeroSecret") }
    }
    /// Hosts for which the user ticked "Don't ask again" in the upload notice.
    public var uploadConsentHosts: [String] {
        get { defaults.stringArray(forKey: "uploadConsentHosts") ?? [] }
        set { defaults.set(Array(Set(newValue.map { $0.lowercased() })).sorted(), forKey: "uploadConsentHosts") }
    }
    public func hasUploadConsent(host: String) -> Bool { uploadConsentHosts.contains(host.lowercased()) }
}
