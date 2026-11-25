// SyncService.swift — app-layer driver for folder-based encrypted sync and backup (v1.2). Logic lives in
// DittoCore/SyncEngine.swift; this class owns settings, the Keychain passphrase, timers and status.
//
// Everything heavy (hashing, compression, PBKDF2, file IO, import) runs on a private serial queue; results are
// delivered on the main actor. The passphrase and derived keys are never logged and never put in status text.

import AppKit
import DittoCore

extension Notification.Name {
    /// Posted (main thread) when SyncService's status, device list or last-sync time changed.
    static let dittoSyncStatusChanged = Notification.Name("io.github.dittomac.syncStatusChanged")
}

@MainActor
final class SyncService: SyncServicing {
    static let passphraseAccount = "sync.passphrase"

    unowned let state: AppState
    private let engine: SyncEngine
    private let queue = DispatchQueue(label: "io.github.dittomac.sync", qos: .utility)

    private(set) var lastSync: Date?
    private(set) var devices: [SyncDeviceInfo] = []
    /// Human-readable result of the last run ("Imported 3 clips"), shown under the status.
    private(set) var lastMessage: String?
    private var lastError: String?
    private var busy = false

    private enum Kind { case full, pullOnly }
    private var queued: (kind: Kind, force: Bool)?
    private var lastConfig: SyncConfigSnapshot?
    private var pushTimer: Timer?
    private var pollTimer: Timer?
    private var debounce: DispatchWorkItem?
    private var observer: NSObjectProtocol?

    init(state: AppState) {
        self.state = state
        let dir: URL? = state.store.path == ":memory:" || state.store.path.isEmpty
            ? nil : URL(fileURLWithPath: state.store.path).deletingLastPathComponent()
        engine = SyncEngine(store: state.store, stateDirectory: dir, deviceID: state.settings.syncDeviceID)
        observer = NotificationCenter.default.addObserver(forName: .dittoClipsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.localClipsChanged() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    // MARK: passphrase (Keychain)

    /// Cached presence flag (no secret read, no Keychain query per render); refreshed by set / remove.
    var hasPassphrase: Bool { Keychain.has(account: Self.passphraseAccount) }

    func setPassphrase(_ p: String) throws {
        guard p.count >= SyncLimits.minPassphraseLength else { throw SyncError.passphraseTooShort }
        try Keychain.set(p, account: Self.passphraseAccount)
        engine.resetSeen()
        applySettings()
        syncNow()
    }

    func removePassphrase() {
        Keychain.delete(account: Self.passphraseAccount)
        engine.resetSeen()
        applySettings()
        publish()
    }

    // MARK: status

    private var settings: DittoCore.Settings { state.settings }
    private var folderReady: Bool { !settings.syncFolderPath.isEmpty }

    var isReady: Bool { settings.syncEnabled && folderReady && hasPassphrase }

    var statusText: String {
        guard settings.syncEnabled else { return "Off" }
        guard folderReady else { return "Needs folder" }
        guard hasPassphrase else { return "Needs passphrase" }
        if busy { return "Syncing…" }
        if let e = lastError { return "Error: \(e)" }
        guard let last = lastSync else { return "Waiting for first sync" }
        let n = max(1, devices.count)
        let ago = Date().timeIntervalSince(last) < 45 ? "just now" : Self.relative.localizedString(for: last, relativeTo: Date())
        return "Synced \(ago) · \(n) Mac\(n == 1 ? "" : "s")"
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func publish() { NotificationCenter.default.post(name: .dittoSyncStatusChanged, object: nil) }

    // MARK: SyncServicing

    func applySettings() {
        let s = settings
        let snapshot = SyncConfigSnapshot(
            enabled: s.syncEnabled, includeImages: s.syncIncludeImages, includeRich: s.syncIncludeRich,
            backups: s.syncBackups, hasPassphrase: hasPassphrase, folderPath: s.syncFolderPath,
            intervalMinutes: s.syncIntervalMinutes, deviceName: s.syncDeviceName,
            maxTotalMB: s.syncMaxTotalMB, backupKeep: s.syncBackupKeep)
        let change = snapshot.change(from: lastConfig)
        lastConfig = snapshot
        switch change {
        case .none:
            return          // device name, size limit, backup count: read by the next scheduled run
        case .reschedule:
            if pushTimer != nil { schedulePushTimer(minutes: s.syncIntervalMinutes) }
            return
        case .restart:
            break
        }
        pushTimer?.invalidate(); pollTimer?.invalidate()
        pushTimer = nil; pollTimer = nil
        debounce?.cancel()
        engine.resetSeen()
        guard s.syncEnabled, folderReady, hasPassphrase else { publish(); return }
        lastError = nil
        schedulePushTimer(minutes: s.syncIntervalMinutes)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollRemote() }
        }
        start(.full, force: true)
    }

    private func schedulePushTimer(minutes: Int) {
        pushTimer?.invalidate()
        pushTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.start(.full, force: false) }
        }
    }

    func syncNow() { start(.full, force: true) }

    // MARK: scheduling

    /// Local clips changed (including our own imports): push after 60 s of quiet.
    private func localClipsChanged() {
        guard settings.syncEnabled, folderReady else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.start(.full, force: false) }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    /// Every 30 s: a cheap stat of the remote files; pull only when one changed.
    private func pollRemote() {
        guard !busy, settings.syncEnabled, folderReady else { return }
        let path = settings.syncFolderPath
        queue.async { [engine, weak self] in
            guard let folder = try? SyncFolder.open(baseFolder: URL(fileURLWithPath: path), create: false),
                  engine.hasRemoteChanges(in: folder) else { return }
            Task { @MainActor in self?.start(.pullOnly, force: false) }
        }
    }

    private func start(_ kind: Kind, force: Bool) {
        let s = settings
        guard s.syncEnabled, folderReady, hasPassphrase,
              let pass = Keychain.get(account: Self.passphraseAccount) else { publish(); return }
        if busy {
            let k: Kind = (queued?.kind == .full || kind == .full) ? .full : .pullOnly
            queued = (k, force || (queued?.force ?? false))
            return
        }
        busy = true
        lastError = nil
        publish()

        var req = SyncRunRequest()
        req.pull = force ? .all : .changedOnly
        req.push = kind == .full
        req.backupKeep = (kind == .full && s.syncBackups) ? s.syncBackupKeep : nil
        req.deviceName = s.syncDeviceName
        req.options = s.syncOptions
        req.maxNewClips = s.checkForMaxEntries ? s.maxEntries : nil
        let path = s.syncFolderPath
        queue.async { [engine, weak self] in
            var report = SyncReport()
            do {
                let folder = try SyncFolder.open(baseFolder: URL(fileURLWithPath: path))
                report = engine.run(folder: folder, passphrase: pass, request: req)
            } catch {
                report.hardError = (error as? SyncError)?.localizedDescription ?? "The sync folder is not available."
            }
            let result = report
            Task { @MainActor in self?.finish(result) }
        }
    }

    private func finish(_ r: SyncReport) {
        busy = false
        if !r.devices.isEmpty { devices = r.devices }
        if let e = r.hardError {
            lastError = e
        } else {
            lastError = nil
            lastSync = Date()
        }
        var parts: [String] = []
        if r.merge.imported > 0 { parts.append("Imported \(r.merge.imported) clip\(r.merge.imported == 1 ? "" : "s")") }
        if r.merge.limited > 0 { parts.append("\(r.merge.limited) older clip\(r.merge.limited == 1 ? "" : "s") not imported (history limit)") }
        if r.pushed { parts.append("uploaded this Mac’s snapshot") }
        if let b = r.backupFile { parts.append("backup \(b) written") }
        if let w = r.warnings.first { parts.append(w) }
        lastMessage = parts.isEmpty ? nil : parts.joined(separator: " · ")
        if r.merge.imported > 0 || r.merge.groupsCreated > 0 { NotificationCenter.default.post(name: .dittoClipsChanged, object: nil) }
        publish()
        if let q = queued {
            queued = nil
            start(q.kind, force: q.force)
        }
    }

    // MARK: restore / merge from a file

    /// Merges a `.dmsync` file additively (tombstones ignored). `passphrase` nil = the saved sync passphrase.
    func restore(from url: URL, passphrase: String?, completion: @escaping (Result<MergeSummary, Error>) -> Void) {
        guard let pass = passphrase ?? Keychain.get(account: Self.passphraseAccount) else {
            completion(.failure(SyncError.passphraseTooShort)); return
        }
        queue.async { [engine, weak self] in
            let result = Result { try engine.restore(from: url, passphrase: pass) }
            Task { @MainActor in
                if case .success(let m) = result, m.imported > 0 || m.groupsCreated > 0 {
                    NotificationCenter.default.post(name: .dittoClipsChanged, object: nil)
                }
                self?.publish()
                completion(result)
            }
        }
    }
}
