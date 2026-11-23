// HUD.swift — transient, non-activating message bubble (wired to AppState.showMessage).

import AppKit

@MainActor
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    private init() {}

    /// Shows `text` near the top of the screen with the mouse; fades out after `duration` (default scales with length).
    func show(_ text: String, duration: TimeInterval? = nil) {
        let panel = self.panel ?? makePanel()
        guard let label else { return }
        label.stringValue = text

        let maxWidth: CGFloat = 460
        label.preferredMaxLayoutWidth = maxWidth
        let size = label.sizeThatFits(NSSize(width: maxWidth, height: 400))
        let w = min(max(size.width, 120), maxWidth) + 36
        let h = max(size.height, 18) + 24
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = NSRect(x: vf.midX - w / 2, y: vf.maxY - h - 60, width: w, height: h)
        panel.setFrame(frame, display: true)
        label.frame = NSRect(x: 18, y: 12, width: w - 36, height: h - 24)

        hideWork?.cancel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        let d = duration ?? min(max(2.0, Double(text.count) / 18.0), 7.0)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: work)
    }

    func hide() { fadeOut() }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if panel.alphaValue < 0.01 { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let p = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 48),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.onClick = { [weak self] in self?.fadeOut() }

        let fx = NSVisualEffectView(frame: p.contentRect(forFrameRect: p.frame))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        fx.autoresizingMask = [.width, .height]
        p.contentView = fx

        let l = NSTextField(wrappingLabelWithString: "")
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = .labelColor
        l.alignment = .center
        l.maximumNumberOfLines = 6
        fx.addSubview(l)

        panel = p
        label = l
        return p
    }
}

private final class HUDPanel: NSPanel {
    var onClick: (() -> Void)?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
}
