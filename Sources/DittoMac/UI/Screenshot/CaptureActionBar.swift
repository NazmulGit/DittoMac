// CaptureActionBar.swift — horizontal Lightshot-style action bar (icon buttons with hover labels and shortcuts).
// Drawn by hand (no visual-effect view) so it renders identically on the overlay and offscreen.

import AppKit
import DittoCore

@MainActor
final class CaptureActionBar: NSView {
    struct Item {
        let action: CaptureAction
        let symbol: String
        let title: String
        let shortcut: String
    }

    static let items: [Item?] = [
        Item(action: .upload, symbol: "icloud.and.arrow.up", title: "Upload & copy link", shortcut: "⌘D"),
        Item(action: .share, symbol: "square.and.arrow.up", title: "Share…", shortcut: ""),
        Item(action: .searchSimilar, symbol: "magnifyingglass", title: "Search similar images", shortcut: "⌘G"),
        Item(action: .print, symbol: "printer", title: "Print", shortcut: "⌘P"),
        nil,
        Item(action: .beautify, symbol: "sparkles", title: "Beautify", shortcut: "⌘B"),
        Item(action: .pin, symbol: "pin", title: "Pin to screen", shortcut: "⌘T"),
        nil,
        Item(action: .copy, symbol: "doc.on.doc", title: "Copy", shortcut: "⌘C"),
        Item(action: .save, symbol: "square.and.arrow.down", title: "Save", shortcut: "⌘S"),
        nil,
        Item(action: .close, symbol: "xmark", title: "Close", shortcut: "Esc"),
    ]

    var onAction: ((CaptureAction, NSView) -> Void)?
    var canUndo: (() -> Bool)?
    var beautifyOn = false { didSet { refresh() } }

    private var buttons: [CaptureAction: CaptureBarButton] = [:]
    private let tip = CaptureTipLabel()
    private static let buttonSize: CGFloat = 30
    private static let pad: CGFloat = 5
    private static let sepWidth: CGFloat = 9

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        var x = Self.pad
        for entry in Self.items {
            guard let item = entry else { x += Self.sepWidth; continue }
            let b = CaptureBarButton(symbol: item.symbol, label: item.title)
            b.frame = NSRect(x: x, y: Self.pad, width: Self.buttonSize, height: Self.buttonSize)
            b.toolTip = item.shortcut.isEmpty ? item.title : "\(item.title) (\(item.shortcut))"
            b.setAccessibilityLabel(item.title)
            b.target = self
            b.action = #selector(tapped(_:))
            b.tag = CaptureAction.allCases.firstIndex(of: item.action) ?? 0
            b.onHover = { [weak self] inside in self?.showTip(inside ? item : nil, for: b) }
            if item.action == .close { b.tintNormal = NSColor(calibratedRed: 1, green: 0.45, blue: 0.42, alpha: 1) }
            addSubview(b)
            buttons[item.action] = b
            x += Self.buttonSize + 2
        }
        tip.isHidden = true
        addSubview(tip)
        setFrameSize(NSSize(width: x - 2 + Self.pad, height: Self.buttonSize + Self.pad * 2))
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Screenshot actions")
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { frame.size }
    override var intrinsicContentSize: NSSize { frame.size }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bg = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        NSColor(calibratedWhite: 0.11, alpha: 0.94).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        bg.lineWidth = 1
        bg.stroke()
        // Separators.
        var x = Self.pad
        NSColor.white.withAlphaComponent(0.14).setFill()
        for entry in Self.items {
            if entry == nil {
                NSBezierPath(rect: NSRect(x: x + Self.sepWidth / 2 - 1.5, y: Self.pad + 6, width: 1, height: Self.buttonSize - 12)).fill()
                x += Self.sepWidth
            } else { x += Self.buttonSize + 2 }
        }
    }

    func refresh() {
        buttons[.beautify]?.isOn = beautifyOn
    }

    func button(for action: CaptureAction) -> NSView? { buttons[action] }

    @objc private func tapped(_ sender: CaptureBarButton) {
        guard sender.tag < CaptureAction.allCases.count else { return }
        onAction?(CaptureAction.allCases[sender.tag], sender)
    }

    /// Custom hover label (system tooltips can end up below a screen-saver-level overlay).
    private func showTip(_ item: Item?, for b: NSView) {
        guard let item, let sv = superview else { tip.isHidden = true; return }
        if tip.superview !== sv { tip.removeFromSuperview(); sv.addSubview(tip) }
        tip.text = item.shortcut.isEmpty ? item.title : "\(item.title)  \(item.shortcut)"
        let size = tip.fittingSize
        let anchor = b.convert(b.bounds, to: sv)
        let below = CGRect(x: anchor.midX - size.width / 2, y: frame.maxY + 6, width: size.width, height: size.height)
        let above = CGRect(x: below.minX, y: frame.minY - 6 - size.height, width: size.width, height: size.height)
        let f = below.maxY <= sv.bounds.maxY - 4 ? below : above
        tip.frame = ScreenshotGeometry.keepInside(f, bounds: sv.bounds.insetBy(dx: 4, dy: 4)).integral
        tip.isHidden = false
    }

    override func removeFromSuperview() {
        tip.removeFromSuperview()
        super.removeFromSuperview()
    }
}

// MARK: - Button

@MainActor
final class CaptureBarButton: NSButton {
    var onHover: ((Bool) -> Void)?
    var isOn = false { didSet { needsDisplay = true } }
    var tintNormal = NSColor.white
    private var hovering = false { didSet { needsDisplay = true } }
    private let symbolImage: NSImage?
    private var tracking: NSTrackingArea?

    init(symbol: String, label: String) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(cfg)
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        imagePosition = .noImage
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; onHover?(true); NSCursor.arrow.set() }
    override func mouseExited(with event: NSEvent) { hovering = false; onHover?(false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        if isOn {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        } else if hovering || isHighlighted {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.26 : 0.16).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
        guard let img = symbolImage else { return }
        let tint: NSColor = isOn ? .white : (isEnabled ? tintNormal : tintNormal.withAlphaComponent(0.35))
        let tinted = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let s = img.size
        let dst = NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height).integral
        tinted.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

// MARK: - Hover label

@MainActor
final class CaptureTipLabel: NSView {
    var text = "" { didSet { needsDisplay = true } }
    private var attrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
    }
    override var isFlipped: Bool { true }
    override var fittingSize: NSSize {
        let s = (text as NSString).size(withAttributes: attrs)
        return NSSize(width: ceil(s.width) + 14, height: ceil(s.height) + 6)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        NSColor(calibratedWhite: 0.05, alpha: 0.92).setFill()
        p.fill()
        (text as NSString).draw(at: NSPoint(x: 7, y: 3), withAttributes: attrs)
    }
}
