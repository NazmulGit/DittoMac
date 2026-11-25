// Contracts.swift — shared app-layer interfaces. Owned by the integrator; do not change signatures
// without updating docs/ARCHITECTURE.md. Concrete types:
//   ClipboardMonitor(state:)  PasteService(state:)  HotKeyCenter()        -> Services/ (popup agent)
//   WindowRouter(state:)                                                  -> UI/WindowRouter.swift (windows agent)
//   FriendsService(state:)  CopyBuffers(state:)  Keychain                 -> Services/ (friends agent)
//   AppTheme                                                              -> UI/Theme.swift (popup agent)

import AppKit
import DittoCore

extension Notification.Name {
    /// Posted (main thread) whenever clips/groups are added, changed or deleted.
    static let dittoClipsChanged = Notification.Name("io.github.dittomac.clipsChanged")
    /// Posted when settings that affect UI changed (theme, font, lines per row, …).
    static let dittoSettingsChanged = Notification.Name("io.github.dittomac.settingsChanged")
    /// Posted when any hotkey assignment changed; services re-register.
    static let dittoHotkeysChanged = Notification.Name("io.github.dittomac.hotkeysChanged")
    /// Posted when clipboard connection state changes.
    static let dittoConnectionChanged = Notification.Name("io.github.dittomac.connectionChanged")
}

/// Pasteboard type used to tag DittoMac's own writes so they are not re-captured.
let dittoInternalPasteboardType = NSPasteboard.PasteboardType("org.dittomac.internal")

@MainActor
protocol ClipboardMonitoring: AnyObject {
    var isConnected: Bool { get set }          // persisted in Settings.connectedToClipboard
    /// When set, the next captured clip (within `until`) is filed into this group.
    func captureNextClip(intoGroup groupID: Int64, until: Date)
    /// Force-save whatever is currently on the pasteboard (ignores dedupe-by-changeCount).
    func saveCurrentClipboard()
    /// Ignore pasteboard changes up to and including this changeCount (own writes).
    func ignoreChangeCount(_ count: Int)
}

@MainActor
protocol PasteServicing: AnyObject {
    /// App that was frontmost before DittoMac's popup opened (paste target).
    var targetApp: NSRunningApplication? { get set }
    /// Put clips on the pasteboard (multi-clip → joined text per Settings), optionally transformed,
    /// then (if sendPaste) re-activate targetApp and post ⌘V. Updates lastPasteDate/order per Settings.
    /// No transform → the default paste format (`defaultPasteFormat()`).
    func paste(clipIDs: [Int64], transform: TextTransform?, sendPaste: Bool, moveToTop: Bool)
    /// Paste with stitched images (multi-image) horizontally or vertically.
    func pasteImagesStitched(clipIDs: [Int64], vertical: Bool)
    /// Paste in an explicit format (Paste As ▸). `.original` = every stored format; others convert (see PasteFormat).
    func paste(clipIDs: [Int64], format: PasteFormat, sendPaste: Bool, moveToTop: Bool)
    /// Format a default paste (Return, double-click, ⌘1…⌘0, global hotkeys) uses for the current `targetApp`.
    func defaultPasteFormat() -> PasteFormat
    /// Copy only (no ⌘V), e.g. ⌘C in the list.
    func copyToPasteboard(clipIDs: [Int64], transform: TextTransform?)
    /// Copy only, in an explicit format (Copy As ▸). Returns false (with a HUD message) when nothing was written.
    @discardableResult func copyToPasteboard(clipIDs: [Int64], format: PasteFormat) -> Bool
    /// Low-level: write formats to the general pasteboard tagged as internal. Returns new changeCount.
    @discardableResult func writeToPasteboard(_ formats: [ClipFormat]) -> Int
    /// Post a synthetic ⌘<key> (e.g. "c" for copy, "v" for paste) to the frontmost app.
    func postCommandKey(_ char: Character)
    func isAccessibilityTrusted(prompt: Bool) -> Bool
}

@MainActor
protocol HotKeyRegistering: AnyObject {
    /// Registers (or replaces) a global hotkey under a unique name. Returns false if the OS refused.
    @discardableResult func register(name: String, combo: KeyCombo, handler: @escaping () -> Void) -> Bool
    func unregister(name: String)
    func unregisterAll(withPrefix prefix: String)
    /// Temporarily suspend all hotkeys (used while a KeyRecorderView is recording).
    var isSuspended: Bool { get set }
}

enum PreferencesTab: String, CaseIterable {
    case general, appearance, quickPaste, keyboard, screenshots, security, sync, copyBuffers, types, friends, rules, stats, advanced
}

@MainActor
protocol WindowRouting: AnyObject {
    func showPreview(clipID: Int64)
    func showEditor(clipID: Int64?)                 // nil = new clip
    func showProperties(clipID: Int64)
    func showPreferences(tab: PreferencesTab?)
    func showQRCode(text: String)
    func showCompare(leftID: Int64, rightID: Int64)
    func showDeleteClipData()
    func showAbout()
    /// Floating desktop note window for a clip (a sticky note). Locked notes show an unlock view while locked.
    func showStickyNote(clipID: Int64)
    /// Group picker sheet/window. completion(nil) = cancelled, (-1) = top level, else group id.
    func pickGroup(title: String, completion: @escaping (Int64?) -> Void)
    /// Simple text prompt (e.g. new group name). completion(nil) = cancelled.
    func promptText(title: String, message: String, defaultValue: String, completion: @escaping (String?) -> Void)
}

@MainActor
protocol FriendsServicing: AnyObject {
    var isRunning: Bool { get }
    var statusText: String { get }
    func applySettings()                             // start/stop listener per Settings.friendsEnabled
    func send(clipIDs: [Int64], to peer: FriendPeer)
    func sendToAutoPeers(clipID: Int64)              // peers with sendAllCopies == true
    func setPassphrase(_ passphrase: String) throws  // stores in Keychain
    var hasPassphrase: Bool { get }
}

@MainActor
protocol CopyBuffersServicing: AnyObject {
    static var bufferCount: Int { get }              // 5
    func reloadHotkeys()
}

// MARK: v1.2 services (screenshots, vault, sync)

/// Lightshot-style capture: frozen-screen overlay, selection, annotation tools, beautify, copy/save/upload/share.
@MainActor
protocol ScreenshotServicing: AnyObject {
    func captureArea()
    func captureWindow()
    func captureFullScreen()
    /// (Re)register the capture hotkeys ("captureArea", "captureWindow", "captureFullScreen") from Settings.
    func registerHotkeys()
    func hasScreenRecordingPermission(prompt: Bool) -> Bool
    /// Human-readable problems from the last `registerHotkeys()` (a shortcut macOS refused because it is in use).
    var hotkeyProblems: [String] { get }
}

enum VaultMethod: String, CaseIterable {
    case system      // Touch ID or the Mac login password (macOS prompt; the app never sees the password)
    case password    // a separate DittoMac password
}

/// Locks clips/sticky notes: encrypted at rest, hidden until unlocked, protected from deletion.
@MainActor
protocol VaultServicing: AnyObject {
    var isSetUp: Bool { get }
    var method: VaultMethod { get }
    var isUnlocked: Bool { get }
    var autoLockMinutes: Int { get set }
    /// Authenticate if needed. completion(true) when the vault is unlocked (immediately if it already is).
    func requestUnlock(reason: String, completion: @escaping (Bool) -> Void)
    func lockNow()
    /// Lock clips (first use runs setup: choose Mac password/Touch ID or a new password).
    func lock(clipIDs: [Int64], completion: @escaping (Bool) -> Void)
    /// Permanently remove the lock from clips (requires authentication).
    func removeLock(clipIDs: [Int64], completion: @escaping (Bool) -> Void)
    func configure(method: VaultMethod, newPassword: String?, completion: @escaping (Bool) -> Void)
}

/// Encrypted sync/backup through any folder your cloud app syncs (Google Drive, iCloud Drive, Dropbox, OneDrive …).
@MainActor
protocol SyncServicing: AnyObject {
    var statusText: String { get }
    var lastSync: Date? { get }
    /// Sync is on and has a folder and a passphrase, so `syncNow()` can do something.
    var isReady: Bool { get }
    func applySettings()
    func syncNow()
}

/// Central app state / service locator. Created in AppDelegate.
@MainActor
final class AppState {
    static var shared: AppState!

    let store: ClipStore
    let settings: Settings

    var monitor: ClipboardMonitoring!
    var paste: PasteServicing!
    var hotkeys: HotKeyRegistering!
    var windows: WindowRouting!
    var friends: FriendsServicing?
    var copyBuffers: CopyBuffersServicing?
    var screenshots: ScreenshotServicing?
    var vault: VaultServicing?
    var sync: SyncServicing?

    /// Show / toggle the Quick Paste popup (set by the popup controller).
    /// Request a debounced retention pass (set by AppDelegate).
    var scheduleRetention: (() -> Void)?

    var showQuickPaste: ((_ groupID: Int64?) -> Void)?
    var hideQuickPaste: (() -> Void)?

    init(store: ClipStore, settings: Settings) {
        self.store = store
        self.settings = settings
    }

    func clipsChanged() {
        NotificationCenter.default.post(name: .dittoClipsChanged, object: nil)
    }

    /// Present a transient, non-blocking message (status bar popover / notification-like HUD).
    var showMessage: ((_ text: String) -> Void)?
    func message(_ text: String) { showMessage?(text) }
}
