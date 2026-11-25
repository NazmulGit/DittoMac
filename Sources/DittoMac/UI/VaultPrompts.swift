// VaultPrompts.swift — NSAlert-based sheets for the vault: choose a method, create / enter a DittoMac
// password, confirm a reset. Password text is read once, the fields are cleared, and nothing is logged.

import AppKit
import DittoCore

@MainActor
enum VaultPrompts {
    private static func makeAlert(_ title: String, _ info: String, style: NSAlert.Style = .informational) -> NSAlert {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = info
        return a
    }

    // MARK: setup

    /// First-use choice. nil = cancelled.
    static func chooseMethod() -> VaultMethod? {
        let a = makeAlert("Protect your locked notes",
                          """
                          Locked notes are encrypted on disk, hidden until you unlock them, and can’t be deleted by \
                          accident (not by Delete, Delete All, cleanup or the history limit).

                          • Mac password / Touch ID: unlock the way you unlock your Mac. The key is kept in your login Keychain.
                          • DittoMac password: a separate password only you know. Without it the notes can’t be decrypted, \
                          and a forgotten password can’t be recovered.
                          """)
        a.icon = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: nil)
        a.addButton(withTitle: "Use My Mac Password / Touch ID")
        a.addButton(withTitle: "Create a DittoMac Password…")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: return .system
        case .alertSecondButtonReturn: return .password
        default: return nil
        }
    }

    /// Asks for a new DittoMac password twice (policy: Vault.minPasswordLength+), with a live strength hint
    /// and the no-recovery warning. Loops until valid or cancelled (nil).
    static func newPassword(title: String = "Create a DittoMac password", error: String? = nil) -> String? {
        let first = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        first.placeholderString = "New password (at least \(Vault.minPasswordLength) characters)"
        let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        second.placeholderString = "Repeat password"
        let strength = NSTextField(labelWithString: " ")
        strength.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        strength.textColor = .secondaryLabelColor
        let watcher = StrengthWatcher(label: strength)
        first.delegate = watcher
        let stack = NSStackView(views: [first, second, strength])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
        for f in [first, second] { f.widthAnchor.constraint(equalToConstant: 300).isActive = true }

        let warning = "If you forget this password, your locked notes can’t be recovered: the only way out is "
            + "Reset Vault, which deletes them."
        var problem = error
        while true {
            let a = makeAlert(title, (problem.map { $0 + "\n\n" } ?? "") + warning, style: problem == nil ? .informational : .warning)
            a.accessoryView = stack
            a.addButton(withTitle: "Set Password")
            a.addButton(withTitle: "Cancel")
            a.window.initialFirstResponder = first
            let response = a.runModal()
            let p1 = first.stringValue
            let p2 = second.stringValue
            first.stringValue = ""
            second.stringValue = ""
            watcher.update("")
            guard response == .alertFirstButtonReturn else { return nil }
            if let why = Vault.passwordProblem(p1) { problem = why; continue }
            if p1 != p2 { problem = "The passwords don’t match."; continue }
            withExtendedLifetime(watcher) {}
            return p1
        }
    }

    // MARK: unlock

    /// Asks for the DittoMac password. nil = cancelled.
    static func askPassword(reason: String, error: String?) -> String? {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "DittoMac password"
        var info = "Enter your DittoMac password to " + reason + "."
        if let error { info = error + "\n\n" + info }
        let a = makeAlert("Unlock locked notes", info, style: error == nil ? .informational : .warning)
        a.icon = NSImage(systemSymbolName: "lock", accessibilityDescription: nil)
        a.accessoryView = field
        a.addButton(withTitle: "Unlock")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        let response = a.runModal()
        let value = field.stringValue
        field.stringValue = ""
        guard response == .alertFirstButtonReturn, !value.isEmpty else { return nil }
        return value
    }

    // MARK: destructive confirmations

    /// Vault reset: the user must type DELETE.
    static func confirmReset(lockedCount: Int) -> Bool {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "Type DELETE"
        let what = lockedCount == 1 ? "your 1 locked note" : "all \(lockedCount) locked notes"
        let a = makeAlert("Reset the vault?",
                          "This permanently deletes \(what) and the vault key. It can’t be undone. Use this only if you "
                          + "forgot your DittoMac password or the key is lost.\n\nType DELETE to confirm.",
                          style: .critical)
        a.accessoryView = field
        a.addButton(withTitle: "Reset Vault")
        a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        return field.stringValue.trimmingCharacters(in: .whitespaces) == "DELETE"
    }

    static func confirmDeleteLocked(count: Int) -> Bool {
        let a = makeAlert(count == 1 ? "Delete this note?" : "Delete \(count) notes?",
                          "Locked notes are deleted permanently. This can’t be undone.", style: .warning)
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        return a.runModal() == .alertFirstButtonReturn
    }

    static func showError(_ title: String, _ info: String) {
        let a = makeAlert(title, info, style: .warning)
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}

/// Live strength hint under the new-password field.
@MainActor
private final class StrengthWatcher: NSObject, NSTextFieldDelegate {
    let label: NSTextField
    init(label: NSTextField) { self.label = label }

    func update(_ text: String) {
        guard !text.isEmpty else { label.stringValue = " "; return }
        let s = Vault.strength(text)
        label.stringValue = "Strength: " + s.label
        label.textColor = s >= .fair ? .secondaryLabelColor : .systemOrange
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        update(field.stringValue)
    }
}
