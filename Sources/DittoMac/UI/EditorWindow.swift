import AppKit
import DittoCore

/// Built-in clip editor (new or existing clip), rich or plain text. In note mode ("New Sticky Note") it also offers
/// an optional title, "Pin to top", "Lock this note", "Show on desktop" and a note colour.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let state: AppState
    private(set) var clipID: Int64?
    var onClose: (() -> Void)?
    let noteMode: Bool

    // Note mode.
    private let titleField = NSTextField()
    private let pinCheck = NSButton(checkboxWithTitle: "Pin to top", target: nil, action: nil)
    private let lockCheck = NSButton(checkboxWithTitle: "Lock this note", target: nil, action: nil)
    private let desktopCheck = NSButton(checkboxWithTitle: "Show on desktop", target: nil, action: nil)
    private let colorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// A note title kept as the description (instead of the text's first line) when saving.
    private var preservedTitle: String?
    private var isLockedClip = false
    /// Unsaved text (and note title) of a locked note, moved out of the window while the vault is locked.
    private var hiddenForLock: (text: NSAttributedString, title: String)?
    private var vaultObserver: NSObjectProtocol?

    private let textView = NSTextView()
    private let scroll = NSScrollView()
    private let wrapCheck = NSButton(checkboxWithTitle: "Wrap", target: nil, action: nil)
    private let richPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")
    private let sizeValue = NSTextField(labelWithString: "")
    private var dirty = false
    private var originalOtherFormats: [ClipFormat] = []
    private var originalHadRTF = false
    private var baseFont: NSFont
    private var isRich: Bool { richPopup.indexOfSelectedItem == 0 }

    init(state: AppState, clipID: Int64?, noteMode: Bool = false) {
        self.state = state
        self.clipID = clipID
        self.noteMode = noteMode && clipID == nil
        self.baseFont = NSFont.monospacedSystemFont(ofSize: CGFloat(state.settings.editorFontSize), weight: .regular)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 420, height: 260)
        super.init(window: w)
        w.delegate = self
        buildUI()
        loadContent(forcePlain: NSEvent.modifierFlags.contains([.shift, .option]))
        w.center()
        updateTitle()
        vaultObserver = NotificationCenter.default.addObserver(forName: .dittoVaultChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.vaultChanged() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let o = vaultObserver { NotificationCenter.default.removeObserver(o) } }

    private var vaultUnlocked: Bool { state.vault?.isUnlocked ?? false }

    /// A locked note's text never stays on screen once the vault locks: without unsaved changes the editor closes;
    /// with unsaved changes the text is moved out of the window (kept in memory) until the next unlock.
    private func vaultChanged() {
        guard isLockedClip else { return }
        if !vaultUnlocked {
            guard hiddenForLock == nil else { return }
            if !dirty { window?.close(); return }
            hiddenForLock = (textView.textStorage.map { NSAttributedString(attributedString: $0) } ?? NSAttributedString(), titleField.stringValue)
            textView.undoManager?.removeAllActions()
            textView.string = ""
            titleField.stringValue = ""
            textView.isEditable = false
            titleField.isEditable = false
            statusLabel.stringValue = "Locked — unlock to continue editing (unsaved changes are kept)"
            window?.title = "🔒 " + ClipStore.lockedPlaceholder
        } else if let h = hiddenForLock {
            hiddenForLock = nil
            textView.textStorage?.setAttributedString(h.text)
            titleField.stringValue = h.title
            textView.isEditable = true
            titleField.isEditable = true
            updateStatus()
        }
    }

    // MARK: UI
    private func buildUI() {
        guard let content = window?.contentView else { return }
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.usesRuler = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        richPopup.addItems(withTitles: ["Rich text", "Plain text"])
        richPopup.target = self; richPopup.action = #selector(formatChanged)
        wrapCheck.target = self; wrapCheck.action = #selector(wrapToggled)
        wrapCheck.state = state.settings.editorWordWrap ? .on : .off
        let fontBtn = NSButton(title: "Font…", target: self, action: #selector(showFonts))
        let rulerBtn = NSButton(title: "Ruler", target: self, action: #selector(toggleRuler))
        let sizeLabel = NSTextField(labelWithString: "Size:")
        let stepper = NSStepper()
        stepper.minValue = 6; stepper.maxValue = 72; stepper.increment = 1
        stepper.doubleValue = state.settings.editorFontSize
        stepper.target = self; stepper.action = #selector(sizeChanged(_:))
        sizeValue.stringValue = "\(Int(state.settings.editorFontSize))"
        let top = NSStackView(views: [richPopup, fontBtn, rulerBtn, sizeLabel, sizeValue, stepper, wrapCheck])
        top.spacing = 8
        top.translatesAutoresizingMaskIntoConstraints = false

        // Note options (New Sticky Note).
        let noteRow = NSStackView()
        noteRow.spacing = 10
        noteRow.translatesAutoresizingMaskIntoConstraints = false
        noteRow.isHidden = !noteMode
        if noteMode {
            titleField.placeholderString = "Title (optional)"
            titleField.font = .systemFont(ofSize: 13, weight: .semibold)
            titleField.translatesAutoresizingMaskIntoConstraints = false
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
            titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            pinCheck.state = .on
            pinCheck.toolTip = "Keep the note at the top of the clip list (top sticky)"
            lockCheck.state = .off
            lockCheck.toolTip = "Encrypt the note and protect it from deletion (Touch ID / Mac password or a DittoMac password)"
            desktopCheck.state = .on
            desktopCheck.toolTip = "Also open it as a floating desktop note"
            for c in NoteColor.allCases {
                colorPopup.addItem(withTitle: c.title)
                colorPopup.lastItem?.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
                    AppearanceManager.color(c.bar(dark: false)).setFill()
                    NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
                    return true
                }
            }
            colorPopup.toolTip = "Note colour"
            [titleField, colorPopup, pinCheck, lockCheck, desktopCheck].forEach { noteRow.addArrangedSubview($0) }
        }

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "s"; save.keyEquivalentModifierMask = .command
        let saveClose = NSButton(title: "Save, Close & Put on Clipboard", target: self, action: #selector(saveCloseClipboard))
        let close = NSButton(title: "Close", target: self, action: #selector(closeTapped))
        close.keyEquivalent = "w"; close.keyEquivalentModifierMask = .command
        let spacer = NSView()
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        let bottom = NSStackView(views: [statusLabel, spacer, close, saveClose, save])
        bottom.spacing = 8
        bottom.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(top); content.addSubview(noteRow); content.addSubview(scroll); content.addSubview(bottom)
        NSLayoutConstraint.activate([
            noteRow.topAnchor.constraint(equalTo: content.topAnchor, constant: noteMode ? 10 : 0),
            noteRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            noteRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            top.topAnchor.constraint(equalTo: noteMode ? noteRow.bottomAnchor : content.topAnchor, constant: 10),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            top.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    // MARK: content
    private func loadContent(forcePlain: Bool) {
        var attributed: NSAttributedString?
        var plain = ""
        if let id = clipID, let c = try? state.store.clip(id: id) { isLockedClip = c.isLocked }
        if let id = clipID, let fmts = try? state.store.formats(clipID: id) {
            originalOtherFormats = fmts.filter { ![ClipUTI.plainText, ClipUTI.rtf, ClipUTI.html].contains($0.type) }
            if let d = fmts.first(where: { $0.type == ClipUTI.plainText })?.data { plain = String(decoding: d, as: UTF8.self) }
            if let d = fmts.first(where: { $0.type == ClipUTI.rtf })?.data, d.count <= 10 * 1024 * 1024 {
                originalHadRTF = true
                attributed = NSAttributedString(rtf: d, documentAttributes: nil)
            }
            if plain.isEmpty, let a = attributed { plain = a.string }
            // Keep a sticky note's title (its description differs from the text's first line).
            if let c = try? state.store.clip(id: id), c.sourceApp == StickyNoteMarker.sourceApp, !c.text.isEmpty,
               c.text != String(plain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(state.settings.descTextSize)) {
                preservedTitle = c.text
            }
        }
        if let a = attributed, !forcePlain {
            richPopup.selectItem(at: 0)
            textView.isRichText = true
            textView.textStorage?.setAttributedString(a)
        } else {
            richPopup.selectItem(at: (forcePlain || clipID != nil) ? 1 : 0)
            textView.isRichText = isRich
            applyPlain(plain)
        }
        textView.usesRuler = isRich
        textView.usesFontPanel = isRich
        textView.typingAttributes = [.font: baseFont, .foregroundColor: NSColor.textColor]
        applyWrap()
        dirty = false
        updateStatus()
    }

    private func applyPlain(_ s: String) {
        textView.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: [.font: baseFont, .foregroundColor: NSColor.textColor]))
    }

    private func applyMode() {
        let rich = isRich
        textView.isRichText = rich
        textView.usesRuler = rich
        textView.usesFontPanel = rich
        if !rich { applyPlain(textView.string) }
        textView.typingAttributes = [.font: baseFont, .foregroundColor: NSColor.textColor]
    }

    private func applyWrap() {
        let wrap = wrapCheck.state == .on
        let width = scroll.contentSize.width
        textView.isHorizontallyResizable = !wrap
        textView.textContainer?.widthTracksTextView = wrap
        textView.textContainer?.containerSize = NSSize(width: wrap ? max(width, 50) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = wrap ? [.width] : []
        if wrap { textView.setFrameSize(NSSize(width: width, height: textView.frame.height)) }
    }

    private func updateTitle() {
        let base = noteMode ? (clipID == nil ? "New Sticky Note" : "Edit Sticky Note") : (clipID == nil ? "New Clip" : "Edit Clip")
        window?.title = (isLockedClip ? "🔒 " : "") + base + (dirty ? " — Edited" : "")
        window?.isDocumentEdited = dirty
    }
    private func updateStatus() {
        statusLabel.stringValue = "\(textView.string.count) characters"
        updateTitle()
    }

    func textDidChange(_ notification: Notification) {
        dirty = true
        updateStatus()
        if isLockedClip { (state.vault as? VaultService)?.noteActivity() }
    }

    /// Clip RTF can carry HYPERLINK fields to file:// or custom schemes; only open http(s)/mailto.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if SafeRichText.isSafeLinkValue(link) { return false }   // default handling opens it
        NSSound.beep()
        return true                                              // handled: swallow unsafe link
    }

    // MARK: actions
    @objc private func formatChanged() {
        if !isRich {
            let alert = NSAlert()
            alert.messageText = "Convert to plain text?"
            alert.informativeText = "Formatting will be discarded when you switch to plain text."
            alert.addButton(withTitle: "Convert"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { richPopup.selectItem(at: 0); return }
        }
        applyMode(); dirty = true; updateStatus()
    }
    @objc private func wrapToggled() {
        state.settings.editorWordWrap = wrapCheck.state == .on
        applyWrap()
    }
    @objc private func showFonts() { if isRich { window?.makeFirstResponder(textView); NSFontManager.shared.orderFrontFontPanel(nil) } }
    @objc private func toggleRuler() { if isRich { textView.toggleRuler(nil) } }
    @objc private func sizeChanged(_ s: NSStepper) {
        state.settings.editorFontSize = s.doubleValue
        sizeValue.stringValue = "\(Int(s.doubleValue))"
        let old = baseFont.pointSize
        baseFont = NSFont.monospacedSystemFont(ofSize: CGFloat(s.doubleValue), weight: .regular)
        guard let ts = textView.textStorage else { return }
        let ratio = CGFloat(s.doubleValue) / max(old, 1)
        ts.beginEditing()
        ts.enumerateAttribute(.font, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            if let f = v as? NSFont {
                ts.addAttribute(.font, value: NSFontManager.shared.convert(f, toSize: max(6, f.pointSize * ratio)), range: r)
            }
        }
        ts.endEditing()
        textView.typingAttributes[.font] = baseFont
    }

    private func hasRichFormatting(_ a: NSAttributedString) -> Bool {
        var rich = false
        let full = NSRange(location: 0, length: a.length)
        let keys: [NSAttributedString.Key] = [.underlineStyle, .strikethroughStyle, .backgroundColor, .link, .superscript, .attachment, .baselineOffset]
        for k in keys {
            a.enumerateAttribute(k, in: full) { v, _, stop in if v != nil { rich = true; stop.pointee = true } }
            if rich { return true }
        }
        let base = baseFont
        a.enumerateAttributes(in: full) { attrs, _, stop in
            if let f = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: f)
                if traits.contains(.boldFontMask) || traits.contains(.italicFontMask) || f.familyName != base.familyName || abs(f.pointSize - base.pointSize) > 0.5 {
                    rich = true; stop.pointee = true
                }
            }
            if let c = attrs[.foregroundColor] as? NSColor, c != NSColor.textColor, c != NSColor.labelColor { rich = true; stop.pointee = true }
        }
        return rich
    }

    /// Builds the format list from the current editor contents.
    private func buildFormats() -> (formats: [ClipFormat], description: String) {
        let text = textView.string
        var out: [ClipFormat] = [ClipFormat(type: ClipUTI.plainText, data: Data(text.utf8))]
        if isRich, let ts = textView.textStorage, ts.length > 0, originalHadRTF || hasRichFormatting(ts) {
            let range = NSRange(location: 0, length: ts.length)
            if let rtf = try? ts.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                out.append(ClipFormat(type: ClipUTI.rtf, data: rtf))
            }
        }
        out.append(contentsOf: originalOtherFormats.map { ClipFormat(type: $0.type, data: $0.data) })
        var desc = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(state.settings.descTextSize))
        if noteMode {
            let t = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { desc = String(t.prefix(200)) }
        } else if let title = preservedTitle {
            desc = title
        }
        return (out, desc)
    }

    private func warn(_ title: String, _ info: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    @discardableResult
    private func performSave() -> [ClipFormat]? {
        if hiddenForLock != nil {
            // The text is out of the window while locked: unlock (restores it via vaultChanged), then save.
            state.vault?.requestUnlock(reason: "save your changes to a locked note") { [weak self] ok in
                if ok, let self, self.hiddenForLock == nil { self.performSave() }
            }
            return nil
        }
        guard !textView.string.isEmpty else { warn("Nothing to save", "The clip is empty."); return nil }
        let (formats, desc) = buildFormats()
        var createdNote: Int64?
        do {
            if let id = clipID {
                try state.store.replaceFormats(clipID: id, formats: formats, description: desc)
                ClipThumbnailCache.shared.invalidate(id)
                if isLockedClip { (state.vault as? VaultService)?.noteActivity() }
            } else if noteMode {
                var opts = ClipStore.AddOptions()
                opts.allowDuplicates = true
                opts.allowBackToBackDuplicates = true
                opts.makeTopSticky = pinCheck.state == .on
                switch try state.store.addClip(formats: formats, description: desc, sourceApp: StickyNoteMarker.sourceApp, options: opts) {
                case .inserted(let id), .duplicateBumped(let id): clipID = id; createdNote = id
                case .rejected: warn("Note not saved", "The note was rejected (size limit)."); return nil
                }
            } else {
                switch try state.store.addClip(formats: formats, description: desc, sourceApp: "DittoMac") {
                case .inserted(let id), .duplicateBumped(let id): clipID = id
                case .rejected: warn("Clip not saved", "The clip was rejected (size limit or duplicate rules)."); return nil
                }
            }
        } catch ClipStoreError.locked {
            // The vault locked while this locked note was open: unlock, then save again.
            state.vault?.requestUnlock(reason: "save your changes to a locked note") { [weak self] ok in
                if ok { self?.performSave() }
            }
            return nil
        } catch {
            if let w = window { NSAlert(error: error).beginSheetModal(for: w) }
            return nil
        }
        originalHadRTF = formats.contains { $0.type == ClipUTI.rtf }
        dirty = false
        if let id = createdNote { finishNewNote(id) }
        updateStatus()
        state.clipsChanged()
        return formats
    }

    /// After the first save of a new sticky note: colour, desktop window, lock.
    private func finishNewNote(_ id: Int64) {
        let color = NoteColor.allCases[max(0, min(colorPopup.indexOfSelectedItem, NoteColor.allCases.count - 1))]
        state.settings.setNoteColor(color, for: id)
        if desktopCheck.state == .on { StickyNoteCenter.shared.show(clipID: id, state: state, activate: false) }
        if lockCheck.state == .on {
            // The note is saved first (plain) and locked right after in one transaction; if locking is cancelled or
            // fails, say so and show the toggle off: the note is NOT locked.
            guard let vault = state.vault else { lockFailed(); return }
            vault.lock(clipIDs: [id]) { [weak self] ok in
                guard let self else { return }
                guard ok else { self.lockFailed(); return }
                self.isLockedClip = true
                self.updateTitle()
            }
        }
        // Options apply to the first save only; later saves edit the same note.
        [pinCheck, lockCheck, desktopCheck, colorPopup].forEach { $0.isEnabled = false }
    }

    private func lockFailed() {
        lockCheck.state = .off
        lockCheck.isEnabled = false
        statusLabel.stringValue = "Saved, not locked"
        state.message("The note was saved but not locked")
        warn("The note was saved but not locked",
             "Locking was cancelled or didn’t complete, so the note is stored unprotected. Use the lock button on its desktop note, or Lock in the clip’s context menu, to lock it.")
    }

    @objc private func save() { performSave() }
    @objc private func saveCloseClipboard() {
        guard let f = performSave() else { return }
        // A locked note's text is marked concealed so other clipboard tools don't record it.
        if isLockedClip, let ps = state.paste as? PasteService { ps.writeToPasteboard(f, concealed: true) }
        else { state.paste?.writeToPasteboard(f) }
        dirty = false
        window?.close()
    }
    @objc private func closeTapped() { window?.performClose(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty else { return true }
        let a = NSAlert()
        a.messageText = "Save changes to this clip?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Discard"); a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: return performSave() != nil
        case .alertSecondButtonReturn: dirty = false; return true
        default: return false
        }
    }
    func windowDidResize(_ notification: Notification) { if wrapCheck.state == .on { applyWrap() } }
    func windowWillClose(_ notification: Notification) {
        hiddenForLock = nil
        textView.string = ""
        onClose?()
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(noteMode ? titleField : textView)
        NSApp.activate(ignoringOtherApps: true)
    }
}
