// PreferencesSync.swift — Sync tab: cloud-folder sync and backup (v1.2). See docs/kb/sync.md.
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DittoCore

/// Refreshes the tab when SyncService publishes a status change, and every 20 s so "2 min ago" stays current.
@MainActor
final class SyncLive: ObservableObject {
    @Published private(set) var tick = 0
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .dittoSyncStatusChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick += 1 }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick += 1 }
        }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        timer?.invalidate()
    }
}

/// Text field that writes to Settings on Return, after `delay` seconds without typing, and when it disappears,
/// instead of on every keystroke (each write would otherwise ripple through the settings observers).
@MainActor
final class CommitTextModel: ObservableObject {
    @Published var text: String
    private var work: DispatchWorkItem?
    private var pending = false
    init(_ text: String) { self.text = text }

    func edited(_ new: String, delay: TimeInterval, commit: @escaping (String) -> Void) {
        text = new
        pending = true
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush(commit) } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func flush(_ commit: (String) -> Void) {
        work?.cancel(); work = nil
        guard pending else { return }
        pending = false
        commit(text)
    }
}

struct CommitTextField: View {
    let title: String
    let value: String
    var delay: TimeInterval = 1.0
    let commit: (String) -> Void
    @StateObject private var model: CommitTextModel

    init(title: String, value: String, delay: TimeInterval = 1.0, commit: @escaping (String) -> Void) {
        self.title = title; self.value = value; self.delay = delay; self.commit = commit
        _model = StateObject(wrappedValue: CommitTextModel(value))
    }

    var body: some View {
        TextField(title, text: Binding(get: { model.text }, set: { model.edited($0, delay: delay, commit: commit) }))
            .onSubmit { model.flush(commit) }
            .onDisappear { model.flush(commit) }
    }
}

struct SyncPrefs: View {
    @ObservedObject var m: PrefsModel
    @StateObject private var live = SyncLive()
    @LState private var folders: [CloudFolder] = []
    @LState private var passphrase = ""
    @LState private var confirmPassphrase = ""
    @LState private var passMessage: String?
    @LState private var passIsError = false
    @LState private var actionMessage: String?
    @LState private var actionIsError = false
    @LState private var confirmRemove = false

    private var svc: SyncService? { m.state.sync as? SyncService }
    private var folderPath: String { m.s.syncFolderPath }
    private var ready: Bool { m.s.syncEnabled && !folderPath.isEmpty && (svc?.hasPassphrase ?? false) }

    var body: some View {
        _ = live.tick
        return Form {
            statusSection
            folderSection
            passphraseSection
            contentSection
            backupSection
            actionsSection
            devicesSection
            notesSection
        }
        .formStyle(.grouped)
        .onAppear { folders = CloudFolders.detect() }
    }

    // MARK: sections

    private var statusSection: some View {
        Section("Cloud sync") {
            Toggle("Sync clips between my Macs through a cloud folder", isOn: m.b(\.syncEnabled))
            Text("DittoMac saves an end-to-end encrypted copy of your clips in a folder that your cloud app already syncs, so it works with Google Drive, iCloud Drive, Dropbox, OneDrive, Box and pCloud without signing in to anything inside DittoMac. For Google Drive: install “Google Drive for desktop”, then choose “My Drive” below.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Status") {
                let t = svc?.statusText ?? "Off"
                Text(t).foregroundStyle(t.hasPrefix("Error") ? Color.red : Color.secondary).textSelection(.enabled)
            }
            if let msg = svc?.lastMessage { Text(msg).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var folderSection: some View {
        Section("Cloud folder") {
            Menu {
                ForEach(folders) { f in
                    Button { pick(f.url, provider: f.provider) } label: { Label(f.name, systemImage: f.symbol) }
                }
                if !folders.isEmpty { Divider() }
                Button("Choose folder…") { CloudFolders.chooseFolder { if let u = $0 { pick(u, provider: "Custom folder") } } }
                Button("Rescan for cloud folders") { folders = CloudFolders.detect() }
            } label: {
                Text(folderPath.isEmpty ? "Choose a cloud folder…" : (m.s.syncProviderName.isEmpty ? "Change folder…" : "Change (\(m.s.syncProviderName))…"))
            }
            if !folderPath.isEmpty {
                LabeledContent("Folder") {
                    Text((folderPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Reveal in Finder") { reveal() }
                    Spacer()
                }
                Text("DittoMac keeps its files in a “\(SyncFolder.directoryName)” folder inside this one.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if folders.isEmpty {
                Text("No cloud folders were found on this Mac. Install Google Drive for desktop, Dropbox, OneDrive or similar and sign in, or pick any folder with “Choose folder…”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var passphraseSection: some View {
        Section("Sync passphrase") {
            SecureField("Passphrase (at least 12 characters)", text: $passphrase)
            SecureField("Repeat passphrase", text: $confirmPassphrase)
            HStack {
                Button("Save passphrase") { savePassphrase() }.disabled(passphrase.isEmpty)
                if svc?.hasPassphrase == true {
                    Button("Remove") { confirmRemove = true }
                }
            }
            if !passphrase.isEmpty {
                let s = FriendsPrefs.strength(passphrase)
                Text(s.text).font(.caption).foregroundStyle(s.ok ? Color.secondary : Color.orange)
            }
            Text(svc?.hasPassphrase == true ? "A sync passphrase is stored in your Keychain." : "No sync passphrase is stored yet.")
                .font(.caption).foregroundStyle(.secondary)
            if let msg = passMessage { Text(msg).font(.caption).foregroundStyle(passIsError ? .red : .green) }
            Text("Use the same passphrase on every Mac. Anyone who has this passphrase and access to your cloud folder can read the synced clips, and it can’t be recovered — if you forget it, set a new one on all your Macs.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Remove the sync passphrase?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { svc?.removePassphrase(); passMessage = "Passphrase removed. Sync is paused."; passIsError = false }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Sync stops until you save a passphrase again. Files already in your cloud folder stay encrypted.") }
    }

    private var contentSection: some View {
        Section("What to sync") {
            Toggle("Images (PNG, TIFF, JPEG, GIF, HEIC, PDF)", isOn: m.b(\.syncIncludeImages))
            Toggle("Rich text and web content (RTF, HTML, web archives)", isOn: m.b(\.syncIncludeRich))
            Stepper("Maximum snapshot size: \(m.s.syncMaxTotalMB) MB", value: m.b(\.syncMaxTotalMB), in: 10...150, step: 10)
            Stepper("Check every \(m.s.syncIntervalMinutes) min", value: m.b(\.syncIntervalMinutes), in: 1...60)
            // Committed on Return, after ~1 s of quiet, or when the tab closes (not per keystroke).
            CommitTextField(title: "This Mac’s name", value: m.s.syncDeviceName) { m.s.syncDeviceName = $0; m.changed() }
            Text("Newest clips go first until the size limit is reached. Plain text is always included.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var backupSection: some View {
        Section("Backups") {
            Toggle("Keep rolling encrypted backups", isOn: m.b(\.syncBackups))
            if m.s.syncBackups {
                Stepper("Keep the last \(m.s.syncBackupKeep) backups", value: m.b(\.syncBackupKeep), in: 1...30)
                Text("One encrypted .dmsync file per day is written to the same folder. Older ones of this Mac are removed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            HStack {
                Button("Sync now") { svc?.syncNow() }.disabled(!ready)
                Button("Restore / merge from file…") { restoreFromFile() }
                Spacer()
            }
            if let msg = actionMessage { Text(msg).font(.caption).foregroundStyle(actionIsError ? .red : .green) }
        }
    }

    private var devicesSection: some View {
        Section("Macs in this folder") {
            let devices = svc?.devices ?? []
            if devices.isEmpty {
                Text(ready ? "None yet. Sync once to see them." : "Nothing to show until sync is set up.").foregroundStyle(.secondary)
            }
            ForEach(devices) { d in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: d.isThisDevice ? "laptopcomputer" : "desktopcomputer").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((d.deviceName ?? d.fileName) + (d.isThisDevice ? " (this Mac)" : ""))
                        Text(detail(d)).font(.caption).foregroundStyle(d.status == .wrongPassphrase || d.status == .unreadable ? Color.orange : Color.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var notesSection: some View {
        Section("Good to know") {
            Text("• Locked notes and your Friends passphrase are never synced or backed up.\n• Keyboard shortcuts, hot keys and copy buffers stay on each Mac.\n• Deletions are not synced yet: a clip you delete here stays on your other Macs, and it is not re-added here.\n• Syncing only adds clips. Nothing is overwritten or removed on another Mac.\n• Locking a note does not remove copies that were already synced or backed up before it was locked: those stay readable in your cloud folder until you delete them there.\n• Sticky notes arrive on other Macs as ordinary clips: their colour, desktop position and open/closed state are not synced.\n• Changing the Mac’s name takes effect at the next scheduled upload.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: actions

    private func detail(_ d: SyncDeviceInfo) -> String {
        var parts: [String] = []
        switch d.status {
        case .wrongPassphrase: parts.append("Can’t decrypt: different passphrase or damaged file")
        case .unreadable: parts.append("Unreadable file")
        default: if let n = d.clipCount { parts.append("\(n) clip\(n == 1 ? "" : "s")") }
        }
        parts.append(d.modified.formatted(date: .abbreviated, time: .shortened))
        parts.append(ByteCountFormatter.string(fromByteCount: d.sizeBytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    private func pick(_ url: URL, provider: String) {
        m.s.syncFolderPath = url.path
        m.s.syncProviderName = provider
        m.changed()
    }

    private func reveal() {
        let base = URL(fileURLWithPath: folderPath)
        let sub = base.appendingPathComponent(SyncFolder.directoryName)
        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: sub.path) ? sub : base])
    }

    private func savePassphrase() {
        guard passphrase == confirmPassphrase else { passMessage = "The two passphrases don’t match."; passIsError = true; return }
        guard passphrase.count >= SyncLimits.minPassphraseLength else {
            passMessage = "Use at least \(SyncLimits.minPassphraseLength) characters."; passIsError = true; return
        }
        guard let svc else { passMessage = "Sync isn’t available."; passIsError = true; return }
        do {
            try svc.setPassphrase(passphrase)
            passphrase = ""; confirmPassphrase = ""
            passMessage = "Saved to your Keychain."; passIsError = false
        } catch {
            passMessage = "Couldn’t save the passphrase (\((error as? SyncError)?.localizedDescription ?? "Keychain error"))."; passIsError = true
        }
    }

    private func restoreFromFile() {
        let p = NSOpenPanel()
        p.title = "Restore / merge from a sync or backup file"
        p.message = "Clips in the file are added to your history. Nothing is removed."
        p.prompt = "Merge"
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        if let t = UTType(filenameExtension: SyncFolder.fileExtension) { p.allowedContentTypes = [t] }
        guard p.runModal() == .OK, let url = p.url else { return }
        runRestore(url, passphrase: nil)
    }

    private func runRestore(_ url: URL, passphrase: String?) {
        guard let svc else { return }
        actionMessage = "Merging…"; actionIsError = false
        svc.restore(from: url, passphrase: passphrase) { result in
            switch result {
            case .success(let s):
                actionMessage = "Merged \(s.imported) new clip\(s.imported == 1 ? "" : "s"); \(s.alreadyPresent) already here."
                actionIsError = false
            case .failure(let e):
                if let se = e as? SyncError, se == .wrongPassphraseOrCorrupt || se == .passphraseTooShort {
                    if let pw = Self.askPassphrase(retry: passphrase != nil) { runRestore(url, passphrase: pw); return }
                    actionMessage = "Cancelled."
                } else {
                    actionMessage = (e as? SyncError)?.localizedDescription ?? "Couldn’t read that file."
                }
                actionIsError = true
            }
        }
    }

    /// Asks for the passphrase of a file made with a different sync passphrase. Not stored.
    private static func askPassphrase(retry: Bool) -> String? {
        let a = NSAlert()
        a.messageText = retry ? "That passphrase didn’t work" : "Passphrase for this file"
        a.informativeText = "This file can’t be opened with your saved sync passphrase. Enter the passphrase it was made with. It is used once and not saved."
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Merge")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        return a.runModal() == .alertFirstButtonReturn && !f.stringValue.isEmpty ? f.stringValue : nil
    }
}
