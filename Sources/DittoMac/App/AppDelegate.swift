// AppDelegate.swift — builds AppState and all services, registers global hotkeys, retention, first-run.

import AppKit
import DittoCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let activateNotification = Notification.Name("io.github.dittomac.activateRunningInstance")
    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private(set) var state: AppState!
    private var monitor: ClipboardMonitor!
    private var paste: PasteService!
    private var hotkeys: HotKeyCenter!
    private var quickPaste: QuickPasteController!
    private var statusItem: StatusItemController!
    private var retentionTimer: Timer?
    private var retentionDebounce: DispatchWorkItem?
    private var groupPressTimes: [Int64: Date] = [:]
    private var pendingGroupOpen: DispatchWorkItem?
    private var lastReportedHotkeyFailures: Set<String> = []

    private var settings: Settings { Settings.shared }

    // MARK: Launch

    func applicationWillFinishLaunching(_ notification: Notification) {
        enforceSingleInstance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy()

        let store: ClipStore
        do {
            store = try ClipStore(path: Self.databaseURL().path)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.alertStyle = .critical
            a.messageText = "DittoMac couldn’t open its database"
            a.informativeText = "\(Self.databaseURL().path)\n\n\(error.localizedDescription)"
            a.addButton(withTitle: "Quit")
            a.runModal()
            NSApp.terminate(nil)
            return
        }

        let state = AppState(store: store, settings: settings)
        AppState.shared = state
        self.state = state
        state.showMessage = { text in HUD.shared.show(text) }

        hotkeys = HotKeyCenter()
        state.hotkeys = hotkeys
        paste = PasteService(state: state)
        state.paste = paste
        monitor = ClipboardMonitor(state: state)
        state.monitor = monitor
        state.windows = WindowRouter(state: state)
        state.friends = FriendsService(state: state)
        state.copyBuffers = CopyBuffers(state: state)

        quickPaste = QuickPasteController(state: state)
        statusItem = StatusItemController(state: state)
        buildMainMenu()

        monitor.start()
        registerHotkeys()
        ensureLaunchAtLogin()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(hotkeysChanged), name: .dittoHotkeysChanged, object: nil)
        nc.addObserver(self, selector: #selector(settingsChanged), name: .dittoSettingsChanged, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(otherInstanceLaunched),
                                                            name: Self.activateNotification, object: nil)

        state.scheduleRetention = { [weak self] in self?.scheduleRetention() }
        applyRetention()
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRetention() }
        }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        retentionTimer = t

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.firstRunChecks()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        state?.showQuickPaste?(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        retentionTimer?.invalidate()
        monitor?.stop()
    }

    static func databaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("DittoMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("Ditto.db")
    }

    // MARK: Single instance

    private func enforceSingleInstance() {
        guard let bid = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid).filter { $0.processIdentifier != me }
        guard let other = others.first else { return }
        if #available(macOS 14.0, *) { other.activate() } else { other.activate(options: [.activateIgnoringOtherApps]) }
        DistributedNotificationCenter.default().postNotificationName(Self.activateNotification, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
        exit(0)
    }

    @objc private func otherInstanceLaunched() {
        state?.showQuickPaste?(nil)
    }

    // MARK: Settings

    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = settings.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    @objc private func settingsChanged() {
        applyActivationPolicy()
        scheduleRetention()
    }

    @objc private func hotkeysChanged() {
        registerHotkeys()
    }

    // MARK: Hotkeys

    /// Start with the Mac by default (like the Windows installer's "run on startup").
    /// Registers when the item was never registered, so turning it off in Preferences (which clears
    /// Settings.launchAtLogin) or in System Settings › Login Items is respected. If the app now runs from a
    /// different location than the one that was registered (moved, reinstalled, or a build folder), the login
    /// item is re-registered so it launches this copy at the next login.
    private func ensureLaunchAtLogin() {
        let defaults = state.settings.defaults
        let pathKey = "loginItemRegisteredPath"
        let here = Bundle.main.bundlePath
        guard here.hasSuffix(".app"), state.settings.launchAtLogin else { return }
        let before = LoginItem.status
        do {
            if before == .enabled {
                // Unknown (nil) or different path: re-register so the item points at this copy.
                let old = defaults.string(forKey: pathKey)
                if old != here {
                    try LoginItem.setEnabled(false)
                    try LoginItem.setEnabled(true)
                    NSLog("DittoMac: login item re-registered for \(here) (was \(old ?? "unknown"))")
                }
                defaults.set(here, forKey: pathKey)
            } else if before == .notRegistered || before == .notFound {
                // A never-registered app can report .notFound; register() still works then.
                try LoginItem.setEnabled(true)
                defaults.set(here, forKey: pathKey)
                NSLog("DittoMac: launch at login registered: \(LoginItem.statusText)")
            } else {
                NSLog("DittoMac: launch at login: \(LoginItem.statusText)")
            }
        } catch {
            NSLog("DittoMac: launch-at-login registration failed: \(error)")
        }
    }

    private func registerHotkeys() {
        for prefix in ["main.", "clip.", "group.", "mtg."] { hotkeys.unregisterAll(withPrefix: prefix) }
        var failures: [String] = []

        // Names match the Preferences › Keyboard page (CopyBuffers registers "buffer<i>.copy|paste|cut").
        func reg(_ name: String, _ handler: @escaping () -> Void) {
            let v = settings.hotkey(name)
            guard v != 0 else { return }
            let combo = KeyCombo(encoded: v)
            if !hotkeys.register(name: "main." + name, combo: combo, handler: handler) {
                failures.append(combo.displayString)
            }
        }

        for name in ["activate", "activate2", "activate3"] {
            reg(name) { [weak self] in self?.quickPaste.activateHotkeyPressed() }
        }
        reg("textOnlyPaste") { [weak self] in self?.paste.pasteCurrentClipboardAsPlainText() }
        reg("saveClipboard") { [weak self] in self?.monitor.saveCurrentClipboard() }
        reg("copyAndSave") { [weak self] in self?.copyAndSave() }
        for i in 1...10 {
            reg("lastTen\(i)") { [weak self] in self?.pasteLastTen(i) }
        }

        for c in (try? state.store.clipsWithShortcuts()) ?? [] {
            let id = c.id
            if c.shortcut != 0, c.globalShortcut {
                let combo = KeyCombo(encoded: c.shortcut)
                let ok: Bool
                if c.isGroup {
                    ok = hotkeys.register(name: "group.\(id)", combo: combo) { [weak self] in self?.groupHotkeyPressed(id) }
                } else {
                    ok = hotkeys.register(name: "clip.\(id)", combo: combo) { [weak self] in self?.pasteClipGlobally(id) }
                }
                if !ok { failures.append(combo.displayString) }
            }
            if c.moveToGroupShortcut != 0, c.globalMoveToGroupShortcut, c.isGroup {
                let combo = KeyCombo(encoded: c.moveToGroupShortcut)
                if !hotkeys.register(name: "mtg.\(id)", combo: combo, handler: { [weak self] in self?.quickSave(intoGroup: id) }) {
                    failures.append(combo.displayString)
                }
            }
        }

        let failSet = Set(failures)
        if !failSet.isEmpty, failSet != lastReportedHotkeyFailures {
            state.message("Couldn’t register shortcut(s) \(failures.joined(separator: ", ")) — already used by another app?")
        }
        lastReportedHotkeyFailures = failSet
    }

    /// Paste a clip from a global clip shortcut into the frontmost app.
    private func pasteClipGlobally(_ id: Int64) {
        paste.targetApp = paste.frontmostOtherApp()
        if quickPaste.isVisible && !settings.alwaysOnTop { quickPaste.hide(restoreFocus: false) }
        paste.paste(clipIDs: [id], transform: nil, sendPaste: true, moveToTop: true)
    }

    /// Global "last ten" position hotkeys: paste the Nth clip of the history list.
    private func pasteLastTen(_ n: Int) {
        let filter = ClipFilter(parentID: nil, showAllClipsInMainList: settings.showAllClipsInMainList,
                                showGroupsInMainList: false, limit: 10)
        let clips = ((try? state.store.clips(filter)) ?? []).filter { !$0.isGroup }
        guard n >= 1, n <= clips.count else {
            state.message("No clip at position \(n)")
            return
        }
        pasteClipGlobally(clips[n - 1].id)
    }

    /// Group shortcut: once = open Quick Paste in the group; twice quickly = copy the selection into the group.
    private func groupHotkeyPressed(_ id: Int64) {
        let now = Date()
        if let last = groupPressTimes[id], now.timeIntervalSince(last) < 0.5 {
            groupPressTimes[id] = nil
            pendingGroupOpen?.cancel()
            quickSave(intoGroup: id)
            return
        }
        groupPressTimes[id] = now
        pendingGroupOpen?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.groupPressTimes[id] = nil
                self?.quickPaste.show(groupID: id)
            }
        }
        pendingGroupOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Sends ⌘C to the frontmost app and files the resulting clip into `groupID`.
    private func quickSave(intoGroup groupID: Int64) {
        if quickPaste.isVisible { quickPaste.hide(restoreFocus: true) }
        guard monitor.isConnected else {
            state.message("Connect to the clipboard first to save into a group")
            return
        }
        guard paste.isAccessibilityTrusted(prompt: false) else {
            state.message("Enable Accessibility for DittoMac to copy into groups")
            return
        }
        let name = (try? state.store.clip(id: groupID))?.text ?? "group"
        monitor.captureNextClip(intoGroup: groupID, until: Date().addingTimeInterval(3))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.paste.postCommandKey("c")
        }
        state.message("Copying into “\(name)”…")
    }

    /// "Copy and save": ⌘C in the frontmost app, then make sure the clip is saved.
    private func copyAndSave() {
        guard paste.isAccessibilityTrusted(prompt: false) else {
            state.message("Enable Accessibility for DittoMac to send ⌘C")
            return
        }
        paste.postCommandKey("c")
        if !monitor.isConnected {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.monitor.saveCurrentClipboard()
            }
        }
    }

    // MARK: Retention

    /// Debounced (~2 s) retention pass, used after settings changes and newly inserted clips.
    func scheduleRetention() {
        retentionDebounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.applyRetention() }
        retentionDebounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    private func applyRetention() {
        let s = settings
        let maxEntries = s.checkForMaxEntries ? s.maxEntries : nil
        let expireDays = s.checkForExpiredEntries ? s.expiredEntries : nil
        guard maxEntries != nil || expireDays != nil else { return }
        let store = state.store
        DispatchQueue.global(qos: .utility).async {
            let deleted = (try? store.applyRetention(maxEntries: maxEntries, expireDays: expireDays)) ?? 0
            guard deleted > 0 else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AppState.shared?.clipsChanged() }
            }
        }
    }

    // MARK: First run

    private func firstRunChecks() {
        let introKey = "accessibilityIntroShown"
        if !paste.isAccessibilityTrusted(prompt: false) {
            if !settings.defaults.bool(forKey: introKey) {
                settings.defaults.set(true, forKey: introKey)
                showAccessibilityIntro()
                return
            }
        }
        if settings.showStartupMessage {
            let v = settings.hotkey("activate")
            let hint = v != 0 ? "press \(KeyCombo(encoded: v).displayString) to open Quick Paste" : "click the menu-bar icon to open Quick Paste"
            state.message("DittoMac is running — \(hint)")
        }
    }

    func showAccessibilityIntro() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "Allow DittoMac to paste for you"
        a.informativeText = """
        DittoMac needs Accessibility permission to paste the clip you pick straight into the app you were using \
        (it sends ⌘V for you) and to place the popup at your text cursor.

        Without it everything else works: the clip is put on the clipboard and you press ⌘V yourself.

        Click “Open System Settings”, then turn on DittoMac under Privacy & Security › Accessibility.
        """
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.accessibilitySettingsURL)
        }
    }

    // MARK: Main menu (gives ⌘C/⌘V/⌘A etc. to text fields in an accessory app)

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "DittoMac")
        appMenu.addItem(QuickPasteMenuItem("About DittoMac") { [weak self] in self?.state.windows.showAbout() })
        appMenu.addItem(.separator())
        appMenu.addItem(QuickPasteMenuItem("Preferences…", key: ",") { [weak self] in self?.state.windows.showPreferences(tab: nil) })
        appMenu.addItem(QuickPasteMenuItem("Show Quick Paste", key: "") { [weak self] in self?.state.showQuickPaste?(nil) })
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide DittoMac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit DittoMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        let pastePlain = NSMenuItem(title: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(pastePlain)
        edit.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f")
        find.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        edit.addItem(find)
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }
}
