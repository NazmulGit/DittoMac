// StatusItemController.swift — menu-bar icon and menu.

import AppKit
import DittoCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private unowned let state: AppState
    private var item: NSStatusItem?
    private let menu = NSMenu()
    static let releasesURL = URL(string: "https://github.com/NazmulGit/DittoMac-Clipboard-Manager/releases")!

    init(state: AppState) {
        self.state = state
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        NotificationCenter.default.addObserver(self, selector: #selector(refreshIcon), name: .dittoConnectionChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .dittoSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshIcon), name: .dittoMenuBarBadgeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(clipsChanged), name: .dittoClipsChanged, object: nil)
        applyVisibility()
    }

    @objc private func settingsChanged() {
        applyVisibility()
        refreshIcon()
    }

    @objc private func clipsChanged() {
        if state.settings.menuBarShowRecentCount { refreshIcon() }
    }

    /// Shows / removes the menu-bar icon per Settings.showMenuBarIcon. If the Dock icon is also hidden the
    /// menu-bar icon is forced on so the app stays reachable.
    func applyVisibility() {
        let show = state.settings.showMenuBarIcon || !state.settings.showDockIcon
        if show, item == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
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
        let s = state.settings
        let img = NSImage(systemSymbolName: s.menuBarIconSymbol, accessibilityDescription: "DittoMac")
            ?? NSImage(systemSymbolName: MenuBarIcon.defaultSymbol, accessibilityDescription: "DittoMac")
        img?.isTemplate = true
        b.image = img
        let badge = s.menuBarShowRecentCount ? MenuBarIcon.badgeText(s.copyCountTotal - s.menuBarCountBaseline) : ""
        b.title = badge
        b.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        b.imagePosition = badge.isEmpty ? .imageOnly : .imageLeading
        item?.length = badge.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
        let dim = !connected && s.menuBarDimWhenDisconnected
        b.appearsDisabled = dim
        b.alphaValue = dim ? 0.45 : 1
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

    /// Menu-started captures wait ~0.25 s so the fading menu isn't captured.
    static let menuCloseDelay: TimeInterval = 0.25
    private func captureAfterMenuCloses(_ action: @escaping (ScreenshotServicing) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.menuCloseDelay) { [weak self] in
            MainActor.assumeIsolated { if let s = self?.state.screenshots { action(s) } }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(QuickPasteMenuItem("Show Quick Paste", key: "") { [weak self] in self?.state.showQuickPaste?(nil) })
        menu.addItem(QuickPasteMenuItem("New Sticky Note…", key: "") { [weak self] in
            guard let self else { return }
            StickyNoteCenter.shared.newNote(state: self.state)
        })
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
            // Locked notes never show their text here, even while the vault is unlocked.
            var title = clip.isLocked ? "🔒 " + ClipStore.lockedPlaceholder
                : clip.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
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
            mi.toolTip = clip.isLocked ? "Locked note — choosing it asks to unlock first" : String(clip.text.prefix(500))
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
        // Started from the menu: wait for the menu to finish fading so it isn't in the snapshot.
        menu.addItem(QuickPasteMenuItem("Capture Area…", key: "") { [weak self] in self?.captureAfterMenuCloses { $0.captureArea() } })
        menu.addItem(QuickPasteMenuItem("Capture Window…", key: "") { [weak self] in self?.captureAfterMenuCloses { $0.captureWindow() } })
        menu.addItem(QuickPasteMenuItem("Capture Full Screen", key: "") { [weak self] in self?.captureAfterMenuCloses { $0.captureFullScreen() } })
        menu.addItem(.separator())
        if let v = state.vault, v.isSetUp {
            menu.addItem(QuickPasteMenuItem(v.isUnlocked ? "Lock Notes Now" : "Unlock Notes…", key: "") { [weak self] in
                guard let v = self?.state.vault else { return }
                if v.isUnlocked { v.lockNow() } else { v.requestUnlock(reason: "Unlock your locked notes") { _ in } }
            })
        }
        if let sync = state.sync {
            if sync.isReady {
                menu.addItem(QuickPasteMenuItem("Sync Now (\(sync.statusText))", key: "") { [weak self] in self?.state.sync?.syncNow() })
            } else {
                // Nothing to run: show why instead of an item that silently does nothing.
                let it = QuickPasteMenuItem("Sync Now (\(sync.statusText))", key: "", enabled: false)
                it.toolTip = "Set up sync in Preferences ▸ Sync: turn it on, choose a cloud folder and save a passphrase."
                menu.addItem(it)
            }
        }
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
