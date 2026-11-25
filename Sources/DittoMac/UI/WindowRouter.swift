import AppKit
import DittoCore

/// Creates and tracks all secondary windows. One window per kind where sensible.
@MainActor
final class WindowRouter: WindowRouting {
    private let state: AppState
    private var preview: PreviewWindowController?
    private var editors: [Int64: EditorWindowController] = [:]
    private var newEditors: [ObjectIdentifier: EditorWindowController] = [:]
    private var properties: [Int64: PropertiesWindowController] = [:]
    private var preferences: PreferencesWindowController?
    private var qr: QRCodeWindowController?
    private var compares: [ObjectIdentifier: CompareWindowController] = [:]
    private var deleteData: DeleteClipDataWindowController?
    private var about: AboutWindowController?
    private var pickers: [ObjectIdentifier: GroupPickerController] = [:]
    /// Clip ids shown by each compare window (to close it when the vault locks).
    private var compareIDs: [ObjectIdentifier: [Int64]] = [:]
    /// The QR window shows text taken from a locked note.
    var qrShowsLockedNote = false
    private var vaultObserver: NSObjectProtocol?

    init(state: AppState) {
        self.state = state
        vaultObserver = NotificationCenter.default.addObserver(forName: .dittoVaultChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeLockedContentIfLocked() }
        }
    }

    /// When the vault locks, windows that show a locked note's decrypted text (properties, compare, a QR code made
    /// from it) are closed. Editors and desktop notes handle this themselves; the preview closes itself (see PreviewWindowController).
    private func closeLockedContentIfLocked() {
        guard state.vault?.isUnlocked != true else { return }
        func isLocked(_ id: Int64) -> Bool { ((try? state.store.clip(id: id)) ?? nil)?.isLocked == true }
        for (id, c) in properties where isLocked(id) { c.window?.close() }
        for (key, c) in compares where (compareIDs[key] ?? []).contains(where: isLocked) { c.window?.close() }
        if qrShowsLockedNote { qr?.window?.close(); qrShowsLockedNote = false }
    }

    private func activate() { NSApp.activate(ignoringOtherApps: true) }

    func showPreview(clipID: Int64) {
        if preview == nil {
            let p = PreviewWindowController(state: state)
            p.onClose = { [weak self] in self?.preview = nil }
            preview = p
        }
        preview?.show(clipID: clipID)
    }

    func showEditor(clipID: Int64?) {
        if let id = clipID, let existing = editors[id] { existing.show(); return }
        let c = EditorWindowController(state: state, clipID: clipID)
        let key = ObjectIdentifier(c)
        c.onClose = { [weak self, weak c] in
            guard let self, let c else { return }
            if let id = clipID { self.editors[id] = nil }
            self.newEditors[ObjectIdentifier(c)] = nil
            _ = key
        }
        if let id = clipID { editors[id] = c } else { newEditors[key] = c }
        c.show()
    }

    func showProperties(clipID: Int64) {
        if let existing = properties[clipID] { existing.window?.makeKeyAndOrderFront(nil); activate(); return }
        let c = PropertiesWindowController(state: state, clipID: clipID)
        c.onClose = { [weak self] in self?.properties[clipID] = nil }
        properties[clipID] = c
        c.window?.makeKeyAndOrderFront(nil)
        activate()
    }

    func showPreferences(tab: PreferencesTab?) {
        if preferences == nil {
            let p = PreferencesWindowController(state: state)
            p.onClose = { [weak self] in self?.preferences = nil }
            preferences = p
        }
        if let tab { preferences?.select(tab) }
        preferences?.window?.makeKeyAndOrderFront(nil)
        activate()
    }

    func showQRCode(text: String) {
        qrShowsLockedNote = false      // the caller sets it again for text from a locked note
        if let q = qr { q.setText(text); q.window?.makeKeyAndOrderFront(nil); activate(); return }
        let q = QRCodeWindowController(text: text)
        q.onClose = { [weak self] in self?.qr = nil; self?.qrShowsLockedNote = false }
        qr = q
        q.window?.makeKeyAndOrderFront(nil)
        activate()
    }

    func showCompare(leftID: Int64, rightID: Int64) {
        let c = CompareWindowController(state: state, leftID: leftID, rightID: rightID)
        let key = ObjectIdentifier(c)
        c.onClose = { [weak self] in self?.compares[key] = nil; self?.compareIDs[key] = nil }
        compares[key] = c
        compareIDs[key] = [leftID, rightID]
        c.window?.makeKeyAndOrderFront(nil)
        activate()
    }

    func showDeleteClipData() {
        if deleteData == nil {
            let d = DeleteClipDataWindowController(state: state)
            d.onClose = { [weak self] in self?.deleteData = nil }
            deleteData = d
        }
        deleteData?.window?.makeKeyAndOrderFront(nil)
        activate()
    }

    func showAbout() {
        if about == nil { about = AboutWindowController() }
        about?.window?.makeKeyAndOrderFront(nil)
        activate()
    }

    func showStickyNote(clipID: Int64) {
        StickyNoteCenter.shared.show(clipID: clipID, state: state, activate: true)
    }

    func pickGroup(title: String, completion: @escaping (Int64?) -> Void) {
        var holder: GroupPickerController?
        let c = GroupPickerController(store: state.store, router: self, title: title, completion: completion)
        holder = c
        let key = ObjectIdentifier(c)
        c.onFinish = { [weak self] in self?.pickers[key] = nil; holder = nil }
        pickers[key] = c
        c.window?.makeKeyAndOrderFront(nil)
        activate()
        _ = holder
    }

    func promptText(title: String, message: String, defaultValue: String, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        activate()
        let r = alert.runModal()
        completion(r == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}
