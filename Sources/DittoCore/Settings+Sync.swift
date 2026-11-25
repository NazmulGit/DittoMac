// Settings+Sync.swift — cloud-folder sync / backup settings (v1.2). Added via extension so Settings.swift stays untouched.
// The sync passphrase is NOT stored here (Keychain, account "sync.passphrase").

import Foundation

extension Settings {
    public static let syncKeys: Set<String> = [
        "syncEnabled", "syncFolderPath", "syncProviderName", "syncIntervalMinutes", "syncIncludeImages",
        "syncIncludeRich", "syncMaxTotalMB", "syncBackups", "syncBackupKeep", "syncDeviceName", "syncDeviceID",
    ]

    private func syncBool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k) }
    private func syncInt(_ k: String, _ d: Int, _ r: ClosedRange<Int>) -> Int {
        let v = defaults.object(forKey: k) == nil ? d : defaults.integer(forKey: k)
        return min(max(v, r.lowerBound), r.upperBound)
    }
    private func syncSetInt(_ k: String, _ v: Int, _ r: ClosedRange<Int>) {
        defaults.set(min(max(v, r.lowerBound), r.upperBound), forKey: k)
    }

    public var syncEnabled: Bool {
        get { syncBool("syncEnabled", false) }
        set { defaults.set(newValue, forKey: "syncEnabled") }
    }
    /// The folder the user's cloud app syncs (DittoMac creates "DittoMac Sync" inside it).
    public var syncFolderPath: String {
        get { defaults.string(forKey: "syncFolderPath") ?? "" }
        set { defaults.set(newValue, forKey: "syncFolderPath") }
    }
    /// Friendly provider name shown in the UI ("Google Drive", "iCloud Drive", "Custom folder" …).
    public var syncProviderName: String {
        get { defaults.string(forKey: "syncProviderName") ?? "" }
        set { defaults.set(newValue, forKey: "syncProviderName") }
    }
    public var syncIntervalMinutes: Int {
        get { syncInt("syncIntervalMinutes", 5, 1...60) }
        set { syncSetInt("syncIntervalMinutes", newValue, 1...60) }
    }
    public var syncIncludeImages: Bool {
        get { syncBool("syncIncludeImages", true) }
        set { defaults.set(newValue, forKey: "syncIncludeImages") }
    }
    public var syncIncludeRich: Bool {
        get { syncBool("syncIncludeRich", true) }
        set { defaults.set(newValue, forKey: "syncIncludeRich") }
    }
    public var syncMaxTotalMB: Int {
        get { syncInt("syncMaxTotalMB", 150, 10...150) }
        set { syncSetInt("syncMaxTotalMB", newValue, 10...150) }
    }
    public var syncBackups: Bool {
        get { syncBool("syncBackups", false) }
        set { defaults.set(newValue, forKey: "syncBackups") }
    }
    public var syncBackupKeep: Int {
        get { syncInt("syncBackupKeep", 7, 1...30) }
        set { syncSetInt("syncBackupKeep", newValue, 1...30) }
    }
    /// Name shown to other Macs. Defaults to this Mac's name.
    public var syncDeviceName: String {
        get {
            let v = defaults.string(forKey: "syncDeviceName") ?? ""
            return v.isEmpty ? Self.defaultSyncDeviceName : v
        }
        set { defaults.set(String(newValue.prefix(64)), forKey: "syncDeviceName") }
    }
    /// Random per-installation id (UUID), created once. Names this Mac's snapshot file.
    public var syncDeviceID: String {
        if let v = defaults.string(forKey: "syncDeviceID"), let u = UUID(uuidString: v) { return u.uuidString }
        let id = UUID().uuidString
        defaults.set(id, forKey: "syncDeviceID")
        return id
    }

    static let defaultSyncDeviceName: String = {
        let n = Host.current().localizedName ?? "Mac"
        return String(n.prefix(64))
    }()

    /// Snapshot options derived from the settings.
    public var syncOptions: SyncOptions {
        var o = SyncOptions()
        o.includeImages = syncIncludeImages
        o.includeRichFormats = syncIncludeRich
        o.maxTotalBytes = syncMaxTotalMB * 1024 * 1024
        return o
    }
}
