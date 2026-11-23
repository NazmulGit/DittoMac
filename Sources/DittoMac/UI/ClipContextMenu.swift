// ClipContextMenu.swift — right-click / gear menu for clips, and the window-level "More" menu.

import AppKit
import DittoCore

/// NSMenuItem that runs a closure.
@MainActor
final class QuickPasteMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], enabled: Bool = true,
         handler: (() -> Void)? = nil) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(run(_:)), keyEquivalent: key)
        self.target = self
        self.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        self.isEnabled = enabled && handler != nil
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not supported") }

    @objc private func run(_ sender: Any?) { handler?() }

    static func submenu(_ title: String, _ items: [NSMenuItem], enabled: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        m.autoenablesItems = false
        items.forEach { m.addItem($0) }
        it.submenu = m
        it.isEnabled = enabled
        return it
    }
}

@MainActor
final class ClipContextMenu {
    private unowned let qp: QuickPasteController
    private var state: AppState { qp.state }
    private var settings: Settings { qp.state.settings }

    init(controller: QuickPasteController) {
        self.qp = controller
    }

    private func item(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], enabled: Bool = true,
                      _ handler: @escaping () -> Void) -> NSMenuItem {
        QuickPasteMenuItem(title, key: key, modifiers: mods, enabled: enabled, handler: handler)
    }

    /// Populates `menu` with clip actions for the current selection.
    func buildClipMenu(into menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let sel = qp.selectedClips
        let has = !sel.isEmpty
        let one = sel.count == 1
        let first = sel.first
        let nonGroups = sel.filter { !$0.isGroup }
        let hasClips = !nonGroups.isEmpty
        let inGroup = qp.currentGroupID != nil

        if one, let g = first, g.isGroup {
            menu.addItem(item("Open Group", "\r", []) { [qp] in qp.enterGroup(id: g.id) })
        }
        menu.addItem(item("Paste", "\r", [], enabled: hasClips) { [qp] in qp.pasteSelection(transform: nil) })
        menu.addItem(item("Paste Plain Text", "\r", [.shift], enabled: hasClips) { [qp] in qp.pasteSelection(transform: .plainText) })

        // Paste As ▸ / Copy As ▸ — every PasteFormat; the default paste format is checked.
        let defaultFormat = state.paste.defaultPasteFormat()
        let pasteAs: [NSMenuItem] = PasteFormat.allCases.map { f in
            let it = f == .markdown ? item(f.title, "\r", [.option, .shift], enabled: hasClips) { [qp] in qp.pasteSelection(format: f) }
                                    : item(f.title, enabled: hasClips) { [qp] in qp.pasteSelection(format: f) }
            it.state = f == defaultFormat ? .on : .off
            return it
        }
        menu.addItem(QuickPasteMenuItem.submenu("Paste As", pasteAs, enabled: hasClips))
        let copyAs: [NSMenuItem] = PasteFormat.allCases.map { f in
            item(f.title, enabled: hasClips) { [qp] in qp.copySelection(format: f) }
        }
        menu.addItem(QuickPasteMenuItem.submenu("Copy As", copyAs, enabled: hasClips))

        var special: [NSMenuItem] = TextTransform.allCases.filter { $0 != .plainText }.map { t in
            item(t.title, enabled: hasClips) { [qp] in qp.pasteSelection(transform: t) }
        }
        special.append(.separator())
        special.append(item("Multiple Images Horizontally", enabled: nonGroups.count >= 1) { [qp] in qp.pasteStitched(vertical: false) })
        special.append(item("Multiple Images Vertically", enabled: nonGroups.count >= 1) { [qp] in qp.pasteStitched(vertical: true) })
        special.append(.separator())
        special.append(item("Paste Don’t Change Order", enabled: hasClips) { [qp] in qp.pasteSelection(transform: nil, moveToTop: false) })
        menu.addItem(QuickPasteMenuItem.submenu("Special Paste", special, enabled: hasClips))
        menu.addItem(.separator())

        menu.addItem(item("Copy", "c", enabled: hasClips) { [qp] in qp.copySelection() })
        menu.addItem(item("Preview", " ", [], enabled: one && hasClips) { [qp] in qp.previewSelection() })
        menu.addItem(item("Edit Clip…", "e", enabled: one && hasClips) { [qp] in qp.editSelection() })
        menu.addItem(item("New Clip…", "n") { [qp] in qp.newClip() })
        menu.addItem(item("Properties…", "i", enabled: one) { [qp] in qp.propertiesSelection() })

        let neverDelete = item("Never Auto Delete", enabled: has) { [qp] in qp.toggleNeverAutoDelete() }
        neverDelete.state = has && sel.allSatisfy(\.dontAutoDelete) ? .on : .off
        let quick: [NSMenuItem] = [
            neverDelete,
            item("Remove Hot Key", enabled: sel.contains { $0.shortcut != 0 || $0.moveToGroupShortcut != 0 }) { [qp] in qp.removeHotKeys() },
            item("Remove Quick Paste Text", enabled: sel.contains { !$0.quickPasteText.isEmpty }) { [qp] in qp.removeQuickPasteText() },
        ]
        menu.addItem(QuickPasteMenuItem.submenu("Quick Properties", quick, enabled: has))

        let order: [NSMenuItem] = [
            item("Move to Top", enabled: has) { [qp] in qp.reorderSelection(.top) },
            item("Move Up", enabled: has) { [qp] in qp.reorderSelection(.up) },
            item("Move Down", enabled: has) { [qp] in qp.reorderSelection(.down) },
            item("Move to Last", enabled: has) { [qp] in qp.reorderSelection(.last) },
        ]
        menu.addItem(QuickPasteMenuItem.submenu("Clip Order", order, enabled: has))

        let stickies: [NSMenuItem] = [
            item("Make Top Sticky", enabled: has) { [qp] in qp.stickySelection(.top) },
            item("Make Last Sticky", enabled: has) { [qp] in qp.stickySelection(.last) },
            item("Replace Top Sticky Clip", enabled: has) { [qp] in qp.stickySelection(.replaceTop) },
            item("Remove Sticky", enabled: sel.contains(where: \.isSticky)) { [qp] in qp.stickySelection(.remove) },
        ]
        menu.addItem(QuickPasteMenuItem.submenu("Stickies", stickies, enabled: has))

        let groups: [NSMenuItem] = [
            item("New Group…", "n", [.command, .control]) { [qp] in qp.newGroup(fromSelection: false) },
            item("New Group from Selection…", "n", [.command, .shift], enabled: has) { [qp] in qp.newGroup(fromSelection: true) },
            item("Move to Group…", enabled: has) { [qp] in qp.moveSelectionToGroup(copy: false) },
            item("Copy to Group…", enabled: hasClips) { [qp] in qp.moveSelectionToGroup(copy: true) },
            .separator(),
            item("Back", String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), [.command], enabled: inGroup) { [qp] in qp.goBack() },
            item("History", enabled: inGroup) { [qp] in qp.goHome() },
            item("Toggle Last Group", enabled: qp.hasLastGroup) { [qp] in qp.toggleLastGroup() },
            .separator(),
            item(qp.isGroupsSidebarVisible ? "Hide Groups Sidebar" : "Show Groups Sidebar", "g") { [qp] in qp.toggleGroupsSidebar() },
        ]
        menu.addItem(QuickPasteMenuItem.submenu("Groups", groups))
        menu.addItem(.separator())

        if qp.isFiltered {
            menu.addItem(item("Cancel Filter") { [qp] in qp.clearSearch() })
        } else {
            menu.addItem(item("Filter On Selected Clip", enabled: one && hasClips) { [qp] in qp.filterOnSelectedClip() })
        }
        menu.addItem(item("Compare", enabled: nonGroups.count == 2) { [qp] in qp.compareSelection() })
        menu.addItem(item("QR Code", enabled: one && hasClips) { [qp] in qp.qrCodeSelection() })
        menu.addItem(item("Web Search", enabled: one && hasClips) { [qp] in qp.webSearchSelection(translate: false) })
        menu.addItem(item("Translate", enabled: one && hasClips) { [qp] in qp.webSearchSelection(translate: true) })

        // Share (system share menu, macOS 13+).
        let shareItems = qp.shareItemsForSelection()
        if !shareItems.isEmpty {
            let picker = NSSharingServicePicker(items: shareItems)
            let share = picker.standardShareMenuItem
            share.title = "Share"
            menu.addItem(share)
        } else {
            menu.addItem(item("Share", enabled: false) {})
        }

        let export: [NSMenuItem] = [
            item("Export Clips…", enabled: hasClips) { [qp] in qp.exportClips() },
            item("Export to Text File(s)…", enabled: hasClips) { [qp] in qp.exportTextFiles() },
            item("Export to Image File(s)…", enabled: hasClips) { [qp] in qp.exportImageFiles() },
        ]
        menu.addItem(item(nonGroups.count > 1 ? "Save Clips As…" : "Save Clip As…", "s", [.command, .shift], enabled: hasClips) { [qp] in
            qp.saveSelectionAs()
        })
        menu.addItem(QuickPasteMenuItem.submenu("Export", export, enabled: hasClips))
        menu.addItem(item("Import Clips…") { [qp] in qp.importClips() })

        var sendTo: [NSMenuItem] = []
        let peers = settings.friendsPeers
        let friendsOn = settings.friendsEnabled && state.friends != nil
        for peer in peers {
            sendTo.append(item(peer.name.isEmpty ? peer.host : peer.name, enabled: friendsOn && hasClips) { [qp] in qp.sendSelection(to: peer) })
        }
        if peers.isEmpty {
            sendTo.append(item("No friends configured", enabled: false) {})
        } else if !friendsOn {
            sendTo.append(item("Friends sync is turned off", enabled: false) {})
        }
        sendTo.append(.separator())
        sendTo.append(item("Manage Friends…") { [qp] in qp.state.windows.showPreferences(tab: .friends) })
        menu.addItem(QuickPasteMenuItem.submenu("Send To", sendTo))
        menu.addItem(.separator())
        menu.addItem(item(sel.contains(where: \.isGroup) && one ? "Delete Group…" : "Delete", "\u{8}", [.command], enabled: has) { [qp] in
            qp.deleteSelection()
        })
    }

    /// Window-level "More" menu.
    func buildMoreMenu(into menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let onTop = item("Always on Top", " ", [.control]) { [qp] in qp.toggleAlwaysOnTop() }
        onTop.state = settings.alwaysOnTop ? .on : .off
        menu.addItem(onTop)

        let transparency: [NSMenuItem] = stride(from: 0, through: 40, by: 5).map { p in
            let it = item(p == 0 ? "None" : "\(p)%") { [qp] in qp.setTransparency(p) }
            it.state = settings.transparencyPercent == p ? .on : .off
            return it
        }
        menu.addItem(QuickPasteMenuItem.submenu("Transparency", transparency))

        let lines: [NSMenuItem] = (1...5).map { n in
            let it = item("\(n)") { [qp] in qp.setLinesPerRow(n) }
            it.state = settings.linesPerRow == n ? .on : .off
            return it
        }
        menu.addItem(QuickPasteMenuItem.submenu("Lines Per Row", lines))

        let positions: [(PopupPosition, String)] = [(.caret, "At Caret"), (.cursor, "At Mouse Cursor"), (.previous, "At Previous Position")]
        let pos: [NSMenuItem] = positions.map { p, title in
            let it = item(title) { [qp] in qp.setPopupPosition(p) }
            it.state = settings.popupPosition == p ? .on : .off
            return it
        }
        menu.addItem(QuickPasteMenuItem.submenu("Position", pos))
        menu.addItem(.separator())

        let connected = item("Connected to Clipboard") { [qp] in qp.state.monitor.isConnected.toggle() }
        connected.state = state.monitor.isConnected ? .on : .off
        menu.addItem(connected)
        menu.addItem(item("Save Current Clipboard") { [qp] in qp.state.monitor.saveCurrentClipboard() })
        menu.addItem(.separator())
        menu.addItem(item("Delete All Non-Used Clips…") { [qp] in qp.deleteNonUsedClips() })
        menu.addItem(item("Delete Clip Data…") { [qp] in qp.state.windows.showDeleteClipData() })
        menu.addItem(item("Backup Database…") { [qp] in qp.backupDatabase() })
        menu.addItem(item("Restore Database…") { [qp] in qp.restoreDatabase() })
        menu.addItem(item("Compact Database") { [qp] in qp.compactDatabase() })
        menu.addItem(item("Import Windows Ditto Database…") { [qp] in qp.importWindowsDatabase() })
        menu.addItem(.separator())
        menu.addItem(item("Refresh", "r") { [qp] in qp.reload(keepSelection: true) })
        menu.addItem(item("Preferences…", ",") { [qp] in qp.showPreferences() })
        menu.addItem(item("Quit DittoMac", "q") { NSApp.terminate(nil) })
    }
}
