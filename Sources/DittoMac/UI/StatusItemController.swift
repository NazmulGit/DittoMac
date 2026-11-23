// StatusItemController.swift — menu-bar icon and menu.

import AppKit
import DittoCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private unowned let state: AppState
    private var item: NSStatusItem?
    private let menu = NSMenu()
    static let releasesURL = URL(string: "https://github.com/NazmulGit/DittoMac/releases")!

    init(state: AppState) {
        self.state = state
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        NotificationCenter.default.addObserver(self, selector: #selector(refreshIcon), name: .dittoConnectionChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .dittoSettingsChanged, object: nil)
        applyVisibility()
    }

    @objc private func settingsChanged() { applyVisibility() }

    /// Shows / removes the menu-bar icon per Settings.showMenuBarIcon. If the Dock icon is also hidden the
    /// menu-bar icon is forced on so the app stays reachable.
    func applyVisibility() {
        let show = state.settings.showMenuBarIcon || !state.settings.showDockIcon
        if show, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let b = it.button {
                b.target = self
                b.action = #selector(buttonClicked(_:))
                b.sendAction(on: [.leftMouseUp, .rightMouseUp])
                b.toolTip = "DittoMac"
            }
            item = it
            refreshIcon()
        } else if !show, let it = item {
            NSStatusBar.system.removeStatusItem(it)
            item = nil
        }
    }

    @objc func refreshIcon() {
        guard let b = item?.button else { return }
        let connected = state.monitor?.isConnected ?? true
        let img = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "DittoMac")
        img?.isTemplate = true
        b.image = img
        b.appearsDisabled = !connected
        b.alphaValue = connected ? 1 : 0.45
        b.toolTip = connected ? "DittoMac" : "DittoMac — disconnected from clipboard"
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let ev = NSApp.currentEvent
        let isRight = ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true
            || ev?.modifierFlags.contains(.option) == true
        if isRight {
            showMenu()
        } else {
            state.showQuickPaste?(nil)
        }
    }

    /// Pops up the status menu (right-click, or ⌥/⌃-click).
    func showMenu() {
        guard let it = item else { return }
        it.menu = menu
        it.button?.performClick(nil)
        it.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(QuickPasteMenuItem("Show Quick Paste", key: "") { [weak self] in self?.state.showQuickPaste?(nil) })
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Recent Clips", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let filter = ClipFilter(parentID: nil, showAllClipsInMainList: true, showGroupsInMainList: false, limit: 10)
        let recent = (try? state.store.clips(filter)) ?? []
        if recent.isEmpty {
            let none = NSMenuItem(title: "No clips yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (i, clip) in recent.enumerated() {
            var title = clip.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if title.count > 60 { title = String(title.prefix(60)) + "…" }
            if title.isEmpty { title = "(empty)" }
            let id = clip.id
            let mi = QuickPasteMenuItem(title, key: i < 9 ? "\(i + 1)" : (i == 9 ? "0" : "")) { [weak self] in
                guard let self else { return }
                self.state.paste.copyToPasteboard(clipIDs: [id], transform: nil)
                self.state.message("Copied to clipboard")
            }
            mi.keyEquivalentModifierMask = []
            mi.toolTip = String(clip.text.prefix(500))
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        let connected = QuickPasteMenuItem("Connected to Clipboard", key: "") { [weak self] in
            guard let self, let m = self.state.monitor else { return }
            m.isConnected.toggle()
        }
        connected.state = (state.monitor?.isConnected ?? true) ? .on : .off
        menu.addItem(connected)
        menu.addItem(QuickPasteMenuItem("Save Current Clipboard", key: "") { [weak self] in
            self?.state.monitor.saveCurrentClipboard()
        })
        menu.addItem(.separator())
        menu.addItem(QuickPasteMenuItem("Preferences…", key: ",") { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.state.windows.showPreferences(tab: nil)
        })
        menu.addItem(QuickPasteMenuItem("Check for Updates…", key: "") {
            NSWorkspace.shared.open(StatusItemController.releasesURL)
        })
        menu.addItem(QuickPasteMenuItem("About DittoMac", key: "") { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.state.windows.showAbout()
        })
        menu.addItem(.separator())
        menu.addItem(QuickPasteMenuItem("Quit DittoMac", key: "q") { NSApp.terminate(nil) })
    }
}
