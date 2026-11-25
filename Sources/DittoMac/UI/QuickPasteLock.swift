// QuickPasteLock.swift — locked notes and sticky notes in the Quick Paste popup: lock / remove lock, unlock-before-use,
// lock-aware delete, New Sticky Note and Show as Desktop Note. Planning logic is `LockPlan` (DittoCore, tested).

import AppKit
import DittoCore

extension QuickPasteController {
    var isVaultUnlocked: Bool { state.vault?.isUnlocked ?? false }

    var vaultService: VaultService? { state.vault as? VaultService }

    func lockPlan(_ clips: [Clip]) -> LockPlan {
        LockPlan(clips.map { LockItem(id: $0.id, isLocked: $0.isLocked, isGroup: $0.isGroup) })
    }

    var selectionLockPlan: LockPlan { lockPlan(selectedClips) }

    /// Runs `action` once every locked clip in `clips` is readable: immediately when there is none or the vault is
    /// already unlocked, otherwise after `requestUnlock` succeeds. Records vault activity for locked notes.
    func withVaultAccess(_ clips: [Clip], reason: String, _ action: @escaping () -> Void) {
        let plan = lockPlan(clips)
        guard plan.hasLocked else { action(); return }
        guard let vault = state.vault, vault.isSetUp else {
            state.message("Locked notes need the vault (Preferences › Security)")
            return
        }
        if vault.isUnlocked {
            vaultService?.noteActivity()
            action()
            return
        }
        vault.requestUnlock(reason: reason) { [weak self] ok in
            guard ok else { return }
            self?.vaultService?.noteActivity()
            action()
        }
    }

    // MARK: Lock / unlock

    /// "Lock" (single or multi selection). The first lock runs the vault setup.
    func lockSelection() {
        let ids = selectionLockPlan.unlockedIDs
        guard !ids.isEmpty else { return }
        guard let vault = state.vault else { state.message("Locking isn’t available"); return }
        vault.lock(clipIDs: ids) { [weak self] _ in self?.reload(keepSelection: true) }
    }

    /// "Remove Lock…" (requires authentication).
    func removeLockSelection() {
        let ids = selectionLockPlan.lockedIDs
        guard !ids.isEmpty, let vault = state.vault else { return }
        vault.removeLock(clipIDs: ids) { [weak self] _ in self?.reload(keepSelection: true) }
    }

    /// ⌘L: lock the selection, or remove the lock when everything selected is already locked.
    func toggleLockSelection() {
        switch selectionLockPlan.toggle {
        case .lock: lockSelection()
        case .removeLock: removeLockSelection()
        case .none: NSSound.beep()
        }
    }

    /// ⇧⌘L: lock the vault now (hides every locked note).
    func lockVaultNow() {
        guard let vault = state.vault, vault.isSetUp else {
            state.message("No locked notes yet — select a clip and press ⌘L to lock it")
            return
        }
        guard vault.isUnlocked else { state.message("Locked notes are already locked"); return }
        vault.lockNow()
        state.message("🔒 Notes locked")
    }

    func unlockVault() {
        guard let vault = state.vault, vault.isSetUp else { return }
        vault.requestUnlock(reason: "show your locked notes") { _ in }
    }

    /// Bottom-bar lock button.
    func toggleVaultLock() {
        guard let vault = state.vault, vault.isSetUp else { return }
        if vault.isUnlocked { lockVaultNow() } else { unlockVault() }
    }

    // MARK: Delete with locked clips

    /// Delete key / menu Delete when the selection contains locked clips: unlocked clips (and groups) are deleted
    /// normally; locked clips only after a clear choice, authentication and VaultPrompts' confirmation
    /// (`VaultService.deleteLockedClips`). Nothing locked is ever dropped silently.
    func deleteSelectionWithLocks(_ sel: [Clip]) {
        let plan = lockPlan(sel)
        let lockedCount = plan.lockedDeleteIDs.count
        guard let vault = vaultService else {
            state.message("Locked notes can’t be deleted here")
            return
        }
        if plan.plainDeleteIDs.isEmpty {
            // Only locked notes selected: authenticate, then VaultPrompts asks "Delete this note?".
            vault.deleteLockedClips(clipIDs: plan.lockedDeleteIDs, confirm: true) { [weak self] ok in
                guard let self else { return }
                if ok { self.state.message(lockedCount == 1 ? "Locked note deleted" : "\(lockedCount) locked notes deleted") }
                self.reload(keepSelection: false)
            }
            return
        }
        let a = NSAlert()
        a.alertStyle = .warning
        let plainCount = plan.plainDeleteIDs.count
        a.messageText = "The selection includes \(lockedCount == 1 ? "a locked note" : "\(lockedCount) locked notes")"
        a.informativeText = "Locked notes are protected from deletion. You can delete the \(plainCount) other "
            + "item\(plainCount == 1 ? "" : "s") and keep the locked \(lockedCount == 1 ? "note" : "notes"), "
            + "or delete everything (you’ll be asked to unlock first). Deleted notes can’t be recovered."
        a.addButton(withTitle: "Delete Others, Keep Locked")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Delete All…")
        a.buttons[2].hasDestructiveAction = true
        let r = a.runModal()
        guard r != .alertSecondButtonReturn else { return }
        let others = sel.filter { plan.plainDeleteIDs.contains($0.id) }
        performPlainDelete(others)
        if r == .alertThirdButtonReturn {
            vault.deleteLockedClips(clipIDs: plan.lockedDeleteIDs, confirm: true) { [weak self] ok in
                guard let self else { return }
                if ok { self.state.message("Deleted \(plainCount + lockedCount) items") }
                self.reload(keepSelection: false)
            }
        } else {
            state.message("Deleted \(plainCount) item\(plainCount == 1 ? "" : "s"); kept \(lockedCount) locked")
        }
    }

    // MARK: Sticky notes

    /// ⌥⌘N / "New Sticky Note": the editor in note mode (title, pin to top, lock, colour).
    func newStickyNote() {
        StickyNoteCenter.shared.newNote(state: state)
    }

    /// "Show as Desktop Note" for the selected clip.
    func showSelectionAsDesktopNote() {
        guard let c = selectedClips.first(where: { !$0.isGroup }) else { return }
        state.windows.showStickyNote(clipID: c.id)
    }
}
