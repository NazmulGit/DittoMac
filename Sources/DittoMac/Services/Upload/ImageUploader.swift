// ImageUploader.swift — uploads a screenshot to the provider the user chose and returns a link.
// Off until the user picks a provider in Preferences › Screenshots; a notice naming the host is shown before any
// upload unless the user ticked "Don't ask again for this host". Pure logic (validation, multipart, parsing, redirects,
// caps) and the URLSession code live in DittoCore (Upload.swift, UploadEngine.swift); see docs/kb/upload-share.md.
import AppKit
import DittoCore

struct UploadedImage: Equatable, Codable, Identifiable {
    var id = UUID()
    var url: URL
    var provider: String
    var date = Date()
    var deleteToken: String?
}

enum UploadError: LocalizedError {
    case notConfigured, cancelled, badResponse, server(Int), network(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Uploading is not set up. Choose a provider in Preferences › Screenshots."
        case .cancelled: return "The upload was cancelled."
        case .badResponse: return "The server's answer did not contain a valid https link."
        case .server(let code): return "The server answered with an error (HTTP \(code))."
        case .network(let message): return message
        }
    }
}

final class UploadTask {
    fileprivate var handle: UploadHandle?
    func cancel() { handle?.cancel() }
}

@MainActor
final class ImageUploader {
    static let shared = ImageUploader()

    private let settings: DittoCore.Settings
    private let engine = UploadEngine()
    private let historyURL: URL

    static let keychainClientID = "upload.imgurClientID"
    static let keychainHeader = "upload.customHeader"

    init(settings: DittoCore.Settings = .shared, historyURL: URL = UploadHistoryFile.defaultURL()) {
        self.settings = settings
        self.historyURL = historyURL
        history = UploadHistoryFile.load(UploadedImage.self, from: historyURL)
    }

    private(set) var history: [UploadedImage] = []
    /// Host the user just confirmed in the notice; consumed by the next `upload` (one upload per confirmation).
    private var confirmedHost: String?

    // MARK: configuration

    private var userAgent: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "DittoMac/\(v)"
    }

    /// The plan for the current Preferences, or the reason there is none. With `secretsAsPlaceholders` the Keychain
    /// secrets are not read (a placeholder stands in when one is stored): for validation / display only, e.g. on
    /// every SwiftUI render; the result must never be used to send a request.
    func currentPlan(secretsAsPlaceholders: Bool = false) -> Result<UploadPlan, UploadFailure> {
        guard let kind = settings.uploadProvider else { return .failure(.notConfigured) }
        var c = UploadConfig(kind: kind)
        c.endpoint = settings.uploadEndpoint
        c.fieldName = settings.uploadFieldName
        c.responseKeyPath = settings.uploadResponseKey
        c.headerName = settings.uploadHeaderName
        if secretsAsPlaceholders {
            c.headerValue = Keychain.has(account: Self.keychainHeader) ? "x" : ""
            c.imgurClientID = Keychain.has(account: Self.keychainClientID) ? "x" : ""
        } else {
            c.headerValue = Keychain.get(account: Self.keychainHeader) ?? ""
            c.imgurClientID = Keychain.get(account: Self.keychainClientID) ?? ""
        }
        c.zeroExpiresHours = settings.uploadZeroExpiresHours
        c.zeroSecret = settings.uploadZeroSecret
        c.userAgent = userAgent
        return UploadPlanner.plan(c)
    }

    var isConfigured: Bool { if case .success = currentPlan(secretsAsPlaceholders: true) { return true } else { return false } }

    var providerDisplayName: String {
        switch currentPlan(secretsAsPlaceholders: true) {
        case .success(let p): return p.displayName
        case .failure:
            if let k = settings.uploadProvider { return "\(k.title) (incomplete)" }
            return "Not configured"
        }
    }

    // MARK: consent

    /// Checks configuration and the one-time per-host consent notice. If not configured, opens Preferences › Screenshots
    /// and completes false. completion(true) means the caller may call `upload`.
    func ensureReady(state: AppState, completion: @escaping (Bool) -> Void) {
        guard case .success(let plan) = currentPlan(secretsAsPlaceholders: true) else {
            state.windows.showPreferences(tab: .screenshots)
            completion(false)
            return
        }
        let host = plan.host
        if settings.hasUploadConsent(host: host) { completion(true); return }
        confirmedHost = nil
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Upload this image to \(host)?"
        alert.informativeText = "Uploading sends this image to \(host). Anyone who has the link can view it. DittoMac is not affiliated with \(host). Continue?"
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again for this host"
        NSApp.activate(ignoringOtherApps: true)
        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok, alert.suppressionButton?.state == .on { settings.uploadConsentHosts += [host] }
        confirmedHost = ok ? host.lowercased() : nil
        completion(ok)
    }

    /// Forget every "Don't ask again" choice.
    func resetConsent() { settings.uploadConsentHosts = [] }

    // MARK: upload

    /// Call `ensureReady` first; the notice is the user's consent, this method does not show it again.
    @discardableResult
    func upload(data: Data, filename: String, mimeType: String, progress: ((Double) -> Void)?,
                completion: @escaping (Result<UploadedImage, Error>) -> Void) -> UploadTask? {
        let plan: UploadPlan
        switch currentPlan() {
        case .failure: completion(.failure(UploadError.notConfigured)); return nil
        case .success(let p): plan = p
        }
        // Consent is enforced here too, not only by callers: the host must be remembered ("Don't ask again") or have
        // been confirmed in the notice for this upload. This also catches a settings change between notice and upload.
        let host = plan.host.lowercased()
        let confirmed = confirmedHost == host
        confirmedHost = nil
        guard settings.hasUploadConsent(host: host) || confirmed else {
            completion(.failure(UploadError.network("Upload cancelled: confirm the upload to \(plan.host) first.")))
            return nil
        }
        let task = UploadTask()
        let nameForHistory = plan.displayName
        task.handle = engine.upload(plan: plan, data: data, filename: filename, mimeType: mimeType, progress: { p in
            DispatchQueue.main.async { progress?(p) }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let out):
                        let entry = UploadedImage(url: out.link, provider: nameForHistory, date: Date(), deleteToken: out.deleteToken)
                        self?.record(entry)
                        completion(.success(entry))
                    case .failure(let f):
                        completion(.failure(Self.map(f)))
                    }
                }
            }
        })
        return task.handle == nil ? nil : task
    }

    static func map(_ f: UploadFailure) -> UploadError {
        switch f {
        case .notConfigured: return .notConfigured
        case .cancelled: return .cancelled
        case .badResponse: return .badResponse
        case .server(let c): return .server(c)
        case .network(let m): return .network(m)
        case .invalidEndpoint: return .network("The upload address must start with https:// and must not contain a user name or password.")
        case .invalidConfiguration(let m): return .network(m)
        case .unsupportedType: return .network("Only PNG, JPG and BMP images can be uploaded.")
        case .tooLarge: return .network("The image is larger than 25 MB. Crop it or save it as JPG first.")
        }
    }

    // MARK: delete / history

    /// Deletes the remote copy. Works for Imgur uploads (anonymous delete hash); other providers have no delete API,
    /// so this completes false and the caller may offer `remove(_:)` (forget locally).
    func delete(_ entry: UploadedImage, completion: @escaping (Bool) -> Void) {
        guard entry.provider == "Imgur", let token = entry.deleteToken, let url = UploadPlanner.imgurDeleteURL(deleteToken: token),
              let id = Keychain.get(account: Self.keychainClientID), !id.isEmpty else { completion(false); return }
        engine.delete(url: url, headers: ["Authorization": "Client-ID \(id)", "User-Agent": userAgent]) { [weak self] ok in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok { self?.remove(entry) }
                    completion(ok)
                }
            }
        }
    }

    /// Forget one entry locally (does not touch the remote copy).
    func remove(_ entry: UploadedImage) {
        history.removeAll { $0.id == entry.id }
        persist()
    }

    func clearHistory() { history = []; persist() }

    private func record(_ entry: UploadedImage) {
        history.insert(entry, at: 0)
        if history.count > UploadLimits.maxHistory { history = Array(history.prefix(UploadLimits.maxHistory)) }
        persist()
    }

    private func persist() { UploadHistoryFile.save(history, to: historyURL) }
}
