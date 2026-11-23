import AppKit
import DittoCore

/// Built-in clip editor (new or existing clip), rich or plain text.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let state: AppState
    private(set) var clipID: Int64?
    var onClose: (() -> Void)?

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

    init(state: AppState, clipID: Int64?) {
        self.state = state
        self.clipID = clipID
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
    }
    required init?(coder: NSCoder) { fatalError() }

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

        content.addSubview(top); content.addSubview(scroll); content.addSubview(bottom)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
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
        if let id = clipID, let fmts = try? state.store.formats(clipID: id) {
            originalOtherFormats = fmts.filter { ![ClipUTI.plainText, ClipUTI.rtf, ClipUTI.html].contains($0.type) }
            if let d = fmts.first(where: { $0.type == ClipUTI.plainText })?.data { plain = String(decoding: d, as: UTF8.self) }
            if let d = fmts.first(where: { $0.type == ClipUTI.rtf })?.data, d.count <= 10 * 1024 * 1024 {
                originalHadRTF = true
                attributed = NSAttributedString(rtf: d, documentAttributes: nil)
            }
            if plain.isEmpty, let a = attributed { plain = a.string }
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
        window?.title = (clipID == nil ? "New Clip" : "Edit Clip") + (dirty ? " — Edited" : "")
        window?.isDocumentEdited = dirty
    }
    private func updateStatus() {
        statusLabel.stringValue = "\(textView.string.count) characters"
        updateTitle()
    }

    func textDidChange(_ notification: Notification) { dirty = true; updateStatus() }

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
        let desc = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(state.settings.descTextSize))
        return (out, desc)
    }

    private func warn(_ title: String, _ info: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        if let w = window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    @discardableResult
    private func performSave() -> [ClipFormat]? {
        guard !textView.string.isEmpty else { warn("Nothing to save", "The clip is empty."); return nil }
        let (formats, desc) = buildFormats()
        do {
            if let id = clipID {
                try state.store.replaceFormats(clipID: id, formats: formats, description: desc)
                ClipThumbnailCache.shared.invalidate(id)
            } else {
                switch try state.store.addClip(formats: formats, description: desc, sourceApp: "DittoMac") {
                case .inserted(let id), .duplicateBumped(let id): clipID = id
                case .rejected: warn("Clip not saved", "The clip was rejected (size limit or duplicate rules)."); return nil
                }
            }
        } catch {
            if let w = window { NSAlert(error: error).beginSheetModal(for: w) }
            return nil
        }
        originalHadRTF = formats.contains { $0.type == ClipUTI.rtf }
        dirty = false
        updateStatus()
        state.clipsChanged()
        return formats
    }

    @objc private func save() { performSave() }
    @objc private func saveCloseClipboard() {
        guard let f = performSave() else { return }
        state.paste?.writeToPasteboard(f)
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
    func windowWillClose(_ notification: Notification) { onClose?() }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
    }
}
