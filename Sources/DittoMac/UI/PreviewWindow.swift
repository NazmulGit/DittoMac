import AppKit
import DittoCore

/// Panel subclass that can become key and routes plain N / P / W / Esc keys.
@MainActor
private final class PreviewPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let h = keyHandler, h(event) { return }
        super.sendEvent(event)
    }
}

/// The "description window": shows a clip as image / RTF / HTML / plain text.
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    enum ViewMode: String { case text = "Text", rtfd = "Rich Text", rtf = "RTF", html = "HTML", image = "Image" }

    /// Navigation context for N / P. The popup sets this to the visible clip ids (in order).
    static var clipIDs: [Int64] = []
    static func setNavigationContext(_ ids: [Int64]) { clipIDs = ids }

    static let maxHTMLBytes = 2 * 1024 * 1024
    static let maxRTFBytes = 10 * 1024 * 1024
    static let maxRTFDBytes = 64 * 1024 * 1024
    static let maxTextChars = 5_000_000

    private let state: AppState
    private(set) var clipID: Int64 = 0
    var onClose: (() -> Void)?

    private let headerLabel = NSTextField(wrappingLabelWithString: "")
    private let viewAsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let wrapCheck = NSButton(checkboxWithTitle: "Wrap text", target: nil, action: nil)
    private let monoCheck = NSButton(checkboxWithTitle: "Monospaced", target: nil, action: nil)
    private let topCheck = NSButton(checkboxWithTitle: "Always on top", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private let imageView = NSImageView()
    private var formats: [ClipFormat] = []
    private var available: [ViewMode] = []
    private var mode: ViewMode = .text
    private var observer: NSObjectProtocol?
    private var vaultObserver: NSObjectProtocol?

    init(state: AppState) {
        self.state = state
        let p = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .utilityWindow],
                             backing: .buffered, defer: false)
        p.title = "Clip Description"
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = false
        p.minSize = NSSize(width: 320, height: 220)
        p.setFrameAutosaveName("DittoMacPreviewWindow")
        super.init(window: p)
        p.delegate = self
        p.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
        buildUI()
        observer = NotificationCenter.default.addObserver(forName: .dittoClipsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfVisible() }
        }
        vaultObserver = NotificationCenter.default.addObserver(forName: .dittoVaultChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeIfLockedNote() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        if let o = vaultObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// When the vault locks, a preview of a locked note must not keep showing its text: blank it and close.
    private func closeIfLockedNote() {
        guard clipID != 0, state.vault?.isUnlocked != true,
              ((try? state.store.clip(id: clipID)) ?? nil)?.isLocked == true else { return }
        blankContent()
        window?.close()
    }

    private func blankContent() {
        formats = []
        textView.string = ""
        imageView.image = nil
        headerLabel.stringValue = ""
        window?.title = "Clip Description"
    }

    // MARK: UI
    private func buildUI() {
        guard let content = window?.contentView else { return }
        headerLabel.font = .systemFont(ofSize: 11)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.isSelectable = true
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        viewAsPopup.target = self; viewAsPopup.action = #selector(viewAsChanged)
        let viewLabel = NSTextField(labelWithString: "View as:")
        wrapCheck.target = self; wrapCheck.action = #selector(wrapToggled)
        monoCheck.target = self; monoCheck.action = #selector(monoToggled)
        topCheck.target = self; topCheck.action = #selector(topToggled)
        wrapCheck.state = state.settings.wrapDescriptionText ? .on : .off
        let bar = NSStackView(views: [viewLabel, viewAsPopup, wrapCheck, monoCheck, topCheck])
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        imageView.imageScaling = .scaleNone
        imageView.setAccessibilityLabel("Clip image")

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(headerLabel); content.addSubview(bar); content.addSubview(scroll)
        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            headerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            headerLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            bar.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    // MARK: showing
    func show(clipID: Int64) {
        self.clipID = clipID
        load()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshIfVisible() {
        guard window?.isVisible == true, clipID != 0 else { return }
        if (try? state.store.clip(id: clipID)) ?? nil == nil { window?.close(); return }
        load(keepMode: true)
    }

    private func load(keepMode: Bool = false) {
        guard let clip = (try? state.store.clip(id: clipID)) ?? nil else {
            headerLabel.stringValue = "Clip not found."
            textView.string = ""
            return
        }
        formats = (try? state.store.formats(clipID: clipID)) ?? []
        func has(_ t: String) -> Bool { formats.contains { $0.type == t } }
        var modes: [ViewMode] = []
        let summary = ClipFormatSummary(types: formats.map(\.type))
        if summary.hasImage { modes.append(.image) }
        if summary.hasRTFD { modes.append(.rtfd) }
        if has(ClipUTI.rtf) { modes.append(.rtf) }
        if has(ClipUTI.html) || has(ClipUTI.webArchive) { modes.append(.html) }
        modes.append(.text)
        available = modes
        viewAsPopup.removeAllItems()
        for m in modes { viewAsPopup.addItem(withTitle: m.rawValue) }
        if !(keepMode && modes.contains(mode)) { mode = modes[0] }
        viewAsPopup.selectItem(withTitle: mode.rawValue)
        viewAsPopup.isEnabled = modes.count > 1
        headerLabel.stringValue = headerText(for: clip)
        window?.title = "Clip Description — " + String(clip.text.prefix(40)).replacingOccurrences(of: "\n", with: " ")
        topCheck.state = (window?.level == .floating) ? .on : .off
        render()
    }

    private func headerText(for c: Clip) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .medium
        var parts = ["Added \(df.string(from: c.date))", "Last Used \(df.string(from: c.lastPasteDate))"]
        if c.dontAutoDelete { parts.append("Never Auto Delete") }
        if !c.quickPasteText.isEmpty { parts.append("Quick Paste: \(c.quickPasteText)") }
        if c.shortcut != 0 { parts.append("Shortcut \(KeyCombo(encoded: c.shortcut).displayString)" + (c.globalShortcut ? " (Global)" : "")) }
        if c.isSticky { parts.append("Sticky") }
        if c.parentID != -1, let g = (try? state.store.clip(id: c.parentID)) ?? nil { parts.append("In group \(g.text)") }
        let names = ClipUTI.displayNames(formats.map(\.type))
        return parts.joined(separator: " | ") + (names.isEmpty ? "" : "\nFormats: " + names.joined(separator: ", "))
    }

    // MARK: rendering
    private func data(_ type: String) -> Data? { formats.first { $0.type == type }?.data }

    private func plainString() -> String {
        if let d = data(ClipUTI.plainText) { return String(decoding: d.prefix(Self.maxTextChars * 4), as: UTF8.self).prefix(Self.maxTextChars).description }
        if let d = data(ClipUTI.fileURL) { return String(decoding: d, as: UTF8.self) }
        if let a = rtfAttributed() { return a.string }
        if let a = rtfdAttributed() { return a.string.replacingOccurrences(of: "\u{FFFC}", with: "") }
        if let a = htmlAttributed() { return a.string }
        if formats.isEmpty { return "(no data)" }
        return formats.map { "\($0.type) — \(ByteCountFormatter.string(fromByteCount: Int64($0.data.count), countStyle: .file))" }.joined(separator: "\n")
    }

    private func rtfAttributed() -> NSAttributedString? {
        guard let d = data(ClipUTI.rtf) else { return nil }
        return SafeRichText.rtf(d, maxBytes: Self.maxRTFBytes)
    }

    /// RTFD with local image attachments (sanitised: see SafeRichText.rtfd).
    private func rtfdAttributed() -> NSAttributedString? {
        guard let d = data(ClipUTI.flatRTFD) ?? data(ClipUTI.rtfd) else { return nil }
        return SafeRichText.rtfd(d, maxBytes: Self.maxRTFDBytes)
    }

    /// Stored HTML, else a web archive's main HTML — always through the sanitiser (sub-resources never loaded;
    /// the web archive itself is never handed to WebKit).
    private func htmlAttributed() -> NSAttributedString? {
        if let d = data(ClipUTI.html) { return SafeRichText.html(d, maxBytes: Self.maxHTMLBytes) }
        guard let d = data(ClipUTI.webArchive), let html = WebArchive.mainHTML(d) else { return nil }
        return SafeRichText.html(Data(html.utf8), maxBytes: Self.maxHTMLBytes)
    }

    /// Full decode only for images under `ImageProbe.maxDecodePixels`; bigger ones are shown downsampled.
    private func previewImage(_ d: Data) -> NSImage? {
        if ImageProbe.isSafeToDecode(d) { return NSImage(data: d) }
        guard let cg = ImageProbe.thumbnail(d, maxPixelSize: 8192) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func render() {
        let monoOn = monoCheck.state == .on
        switch mode {
        case .image:
            let d = PasteContent.imageData(from: formats)
            guard let d, let img = previewImage(d) else { mode = .text; viewAsPopup.selectItem(withTitle: "Text"); render(); return }
            monoCheck.isHidden = true; wrapCheck.isHidden = true
            if let rep = img.representations.first, rep.pixelsWide > 0 {
                img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
            imageView.image = img
            imageView.frame = NSRect(origin: .zero, size: img.size)
            scroll.allowsMagnification = true
            scroll.minMagnification = 0.02
            scroll.maxMagnification = 32
            scroll.documentView = imageView
            scroll.layoutSubtreeIfNeeded()
            zoomToFit()
        case .rtfd, .rtf, .html, .text:
            monoCheck.isHidden = mode != .text; wrapCheck.isHidden = false
            scroll.allowsMagnification = false
            scroll.magnification = 1
            scroll.documentView = textView
            if mode == .rtfd, let a = rtfdAttributed() {
                textView.textStorage?.setAttributedString(a)
            } else if mode == .rtf, let a = rtfAttributed() {
                textView.textStorage?.setAttributedString(a)
            } else if mode == .html, let a = htmlAttributed() {
                textView.textStorage?.setAttributedString(a)
            } else {
                let font = monoOn ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) : NSFont.systemFont(ofSize: 13)
                let a = NSAttributedString(string: plainString(), attributes: [.font: font, .foregroundColor: NSColor.textColor])
                textView.textStorage?.setAttributedString(a)
            }
            applyWrap()
        }
    }

    private func applyWrap() {
        let wrap = wrapCheck.state == .on
        let width = scroll.contentSize.width
        textView.isHorizontallyResizable = !wrap
        textView.textContainer?.widthTracksTextView = wrap
        textView.textContainer?.containerSize = NSSize(width: wrap ? max(width, 50) : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = wrap ? [.width] : []
        if wrap { textView.setFrameSize(NSSize(width: width, height: textView.frame.height)) }
        textView.sizeToFit()
    }

    private func zoomToFit() {
        guard let img = imageView.image, img.size.width > 0, img.size.height > 0 else { return }
        let vs = scroll.contentSize
        let m = min(1, min(vs.width / img.size.width, vs.height / img.size.height))
        scroll.magnification = max(scroll.minMagnification, m)
    }

    private func zoom(by factor: CGFloat) {
        guard mode == .image else { return }
        scroll.magnification = min(scroll.maxMagnification, max(scroll.minMagnification, scroll.magnification * factor))
    }

    // MARK: actions
    @objc private func viewAsChanged() {
        guard let t = viewAsPopup.titleOfSelectedItem, let m = ViewMode(rawValue: t) else { return }
        mode = m; render()
    }
    @objc private func wrapToggled() {
        state.settings.wrapDescriptionText = wrapCheck.state == .on
        applyWrap()
        NotificationCenter.default.post(name: .dittoSettingsChanged, object: nil)
    }
    @objc private func monoToggled() { render() }
    @objc private func topToggled() {
        window?.level = topCheck.state == .on ? .floating : .normal
    }

    func toggleWrap() { wrapCheck.state = wrapCheck.state == .on ? .off : .on; wrapToggled() }

    private func navigate(_ delta: Int) {
        let ids = Self.clipIDs
        guard let i = ids.firstIndex(of: clipID) else { return }
        let j = i + delta
        guard ids.indices.contains(j) else { NSSound.beep(); return }
        clipID = ids[j]
        load()
    }

    private func isTypingInField() -> Bool {
        guard let fr = window?.firstResponder else { return false }
        if let tv = fr as? NSTextView { return tv.isFieldEditor || tv.isEditable }
        return fr is NSTextField
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command {
            switch ch {
            case "=", "+": zoom(by: 1.25); return mode == .image
            case "-": zoom(by: 0.8); return mode == .image
            case "0":
                if mode == .image { zoomToFit(); return true }
                return false
            case "f":
                let item = NSMenuItem(); item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
                if mode != .image { window?.makeFirstResponder(textView); textView.performFindPanelAction(item); return true }
                return false
            case "w": window?.close(); return true
            default: return false
            }
        }
        if e.keyCode == 0x35 && mods.isEmpty {
            if isTypingInField() { return false }       // let the find bar consume Esc first
            window?.close(); return true
        }
        guard mods.isEmpty, !isTypingInField() else { return false }
        switch ch {
        case "n": navigate(1); return true
        case "p": navigate(-1); return true
        case "w": toggleWrap(); return true
        default: return false
        }
    }

    func windowDidResize(_ notification: Notification) { if mode != .image, wrapCheck.state == .on { applyWrap() } }
    func windowWillClose(_ notification: Notification) {
        blankContent()
        onClose?()
    }
}
