// QuickPasteKeyboard.swift — keyboard map for the Quick Paste popup (Ditto shortcuts, mac-ified).
// See "App layer notes" in docs/ARCHITECTURE.md for the full table.

import AppKit
import Carbon.HIToolbox
import DittoCore

extension QuickPasteController {
    private static let digitKeyCodes: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9, kVK_ANSI_0: 0,
        kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3, kVK_ANSI_Keypad4: 4, kVK_ANSI_Keypad5: 5,
        kVK_ANSI_Keypad6: 6, kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8, kVK_ANSI_Keypad9: 9, kVK_ANSI_Keypad0: 0,
    ]

    private static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    func escapePressed(force: Bool) {
        if force {
            hide(restoreFocus: true)
            return
        }
        if !searchField.stringValue.isEmpty || isFiltered {
            clearSearch()
            panel.makeFirstResponder(tableView)
            return
        }
        hide(restoreFocus: true)
    }

    /// Returns true when the key was consumed.
    func handleKeyDown(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(e.keyCode)
        let inSearch = isSearchFocused
        let none = flags.isEmpty
        let cmd = flags == [.command]
        let key = (e.charactersIgnoringModifiers ?? "").lowercased()

        switch code {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags == [.option] { propertiesSelection(); return true }
            if flags == [.shift] { pasteSelection(transform: .plainText); return true }
            if flags == [.option, .shift] { pasteSelection(format: .markdown); return true }
            if none || cmd {
                if inSearch && isSearchPending {
                    runSearchNow(recordHistory: true)
                    return true
                }
                pasteSelection(transform: nil)
                return true
            }
        case kVK_Escape:
            escapePressed(force: flags.contains(.shift))
            return true
        case kVK_UpArrow where cmd:
            goBack()
            return true
        case kVK_UpArrow, kVK_DownArrow, kVK_PageUp, kVK_PageDown:
            if inSearch && (none || flags == [.shift]) {
                tableView.keyDown(with: e)
                return true
            }
        case kVK_Home:
            if cmd || (none && !inSearch) { goHome(); return true }
        case kVK_F3:
            if none { previewSelection(); return true }
        case kVK_F5:
            if none { refresh(); return true }
        case kVK_F7:
            if none { newGroup(fromSelection: true); return true }
        case kVK_Space:
            if flags == [.control] { toggleAlwaysOnTop(); return true }
            if none && !inSearch { previewSelection(); return true }
        case kVK_Delete, kVK_ForwardDelete:
            if inSearch { return false }
            if code == kVK_Delete && none && currentGroupID != nil && !isFiltered {
                goBack()   // ⌫ in a group with no search = back to parent (upstream Backspace)
                return true
            }
            if none || cmd { deleteSelection(); return true }
        default:
            break
        }

        // ⌘1…⌘0 paste position, ⌥⌘1…⌥⌘0 plain-text position.
        if let d = Self.digitKeyCodes[code], cmd || flags == [.command, .option] {
            pastePosition(digit: d, plain: flags.contains(.option))
            return true
        }

        if cmd {
            switch key {
            case "c":
                if inSearch, (searchField.currentEditor()?.selectedRange.length ?? 0) > 0 { return false }
                copySelection()
                return true
            case "f": focusSearch(); return true
            case "g": toggleGroupsSidebar(); return true
            case "n": newClip(); return true
            case "e": editSelection(); return true
            case "i": propertiesSelection(); return true
            case "r": refresh(); return true
            case "a":
                if inSearch { return false }
                tableView.selectAll(nil)
                return true
            case ",": showPreferences(); return true
            case "w": hide(restoreFocus: true); return true
            default: break
            }
        }
        if flags == [.command, .shift], key == "n" { newGroup(fromSelection: true); return true }
        if flags == [.command, .shift], key == "s" { saveSelectionAs(); return true }
        if flags == [.command, .control], key == "n" { newGroup(fromSelection: false); return true }
        if flags == [.command, .option], key == "f" { cycleSearchMode(); return true }

        // Clip / group shortcuts that work inside the popup.
        if !none || Self.functionKeyCodes.contains(code) {
            let combo = KeyCombo(dmEvent: e).encoded
            if let c = localShortcuts[combo] {
                if c.isGroup { enterGroup(id: c.id) } else { paste(ids: [c.id], transform: nil) }
                return true
            }
            if let g = localMoveToGroupShortcuts[combo], !selectedIDs.isEmpty {
                moveOrCopy(ids: selectedIDs, toGroup: g.id, copy: false)
                return true
            }
        }

        // Typing a printable character in the list jumps to search, seeded with it.
        if !inSearch, none || flags == [.shift], let chars = e.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            focusSearch(seed: chars)
            return true
        }
        return false
    }

    func refresh() {
        ClipThumbnailCache.shared.invalidate()
        refreshLocalShortcuts()
        reload(keepSelection: true)
        reloadSidebar()
    }
}
