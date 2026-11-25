// StickyNoteWindow.swift — floating desktop notes. A sticky note is an ordinary (usually top-sticky) clip; this window
// shows it as a coloured, resizable note with plain-text editing and autosave. Locked notes show an unlock view
// while the vault is locked and their text is never put in the window.

import AppKit
import DittoCore

// MARK: - Center (open notes, new-note editors, restore at launch)

@MainActor
final class StickyNoteCenter {
    static let shared = StickyNoteCenter()

    private var windows: [Int64: StickyNoteWindowController] = [:]
    private var editors: [ObjectIdentifier: EditorWindowController] = [:]

    var openIDs: [Int64] { Array(windows.keys) }

    /// "New Sticky Note": the clip editor in note mode.
    func newNote(state: AppState) {
        let e = EditorWindowController(state: state, clipID: nil, noteMode: true)
        let key = ObjectIdentifier(e)
        e.onClose = { [weak self] in self?.editors[key] = nil }
        editors[key] = e
        e.show()
    }

    /// Opens (or brings forward) the desktop note for a clip.
    func show(clipID: Int64, state: AppState, activate: Bool) {
        if let w = windows[clipID] {
            w.window?.orderFront(nil)
            if activate { NSApp.activate(ignoringOtherApps: true); w.window?.makeKey() }
            return
        }
        guard let clip = try? state.store.clip(id: clipID), !clip.isGroup else { return }
        let c = StickyNoteWindowController(state: state, clipID: clipID)
        c.onClose = { [weak self] userClosed in
            guard let self else { return }
            self.windows[clipID] = nil
            if userClosed { self.persist(state) }
        }
        windows[clipID] = c
        persist(state)
        c.window?.orderFront(nil)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            c.window?.makeKey()
        }
    }

    /// Reopens the notes that were open when DittoMac last quit (Settings.restoreDesktopNotes).
    func restore(state: AppState) {
        guard state.settings.restoreDesktopNotes else { return }
        for id in state.settings.openDesktopNoteIDs {
            if let c = try? state.store.clip(id: id), !c.isGroup {
                show(clipID: id, state: state, activate: false)
            }
        }
        persist(state)
    }

    private func persist(_ state: AppState) {
        state.settings.openDesktopNoteIDs = windows.keys.sorted()
    }
}

// MARK: - Note window

@MainActor
final class StickyNoteWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let state: AppState
    let clipID: Int64
    /// `true` when the user closed the note (as opposed to the clip being deleted).
    var onClose: ((_ userClosed: Bool) -> Void)?

    private let root = StickyNoteRootView()
    private let bar = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let colorButton = NSButton()
    private let pinButton = NSButton()
    private let lockButton = NSButton()
    private let scroll = NSScrollView()
    let textView = NSTextView()
    private let lockedView = NSStackView()
    private let unlockButton = NSButton(title: "Unlock…", target: nil, action: nil)

    private var clip: Clip?
    private var dirty = false
    private var saveWork: DispatchWorkItem?
    /// Edits that couldn't be written because the vault locked first; written after the next unlock.
    private var pendingText: String?
    /// A user-given note title (description differs from the text's first line) is kept when the text changes.
    private var preservedTitle: String?
    private var deletedClose = false
    private var frameWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    private var settings: DittoCore.Settings { state.settings }
    private var vaultUnlocked: Bool { state.vault?.isUnlocked ?? false }
    var isContentHidden: Bool { (clip?.isLocked ?? false) && !vaultUnlocked }

    static let defaultSize = NSSize(width: 270, height: 250)
    static let saveDelay: TimeInterval = 0.6

    init(state: AppState, clipID: Int64) {
        self.state = state
        self.clipID = clipID
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 180, height: 140)
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.collectionBehavior = [.managed, .fullScreenAuxiliary]
        w.hasShadow = true
        super.init(window: w)
        w.delegate = self
        buildUI()
        reloadFromStore(force: true)
        placeWindow()
        applyFloating()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .dittoVaultChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.vaultChanged() }
        })
        observers.append(nc.addObserver(forName: .dittoClipsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFromStore(force: false) }
        })
        root.onAppearanceChange = { [weak self] in self?.applyColors() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: UI

    private func buildUI() {
        guard let w = window else { return }
        root.wantsLayer = true
        w.contentView = root

        bar.wantsLayer = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        for (b, sym, tip, act) in [(colorButton, "paintpalette", "Note colour", #selector(colorClicked(_:))),
                                   (pinButton, "pin", "Keep on top of other windows", #selector(pinClicked(_:))),
                                   (lockButton, "lock", "Lock this note", #selector(lockClicked(_:)))] {
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)?.withSymbolConfiguration(cfg)
            b.isBordered = false
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            b.target = self
            b.action = act
            b.translatesAutoresizingMaskIntoConstraints = false
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        let buttons = NSStackView(views: [titleLabel, colorButton, pinButton, lockButton])
        buttons.spacing = 9
        buttons.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(buttons)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        // Locked view: icon, label, unlock button. The note text is never placed in the window while locked.
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)) ?? NSImage())
        let label = NSTextField(labelWithString: "Locked note")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let hint = NSTextField(labelWithString: "Unlock to read or edit it.")
        hint.font = .systemFont(ofSize: 11)
        unlockButton.target = self
        unlockButton.action = #selector(unlockClicked(_:))
        unlockButton.bezelStyle = .rounded
        unlockButton.controlSize = .regular
        lockedView.orientation = .vertical
        lockedView.alignment = .centerX
        lockedView.spacing = 6
        [icon, label, hint, unlockButton].forEach { lockedView.addArrangedSubview($0) }
        lockedView.setCustomSpacing(12, after: hint)
        lockedView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(lockedView)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28),
            buttons.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 72),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),
            lockedView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            lockedView.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: 10),
            lockedView.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 12),
        ])
    }

    private var noteColor: NoteColor { settings.noteColor(for: clipID) ?? .yellow }

    func applyColors() {
        guard let w = window else { return }
        let dark = AppearanceManager.isDark(w.effectiveAppearance)
        let c = noteColor
        let paper = AppearanceManager.color(c.paper(dark: dark))
        let barColor = AppearanceManager.color(c.bar(dark: dark))
        let text = AppearanceManager.color(c.text(dark: dark))
        w.backgroundColor = paper
        root.layer?.backgroundColor = paper.cgColor
        bar.layer?.backgroundColor = barColor.cgColor
        textView.textColor = text
        textView.insertionPointColor = text
        titleLabel.textColor = text.withAlphaComponent(0.75)
        for b in [colorButton, pinButton, lockButton] { b.contentTintColor = text.withAlphaComponent(0.7) }
        for v in lockedView.arrangedSubviews {
            (v as? NSTextField)?.textColor = text.withAlphaComponent(0.8)
            (v as? NSImageView)?.contentTintColor = text.withAlphaComponent(0.7)
        }
    }

    private func placeWindow() {
        guard let w = window else { return }
        if let s = settings.noteFrame(for: clipID) {
            let r = NSRectFromString(s)
            // The title bar (top 40 pt) must be on a screen, otherwise the note can't be dragged back (display unplugged).
            if r.width >= w.minSize.width, r.height >= w.minSize.height, r.width < 4000, r.height < 4000,
               ScreenshotGeometry.isTitleBarReachable(r, visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
                w.setFrame(r, display: false)
                return
            }
        }
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let n = CGFloat(StickyNoteCenter.shared.openIDs.count % 8)
        let origin = NSPoint(x: vf.maxX - Self.defaultSize.width - 40 - n * 24, y: vf.maxY - Self.defaultSize.height - 40 - n * 24)
        w.setFrame(NSRect(origin: origin, size: Self.defaultSize), display: false)
    }

    private func applyFloating() {
        let floats = settings.noteFloats(clipID)
        window?.level = floats ? .floating : .normal
        let sym = floats ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: sym, accessibilityDescription: "Keep on top")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        pinButton.toolTip = floats ? "Floating above other windows (click to stop)" : "Keep on top of other windows"
    }

    private func updateLockUI() {
        let hidden = isContentHidden
        scroll.isHidden = hidden
        lockedView.isHidden = !hidden
        colorButton.isEnabled = true
        let locked = clip?.isLocked ?? false
        let sym = !locked ? "lock.open" : (hidden ? "lock.fill" : "lock.open.fill")
        lockButton.image = NSImage(systemSymbolName: sym, accessibilityDescription: "Lock")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        lockButton.toolTip = !locked ? "Lock this note (encrypt it and protect it from deletion)"
            : (hidden ? "Unlock notes" : "Locked note — lock notes now or remove the lock")
        let title = hidden ? ClipStore.lockedPlaceholder : (clip.map { Self.oneLine($0.text) } ?? "Note")
        titleLabel.stringValue = (locked ? "🔒 " : "") + title
        window?.title = hidden ? "Locked note" : title
    }

    private static func oneLine(_ s: String) -> String {
        let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return String(first.trimmingCharacters(in: .whitespaces).prefix(60))
    }

    private func derivedDescription(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(settings.descTextSize))
    }

    // MARK: Data

    /// Re-reads the clip. Closes the window when the clip was deleted; leaves unsaved edits alone.
    func reloadFromStore(force: Bool) {
        guard let c = try? state.store.clip(id: clipID) else {
            deletedClose = true
            settings.forgetNote(clipID)
            window?.close()
            return
        }
        clip = c
        applyColors()
        if isContentHidden {
            textView.string = ""          // never keep decrypted text in a locked note window
            textView.undoManager?.removeAllActions()
            updateLockUI()
            return
        }
        if let p = pendingText, (try? writeText(p)) != nil { pendingText = nil }
        let text = PasteContent.text(clipID: clipID, store: state.store) ?? c.text
        if force || (!dirty && text != textView.string) {
            textView.string = text
            dirty = false
        }
        preservedTitle = c.text != derivedDescription(text) && !c.text.isEmpty ? c.text : nil
        updateLockUI()
    }

    private func vaultChanged() {
        if isContentHidden, dirty { flushSave() }
        reloadFromStore(force: false)
    }

    func textDidChange(_ notification: Notification) {
        dirty = true
        if clip?.isLocked == true { (state.vault as? VaultService)?.noteActivity() }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flushSave() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// Writes the text now (re-encrypted by the store when the note is locked).
    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        guard dirty else { return }
        let text = textView.string
        do {
            try writeText(text)
            dirty = false
        } catch ClipStoreError.locked {
            pendingText = text
            dirty = false
        } catch {
            state.message("Couldn’t save the note: \(error.localizedDescription)")
        }
    }

    private func writeText(_ text: String) throws {
        var formats = [ClipFormat(type: ClipUTI.plainText, data: Data(text.utf8))]
        // Keep non-text formats (images, files); drop stale rich-text copies of the old text.
        let textTypes: Set<String> = [ClipUTI.plainText, ClipUTI.rtf, ClipUTI.html, "public.utf16-plain-text",
                                      ClipUTI.rtfd, ClipUTI.webArchive]
        if let old = try? state.store.formats(clipID: clipID) {
            formats.append(contentsOf: old.filter { !textTypes.contains($0.type) }.map { ClipFormat(type: $0.type, data: $0.data) })
        }
        let desc = preservedTitle ?? derivedDescription(text)
        try state.store.replaceFormats(clipID: clipID, formats: formats, description: desc.isEmpty ? " " : desc)
        if clip?.isLocked == true { (state.vault as? VaultService)?.noteActivity() }
        ClipThumbnailCache.shared.invalidate(clipID)
        state.clipsChanged()
    }

    // MARK: Actions

    @objc private func colorClicked(_ sender: NSButton) {
        let m = NSMenu()
        for c in NoteColor.allCases {
            let it = QuickPasteMenuItem(c.title) { [weak self] in
                guard let self else { return }
                self.settings.setNoteColor(c, for: self.clipID)
                self.applyColors()
                self.state.clipsChanged()
            }
            it.state = c == noteColor ? .on : .off
            let dot = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                AppearanceManager.color(c.bar(dark: false)).setFill()
                NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
                NSColor.black.withAlphaComponent(0.2).setStroke()
                NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).stroke()
                return true
            }
            it.image = dot
            m.addItem(it)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func pinClicked(_ sender: NSButton) {
        settings.setNoteFloats(!settings.noteFloats(clipID), for: clipID)
        applyFloating()
    }

    @objc private func lockClicked(_ sender: NSButton) {
        guard let vault = state.vault else { return }
        guard let c = clip else { return }
        if !c.isLocked {
            flushSave()
            vault.lock(clipIDs: [clipID]) { [weak self] _ in self?.reloadFromStore(force: true) }
            return
        }
        if isContentHidden {
            unlockClicked(sender)
            return
        }
        let m = NSMenu()
        m.addItem(QuickPasteMenuItem("Lock Notes Now") { [weak self] in
            self?.flushSave()
            vault.lockNow()
        })
        m.addItem(QuickPasteMenuItem("Remove Lock…") { [weak self] in
            guard let self else { return }
            self.flushSave()
            vault.removeLock(clipIDs: [self.clipID]) { [weak self] _ in self?.reloadFromStore(force: true) }
        })
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func unlockClicked(_ sender: Any?) {
        state.vault?.requestUnlock(reason: "open a locked note") { [weak self] ok in
            if ok { self?.reloadFromStore(force: true) }
        }
    }

    // MARK: Window

    private func saveFrame() {
        guard let f = window?.frame else { return }
        settings.setNoteFrame(NSStringFromRect(f), for: clipID)
    }

    /// Frame writes are debounced: a drag fires `windowDidMove` continuously.
    private func scheduleFrameSave() {
        frameWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveFrame() } }
        frameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    func windowDidEndLiveResize(_ notification: Notification) { scheduleFrameSave() }

    /// Closing a note whose edits are waiting for the vault (it locked first) must not drop them silently.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !deletedClose, dirty { flushSave() }      // a locked vault turns this into `pendingText`
        guard !deletedClose, pendingText != nil else { return true }
        let a = NSAlert()
        a.messageText = "Unlock to save your changes?"
        a.informativeText = "This locked note has changes that couldn’t be saved because the vault is locked."
        a.addButton(withTitle: "Unlock & Save")
        a.addButton(withTitle: "Discard")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            state.vault?.requestUnlock(reason: "save your changes to a locked note") { [weak self] ok in
                guard let self else { return }
                if ok { self.reloadFromStore(force: false) }      // writes the pending text
                if ok, self.pendingText == nil { self.window?.close() }
                else if ok { self.state.message("Couldn’t save the note — your changes are still in the window") }
            }
            return false
        case .alertSecondButtonReturn:
            pendingText = nil
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        frameWork?.cancel(); frameWork = nil
        if !deletedClose { flushSave(); saveFrame() }
        pendingText = nil
        textView.string = ""
        onClose?(!deletedClose)
    }
}

/// Root view of a note; reports light / dark changes so the paper colour follows the appearance.
final class StickyNoteRootView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        MainActor.assumeIsolated { onAppearanceChange?() }
    }
    override var mouseDownCanMoveWindow: Bool { true }
}
