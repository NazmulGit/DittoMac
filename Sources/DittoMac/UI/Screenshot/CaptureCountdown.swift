// CaptureCountdown.swift — "3… 2… 1…" panel shown before a delayed capture (hidden before the snapshot is taken).
import AppKit

@MainActor
final class CaptureCountdown {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?
    private var remaining = 0
    private var completion: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var keyMonitors: [Any] = []

    /// A countdown is running (the snapshot hasn't been taken yet).
    var isActive: Bool { timer != nil }

    /// Counts down `seconds` on the screen under the mouse, then hides itself and calls `completion` (not on cancel).
    /// Esc cancels (`onCancel` runs); so does `cancel()` from the caller (e.g. the capture hotkey pressed again).
    func start(seconds: Int, onCancel: (() -> Void)? = nil, completion: @escaping () -> Void) {
        cancel()
        guard seconds > 0 else { completion(); return }
        self.completion = completion
        self.onCancel = onCancel
        remaining = seconds
        let p = makePanel()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let size = NSSize(width: 132, height: 132)
        p.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height), display: true)
        update()
        p.orderFrontRegardless()
        // `.common` modes: the countdown keeps ticking while a menu is being tracked.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        installKeyMonitors()
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        removeKeyMonitors()
        panel?.orderOut(nil)
        completion = nil
        onCancel = nil
    }

    /// Esc pressed during the countdown.
    private func userCancelled() {
        guard timer != nil else { return }
        let c = onCancel
        cancel()
        c?()
    }

    // Local monitor: Esc while DittoMac is active. Global monitor: Esc in another app (macOS delivers these only
    // when the user has allowed input monitoring; without it the capture hotkey pressed again still cancels).
    private func installKeyMonitors() {
        removeKeyMonitors()
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53 else { return e }
            MainActor.assumeIsolated { self?.userCancelled() }
            return nil
        }) { keyMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            guard e.keyCode == 53 else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.userCancelled() } }
        }) { keyMonitors.append(global) }
    }

    private func removeKeyMonitors() {
        keyMonitors.forEach { NSEvent.removeMonitor($0) }
        keyMonitors.removeAll()
    }

    private func tick() {
        remaining -= 1
        if remaining > 0 { update(); return }
        timer?.invalidate(); timer = nil
        removeKeyMonitors()
        panel?.orderOut(nil)
        let c = completion
        completion = nil
        onCancel = nil
        // Give the window server a moment to remove the panel before the snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { c?() }
    }

    private func update() {
        label?.stringValue = "\(remaining)"
        panel?.contentView?.setAccessibilityLabel("Screenshot in \(remaining) seconds")
    }

    private func makePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 132, height: 132),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let fx = NSVisualEffectView(frame: p.contentRect(forFrameRect: p.frame))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 26
        fx.layer?.masksToBounds = true
        fx.autoresizingMask = [.width, .height]
        let l = NSTextField(labelWithString: "")
        l.font = .monospacedDigitSystemFont(ofSize: 64, weight: .semibold)
        l.alignment = .center
        l.textColor = .labelColor
        l.frame = NSRect(x: 0, y: 30, width: 132, height: 80)
        let sub = NSTextField(labelWithString: "Screenshot in")
        sub.font = .systemFont(ofSize: 11, weight: .medium)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.frame = NSRect(x: 0, y: 104, width: 132, height: 16)
        fx.addSubview(l); fx.addSubview(sub)
        p.contentView = fx
        panel = p; label = l
        return p
    }
}
