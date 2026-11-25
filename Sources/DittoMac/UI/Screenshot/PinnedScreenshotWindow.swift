// PinnedScreenshotWindow.swift — "Pin to screen": a floating, always-on-top image you can drag around.
// ⌥-scroll (or pinch) resizes, Esc or double-click closes, right-click offers Copy / Save / Close.
import AppKit

@MainActor
final class PinnedScreenshotWindow: NSPanel {
    private static var open: [PinnedScreenshotWindow] = []
    private let image: CGImage
    private let aspect: CGFloat
    var onCopy: ((CGImage) -> Void)?
    var onSave: ((CGImage) -> Void)?

    /// Shows `image` (pixels) at `pointSize`, top-left at `topLeft` (AppKit global), kept on screen.
    @discardableResult
    static func pin(_ image: CGImage, pointSize: CGSize, topLeft: CGPoint,
                    onCopy: ((CGImage) -> Void)? = nil, onSave: ((CGImage) -> Void)? = nil) -> PinnedScreenshotWindow {
        let w = PinnedScreenshotWindow(image: image, size: pointSize, topLeft: topLeft)
        w.onCopy = onCopy
        w.onSave = onSave
        open.append(w)
        w.orderFrontRegardless()
        w.makeKey()
        return w
    }

    private init(image: CGImage, size: CGSize, topLeft: CGPoint) {
        self.image = image
        aspect = size.height > 0 ? size.width / size.height : 1
        var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: max(size.width, 24), height: max(size.height, 24))
        if let vf = (NSScreen.screens.first { $0.frame.contains(topLeft) } ?? NSScreen.main)?.visibleFrame {
            if frame.width > vf.width || frame.height > vf.height {
                let s = min(vf.width / frame.width, vf.height / frame.height) * 0.9
                frame.size = NSSize(width: frame.width * s, height: frame.height * s)
            }
            frame.origin.x = min(max(frame.minX, vf.minX), vf.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, vf.minY), vf.maxY - frame.height)
        }
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = PinnedImageView(image: image)
        v.owner = self
        contentView = v
        title = "Pinned Screenshot"
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" { onCopy?(image); return }
        super.keyDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) { closePin() }

    func closePin() {
        orderOut(nil)
        close()
        Self.open.removeAll { $0 === self }
    }

    fileprivate func resize(by factor: CGFloat) {
        let f = frame
        var w = min(max(f.width * factor, 40), CGFloat(image.width) * 4)
        var h = w / aspect
        if h < 24 { h = 24; w = h * aspect }
        let nf = NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h).integral
        setFrame(nf, display: true)
    }

    fileprivate func menu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyItem), keyEquivalent: "c").target = self
        if onSave != nil { m.addItem(withTitle: "Save…", action: #selector(saveItem), keyEquivalent: "").target = self }
        m.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closeItem), keyEquivalent: "").target = self
        return m
    }
    @objc private func copyItem() { onCopy?(image) }
    @objc private func saveItem() { onSave?(image) }
    @objc private func closeItem() { closePin() }
    @objc private func actualSize() {
        let scale = screen?.backingScaleFactor ?? 2
        let w = CGFloat(image.width) / scale
        resize(by: w / frame.width)
    }
}

@MainActor
private final class PinnedImageView: NSView {
    weak var owner: PinnedScreenshotWindow?
    private let image: NSImage
    init(image: CGImage) {
        self.image = NSImage(cgImage: image, size: .zero)
        super.init(frame: .zero)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Pinned screenshot. Escape or double-click closes; Option-scroll resizes.")
        toolTip = "Drag to move · ⌥-scroll to resize · double-click or Esc to close"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        p.lineWidth = 1
        p.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.closePin(); return }
        window?.performDrag(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else { super.scrollWheel(with: event); return }
        let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        owner?.resize(by: max(0.5, min(1.5, 1 + d)))
    }
    override func magnify(with event: NSEvent) { owner?.resize(by: 1 + event.magnification) }
    override func menu(for event: NSEvent) -> NSMenu? { owner?.menu() }
}
