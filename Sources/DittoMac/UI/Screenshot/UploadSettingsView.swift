// UploadSettingsView.swift — Preferences section: upload provider, endpoint, keys, consent, upload history.
// Secrets (Imgur Client-ID, custom header value) are stored in the Keychain, never in UserDefaults.
import SwiftUI
import AppKit
import DittoCore

/// Preferences section: upload provider, endpoint, keys, consent, upload history.
struct UploadSettingsView: View {
    @ObservedObject var m: PrefsModel

    @LState private var clientID = ""
    @LState private var headerValue = ""
    @LState private var hasClientID = false
    @LState private var hasHeader = false
    @LState private var message: String?
    @LState private var testing = false
    @LState private var testTask: UploadTask?
    @LState private var testLink: URL?
    @LState private var history: [UploadedImage] = []

    private var kind: UploadProviderKind? { m.s.uploadProvider }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Upload & share link").font(.headline)
            Text("Off by default. When you upload, the image is sent to the provider you choose below and you get a link anyone can open. DittoMac never uses prnt.sc or any Lightshot server.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            Picker("Provider", selection: m.b(\.uploadProvider)) {
                Text("Off (no uploading)").tag(UploadProviderKind?.none)
                ForEach(UploadProviderKind.allCases, id: \.self) { Text($0.title).tag(UploadProviderKind?.some($0)) }
            }

            switch kind {
            case .none: EmptyView()
            case .some(.custom): customFields
            case .some(.imgur): imgurFields
            case .some(.zeroX0): zeroFields
            }

            if kind != nil, case .failure(let f) = ImageUploader.shared.currentPlan(secretsAsPlaceholders: true), f != .notConfigured {
                Label(Self.describe(f), systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange)
            }

            privacyBox

            if kind != nil {
                HStack {
                    Button(testing ? "Uploading…" : "Test upload (1×1 pixel image)") { runTest() }.disabled(testing)
                    if testing { Button("Cancel") { testTask?.cancel() } }
                    Button("Reset notices") { ImageUploader.shared.resetConsent(); message = "You will be asked before the next upload." }
                }
                if let link = testLink {
                    HStack {
                        Text(link.absoluteString).font(.caption).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("Copy link") { copy(link) }
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }

            Divider()
            historySection
        }
        .onAppear { reload() }
    }

    // MARK: provider fields

    private var customFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Endpoint (https://…)", text: m.b(\.uploadEndpoint)).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Form field name", text: m.b(\.uploadFieldName)).textFieldStyle(.roundedBorder)
                TextField("Response JSON key, e.g. data.link (empty = plain-text URL)", text: m.b(\.uploadResponseKey)).textFieldStyle(.roundedBorder)
            }
            HStack {
                TextField("Extra header name", text: m.b(\.uploadHeaderName)).textFieldStyle(.roundedBorder).frame(width: 170)
                SecureField(hasHeader ? "Saved in Keychain (type to replace)" : "Header value, e.g. Bearer …", text: $headerValue)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { saveSecret(headerValue, account: ImageUploader.keychainHeader) { headerValue = ""; hasHeader = true } }
                    .disabled(headerValue.isEmpty)
                if hasHeader { Button("Remove") { Keychain.delete(account: ImageUploader.keychainHeader); hasHeader = false } }
            }
            Text("The endpoint must use https (plain http is accepted only for localhost, for testing). The image is sent as multipart/form-data. The header value is kept in your Keychain.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var imgurFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(hasClientID ? "Client-ID saved in Keychain (type to replace)" : "Your own Imgur Client-ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { saveSecret(clientID, account: ImageUploader.keychainClientID) { clientID = ""; hasClientID = true } }
                    .disabled(clientID.isEmpty)
                if hasClientID { Button("Remove") { Keychain.delete(account: ImageUploader.keychainClientID); hasClientID = false } }
            }
            HStack(spacing: 4) {
                Text("Register a free application at").font(.caption).foregroundColor(.secondary)
                Button("api.imgur.com") { NSWorkspace.shared.open(URL(string: "https://api.imgur.com/oauth2/addclient")!) }
                    .buttonStyle(.link).font(.caption)
                Text("(choose “anonymous usage”) and paste its Client-ID. DittoMac ships no key of its own.").font(.caption).foregroundColor(.secondary)
            }
            Text("Imgur uploads can be deleted later from the history below.").font(.caption).foregroundColor(.secondary)
        }
    }

    private var zeroFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Hard-to-guess link (secret)", isOn: m.b(\.uploadZeroSecret))
            Stepper(value: m.b(\.uploadZeroExpiresHours), in: 0...(24 * 365), step: 24) {
                Text(m.s.uploadZeroExpiresHours == 0 ? "Expires: server default" : "Expires after \(m.s.uploadZeroExpiresHours) hours")
            }
            Text("0x0.st is a free, community-run file host. Files expire (older and larger files sooner) and uploads cannot be deleted by DittoMac.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Label("Privacy", systemImage: "hand.raised").font(.subheadline.bold())
                Text("• The provider receives the image, your IP address and DittoMac's name and version.\n• Anyone who has the link can view the image; “secret” links are only hard to guess, not protected.\n• Before an upload DittoMac tells you the host and asks you to confirm. You can tick “Don't ask again for this host”.\n• Nothing is uploaded unless you press Upload in a screenshot. Cookies are never sent or stored.\n• DittoMac is not affiliated with Imgur, 0x0.st or any other provider.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: history

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Upload history").font(.headline)
                Spacer()
                Text("\(history.count) of \(UploadLimits.maxHistory)").font(.caption).foregroundColor(.secondary)
                Button("Clear") {
                    if m.confirm("Clear upload history?", "This removes the list on this Mac only. Uploaded images stay online.", button: "Clear") {
                        ImageUploader.shared.clearHistory(); reload()
                    }
                }.disabled(history.isEmpty)
            }
            if history.isEmpty {
                Text("No uploads yet.").font(.caption).foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(history) { e in row(e) }
                    }
                }.frame(maxHeight: 170)
            }
        }
    }

    private func row(_ e: UploadedImage) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(e.url.absoluteString).font(.caption).lineLimit(1).truncationMode(.middle)
                Text("\(e.provider) · \(e.date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            Button("Copy link") { copy(e.url) }
            Button("Open") { open(e.url) }
            if e.deleteToken != nil, e.provider == "Imgur" {
                Button("Delete") {
                    ImageUploader.shared.delete(e) { ok in
                        message = ok ? "Deleted from Imgur." : "Imgur did not delete it (check the Client-ID)."
                        reload()
                    }
                }
            } else {
                Button("Remove") { ImageUploader.shared.remove(e); reload() }.help("Forget this entry (the uploaded image stays online)")
            }
        }.controlSize(.small)
    }

    // MARK: actions

    private func reload() {
        history = ImageUploader.shared.history
        // Cached presence flags: no secret is read and the Keychain isn't queried again on every refresh.
        hasClientID = Keychain.has(account: ImageUploader.keychainClientID)
        hasHeader = Keychain.has(account: ImageUploader.keychainHeader)
    }

    private func saveSecret(_ value: String, account: String, done: () -> Void) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { message = "Nothing to save."; return }
        do { try Keychain.set(trimmed, account: account); done(); message = "Saved in your Keychain."; m.changed() }
        catch { message = "Could not save to the Keychain: \(error.localizedDescription)" }
    }

    private func copy(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
        message = "Link copied."
    }

    private func open(_ url: URL) {
        // History lives in a user-writable file: only ever open a valid https link.
        if let safe = UploadURLRules.validateLink(url.absoluteString) { NSWorkspace.shared.open(safe) }
    }

    private func runTest() {
        message = nil; testLink = nil
        ImageUploader.shared.ensureReady(state: m.state) { ok in
            guard ok else { return }
            guard let png = Self.tinyPNG() else { message = "Could not create the test image."; return }
            testing = true
            testTask = ImageUploader.shared.upload(data: png, filename: "dittomac-test.png", mimeType: "image/png", progress: nil) { result in
                testing = false; testTask = nil
                switch result {
                case .success(let e): testLink = e.url; message = "Upload works. The test image is a single pixel."
                case .failure(let err): message = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
                }
                reload()
            }
            if testTask == nil { testing = false }
        }
    }

    static func tinyPNG() -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.setColor(NSColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1), atX: 0, y: 0)
        return rep.representation(using: .png, properties: [:])
    }

    static func describe(_ f: UploadFailure) -> String {
        switch f {
        case .notConfigured: return "Not configured."
        case .invalidEndpoint: return "The endpoint must start with https:// and must not contain a user name or password."
        case .invalidConfiguration(let s): return s
        default: return "Check the settings."
        }
    }
}
