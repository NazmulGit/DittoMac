// AnnotationToolbar.swift — vertical tool strip: tools, colours, line width, font size, undo/redo/clear.
import AppKit
import DittoCore

// MARK: - Small controls

/// Icon button with a rounded selected-state highlight.
@MainActor
private final class StripButton: NSButton {
    var isOn = false { didSet { if oldValue != isOn { restyle() } } }
    var onSymbolTint: NSColor?
    override var isEnabled: Bool { didSet { restyle() } }

    init(symbol: String, label: String, tooltip: String, target: AnyObject?, action: Selector?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 22))
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 6
        toolTip = tooltip
        setAccessibilityLabel(label)
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        image = (NSImage(systemSymbolName: symbol, accessibilityDescription: label)
                 ?? NSImage(systemSymbolName: "square", accessibilityDescription: label))?.withSymbolConfiguration(cfg)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 32).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isOn ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
        contentTintColor = isOn ? .white : (isEnabled ? .labelColor : .tertiaryLabelColor)
    }
    override func accessibilityValue() -> Any? { isOn ? "selected" : nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
}

/// Round colour swatch.
@MainActor
private final class SwatchButton: NSControl {
    let hex: String
    let swatchColor: NSColor
    var isOn = false { didSet { needsDisplay = true } }
    init(hex: String, name: String, target: AnyObject?, action: Selector?) {
        self.hex = hex
        self.swatchColor = AnnotationCanvas.color(fromHex: hex) ?? .red
        super.init(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        self.target = target
        self.action = action
        toolTip = name
        setAccessibilityLabel("Colour \(name)")
        setAccessibilityRole(.button)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 15).isActive = true
        heightAnchor.constraint(equalToConstant: 15).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        swatchColor.setFill()
        NSBezierPath(ovalIn: r).fill()
        // hairline so white/black stay visible on any background
        NSColor.labelColor.withAlphaComponent(0.28).setStroke()
        let ring = NSBezierPath(ovalIn: r); ring.lineWidth = 0.75; ring.stroke()
        if isOn {
            NSColor.controlAccentColor.setStroke()
            let sel = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75)); sel.lineWidth = 1.5; sel.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }
    override func accessibilityValue() -> Any? { isOn ? "selected" : nil }
}

/// A dot of increasing size standing for a line width.
@MainActor
private final class WidthButton: NSControl {
    let width: CGFloat
    var isOn = false { didSet { needsDisplay = true } }
    init(width: CGFloat, target: AnyObject?, action: Selector?) {
        self.width = width
        super.init(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        self.target = target
        self.action = action
        toolTip = "Line width \(Int(width)) pt"
        setAccessibilityLabel("Line width \(Int(width)) points")
        setAccessibilityRole(.button)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 15).isActive = true
        heightAnchor.constraint(equalToConstant: 15).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let d = min(11, 2 + width * 0.85)
        (isOn ? NSColor.white : NSColor.labelColor).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
    }
    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }
    override func accessibilityValue() -> Any? { isOn ? "selected" : nil }
}

// MARK: - Toolbar

/// Vertical tool strip: tools, colour palette, line width, undo/redo. Sits beside the selection.
@MainActor
final class AnnotationToolbarView: NSView {
    static let stripWidth: CGFloat = 40
    static let presets: [(hex: String, name: String)] = [
        ("#FF3B30", "Red"), ("#FF9500", "Orange"), ("#FFCC00", "Yellow"), ("#34C759", "Green"),
        ("#00C7BE", "Teal"), ("#0A84FF", "Blue"), ("#AF52DE", "Purple"), ("#FF2D92", "Pink"),
        ("#000000", "Black"), ("#FFFFFF", "White"), ("#8E8E93", "Grey"), ("#A2845E", "Brown"),
    ]
    static let widths: [CGFloat] = [1, 2, 3, 5, 8, 12]

    let canvas: AnnotationCanvas
    /// Called when `intrinsicContentSize` changed because the visible option rows changed (tool switch).
    var onSizeChange: (() -> Void)?

    private let effect = NSVisualEffectView()
    private let stack = NSStackView()
    private var toolButtons: [AnnotationTool: StripButton] = [:]
    private var swatches: [SwatchButton] = []
    private var widthButtons: [WidthButton] = []
    private let colorSection = NSStackView()
    private let widthSection = NSStackView()
    private let textSection = NSStackView()
    private let shapeSection = NSStackView()
    private let fontLabel = NSTextField(labelWithString: "18")
    private let fontStepper = NSStepper()
    private let fillButton: StripButton
    private let chipButton: StripButton
    private let undoButton: StripButton
    private let redoButton: StripButton
    private let clearButton: StripButton
    private let moreButton: StripButton
    private var popover: NSPopover?
    private var lastHeight: CGFloat = 0

    init(canvas: AnnotationCanvas) {
        self.canvas = canvas
        fillButton = StripButton(symbol: "square.fill", label: "Fill shapes", tooltip: "Filled shapes (hold ⌥ while drawing to toggle)", target: nil, action: nil)
        chipButton = StripButton(symbol: "textformat.alt", label: "Text background", tooltip: "Contrast background behind text", target: nil, action: nil)
        undoButton = StripButton(symbol: "arrow.uturn.backward", label: "Undo", tooltip: "Undo (⌘Z)", target: nil, action: nil)
        redoButton = StripButton(symbol: "arrow.uturn.forward", label: "Redo", tooltip: "Redo (⇧⌘Z)", target: nil, action: nil)
        clearButton = StripButton(symbol: "trash", label: "Clear all annotations", tooltip: "Clear all annotations", target: nil, action: nil)
        moreButton = StripButton(symbol: "eyedropper.halffull", label: "Custom colour", tooltip: "More colours…", target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.stripWidth, height: 360))
        wire()
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(canvasChanged), name: AnnotationCanvas.stateDidChange, object: canvas)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func wire() {
        for (b, a) in [(fillButton, #selector(toggleFill)), (chipButton, #selector(toggleChip)), (undoButton, #selector(undo)),
                       (redoButton, #selector(redo)), (clearButton, #selector(clearAll)), (moreButton, #selector(showMore))] {
            b.target = self; b.action = a
        }
    }

    // MARK: Layout
    private func build() {
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Annotation tools")
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        NSLayoutConstraint.activate([
            effect.leadingAnchor.constraint(equalTo: leadingAnchor), effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            effect.topAnchor.constraint(equalTo: topAnchor), effect.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
        ])

        for t in AnnotationTool.allCases {
            let b = StripButton(symbol: t.symbolName, label: t.title, tooltip: t.tooltip, target: self, action: #selector(toolClicked(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(t.rawValue)
            toolButtons[t] = b
            stack.addArrangedSubview(b)
        }

        // colours: 2 columns × 6 rows + "more"
        colorSection.orientation = .vertical; colorSection.alignment = .centerX; colorSection.spacing = 3
        var row: [NSView] = []
        for p in Self.presets {
            let s = SwatchButton(hex: p.hex, name: p.name, target: self, action: #selector(swatchClicked(_:)))
            swatches.append(s)
            row.append(s)
            if row.count == 2 { colorSection.addArrangedSubview(hstack(row, spacing: 4)); row = [] }
        }
        colorSection.addArrangedSubview(moreButton)

        // widths: 2 columns × 3 rows
        widthSection.orientation = .vertical; widthSection.alignment = .centerX; widthSection.spacing = 3
        row = []
        for w in Self.widths {
            let b = WidthButton(width: w, target: self, action: #selector(widthClicked(_:)))
            widthButtons.append(b)
            row.append(b)
            if row.count == 2 { widthSection.addArrangedSubview(hstack(row, spacing: 4)); row = [] }
        }

        // text size
        fontStepper.minValue = Double(AnnotationMath.minFontSize); fontStepper.maxValue = 96; fontStepper.increment = 2
        fontStepper.controlSize = .mini
        fontStepper.target = self; fontStepper.action = #selector(fontStep)
        fontStepper.toolTip = "Text / step size"
        fontStepper.setAccessibilityLabel("Font size")
        fontLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        fontLabel.alignment = .right
        fontLabel.setAccessibilityLabel("Font size value")
        textSection.orientation = .vertical; textSection.alignment = .centerX; textSection.spacing = 2
        textSection.addArrangedSubview(hstack([fontLabel, fontStepper], spacing: 2))
        textSection.addArrangedSubview(chipButton)
        shapeSection.orientation = .vertical; shapeSection.alignment = .centerX
        shapeSection.addArrangedSubview(fillButton)

        for v in [separator(), colorSection, separator(), widthSection, shapeSection, textSection, separator(), undoButton, redoButton, clearButton] {
            stack.addArrangedSubview(v)
            if v is NSBox { v.widthAnchor.constraint(equalToConstant: 26).isActive = true }
        }
    }

    private func hstack(_ v: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: v); s.orientation = .horizontal; s.spacing = spacing; s.alignment = .centerY; return s
    }
    private func separator() -> NSBox {
        let b = NSBox(); b.boxType = .separator; return b
    }

    override var intrinsicContentSize: NSSize {
        stack.layoutSubtreeIfNeeded()
        return NSSize(width: Self.stripWidth, height: ceil(stack.fittingSize.height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            effect.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: State
    @objc private func canvasChanged() { refresh() }

    /// Refresh enabled state of undo/redo etc. (call after canvas.onChange).
    func refresh() {
        let t = canvas.tool
        for (tool, b) in toolButtons { b.isOn = tool == t }
        let hex = AnnotationCanvas.hex(of: canvas.color)?.uppercased()
        for s in swatches { s.isOn = s.hex == hex }
        moreButton.isOn = hex != nil && !swatches.contains { $0.isOn }
        for b in widthButtons { b.isOn = abs(b.width - canvas.lineWidth) < 0.01 }
        fontStepper.doubleValue = Double(canvas.fontSize)
        fontLabel.stringValue = "\(Int(canvas.fontSize.rounded()))"
        fillButton.isOn = canvas.fillShapes
        chipButton.isOn = canvas.textChip
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
        clearButton.isEnabled = canvas.hasAnnotations
        undoButton.alphaValue = canvas.canUndo ? 1 : 0.5
        redoButton.alphaValue = canvas.canRedo ? 1 : 0.5
        clearButton.alphaValue = canvas.hasAnnotations ? 1 : 0.5

        // option rows adapt to the tool
        colorSection.isHidden = t == .pixelate || t == .blur
        widthSection.isHidden = !t.usesLineWidth
        shapeSection.isHidden = !(t == .rectangle || t == .ellipse)
        textSection.isHidden = !(t == .text || t == .step)
        chipButton.isHidden = t != .text
        let h = intrinsicContentSize.height
        if abs(h - lastHeight) > 0.5 {
            lastHeight = h
            invalidateIntrinsicContentSize()
            onSizeChange?()
        }
    }

    // MARK: Actions
    @objc private func toolClicked(_ s: NSButton) {
        if let id = s.identifier?.rawValue, let t = AnnotationTool(rawValue: id) { canvas.tool = t }
        window?.makeFirstResponder(canvas)
    }
    @objc private func swatchClicked(_ s: SwatchButton) { canvas.color = s.swatchColor; window?.makeFirstResponder(canvas) }
    @objc private func widthClicked(_ s: WidthButton) { canvas.lineWidth = s.width; window?.makeFirstResponder(canvas) }
    @objc private func fontStep() { canvas.fontSize = CGFloat(fontStepper.doubleValue) }
    @objc private func toggleFill() { canvas.fillShapes.toggle() }
    @objc private func toggleChip() { canvas.textChip.toggle() }
    @objc private func undo() { canvas.undo(); window?.makeFirstResponder(canvas) }
    @objc private func redo() { canvas.redo(); window?.makeFirstResponder(canvas) }
    @objc private func clearAll() { canvas.clearAll(); window?.makeFirstResponder(canvas) }

    /// Extra colours as an in-overlay popover (swatch grid + hex field). `NSColorWell` / `NSColorPanel` would open the
    /// shared colour panel, which sits behind the screen-saver-level capture overlay and could not be reached.
    private static let moreSwatches: [(String, String)] = [
        ("#FF3B30", "Red"), ("#FF9500", "Orange"), ("#FFCC00", "Yellow"), ("#34C759", "Green"), ("#00C7BE", "Teal"), ("#32ADE6", "Sky"),
        ("#007AFF", "Blue"), ("#5856D6", "Indigo"), ("#AF52DE", "Purple"), ("#FF2D55", "Pink"), ("#A2845E", "Brown"), ("#8E8E93", "Gray"),
        ("#FFFFFF", "White"), ("#D1D1D6", "Light gray"), ("#636366", "Dark gray"), ("#000000", "Black"),
    ]

    @objc private func showMore() {
        if let p = popover, p.isShown { p.close(); return }
        let current = AnnotationCanvas.hex(of: canvas.color)?.uppercased()
        var rows: [NSView] = []
        for chunk in stride(from: 0, to: Self.moreSwatches.count, by: 8) {
            let buttons = Self.moreSwatches[chunk..<min(chunk + 8, Self.moreSwatches.count)].map { (hex, name) -> SwatchButton in
                let b = SwatchButton(hex: hex, name: name, target: self, action: #selector(moreSwatchClicked(_:)))
                b.isOn = hex == current
                return b
            }
            rows.append(hstack(buttons, spacing: 8))
        }
        let field = NSTextField()
        field.placeholderString = "#RRGGBB"
        field.stringValue = current ?? ""
        field.target = self
        field.action = #selector(hexEntered(_:))
        field.setAccessibilityLabel("Custom colour, hex")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 150).isActive = true
        rows.append(field)
        let host = NSStackView(views: rows)
        host.orientation = .vertical
        host.alignment = .leading
        host.spacing = 8
        host.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let vc = NSViewController()
        vc.view = host
        host.layoutSubtreeIfNeeded()
        vc.preferredContentSize = host.fittingSize
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        p.show(relativeTo: moreButton.bounds, of: moreButton, preferredEdge: .maxX)
        popover = p
    }

    @objc private func moreSwatchClicked(_ s: SwatchButton) {
        canvas.color = s.swatchColor
        popover?.close()
        window?.makeFirstResponder(canvas)
    }

    @objc private func hexEntered(_ f: NSTextField) {
        guard let c = AnnotationCanvas.color(fromHex: f.stringValue) else { NSSound.beep(); return }
        canvas.color = c
        popover?.close()
        window?.makeFirstResponder(canvas)
    }
}
