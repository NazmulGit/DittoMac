// CaptureOverlayWindow.swift — borderless, key-capable window covering one display above everything.
import AppKit

@MainActor
final class CaptureOverlayWindow: NSWindow {
    /// Session-level keyboard handling; return true when the key was consumed.
    var keyHandler: ((NSEvent) -> Bool)?
    let overlay: CaptureOverlayView

    init(overlay: CaptureOverlayView) {
        self.overlay = overlay
        super.init(contentRect: NSRect(origin: .zero, size: overlay.snapshot.frame.size),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(overlay.snapshot.frame, display: false)     // global frame (no screen-relative init surprises)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        animationBehavior = .none
        isMovable = false
        contentView = overlay
        title = "DittoMac Screenshot"
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !(firstResponder is NSText), keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    // Keep the frame exactly on the display (borderless windows aren't constrained, but be explicit).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
