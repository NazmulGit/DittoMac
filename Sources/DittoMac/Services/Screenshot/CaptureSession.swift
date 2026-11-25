// CaptureSession.swift — one capture: overlay windows on every display, keyboard map, and the actions.
import AppKit
import DittoCore

@MainActor
final class CaptureSession: NSObject, CaptureOverlayDelegate {
    private unowned let state: AppState
    let mode: CaptureMode
    private let output: ScreenshotOutput
    private(set) var windows: [CaptureOverlayWindow] = []
    private weak var active: CaptureOverlayView?
    private let beautify: CaptureBeautifyModel
    private var popover: NSPopover?
    private let previousApp: NSRunningApplication?
    private var ended = false
    var onEnd: (() -> Void)?

    private var settings: DittoCore.Settings { state.settings }
    private var views: [CaptureOverlayView] { windows.map(\.overlay) }

    init(state: AppState, mode: CaptureMode, snapshots: [DisplaySnapshot], windowList: [CaptureWindowInfo], output: ScreenshotOutput) {
        self.state = state
        self.mode = mode
        self.output = output
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        beautify = CaptureBeautifyModel(enabled: state.settings.screenshotBeautifyAutoApplyFlag,
                                        style: CaptureBeautifyModel.defaultStyle(state.settings))
        super.init()
        var config = CaptureOverlayConfig()
        config.mode = mode
        config.dimOpacity = CGFloat(state.settings.screenshotDimOpacity)
        config.showMagnifier = state.settings.screenshotShowMagnifier
        config.windows = windowList
        config.beautifyOn = beautify.enabled
        for snap in snapshots {
            let v = CaptureOverlayView(snapshot: snap, config: config)
            v.delegate = self
            let w = CaptureOverlayWindow(overlay: v)
            w.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
            windows.append(w)
        }
        beautify.onChange = { [weak self] in
            guard let self else { return }
            for v in self.views { v.config.beautifyOn = self.beautify.enabled }
        }
        beautify.source = { [weak self] in
            guard let v = self?.active, let img = v.renderedSelection() else { return nil }
            return (img, v.snapshot.pixelScale)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(otherWindowBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Shows the overlays. `preselect` selects the whole display under the mouse (full-screen mode → editor).
    func present(preselect: Bool) {
        guard !windows.isEmpty else { cancel(); return }      // nothing to show: never leave a dead session behind
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for w in windows { w.orderFrontRegardless() }
        let underMouse = windows.first { $0.overlay.snapshot.frame.contains(mouse) } ?? windows.first
        underMouse?.makeKeyAndOrderFront(nil)
        underMouse?.makeFirstResponder(underMouse?.overlay)
        NSCursor.crosshair.set()
        if preselect, let v = underMouse?.overlay {
            active = v
            v.setSelection(v.bounds)
            v.beginEditing()
        }
    }

    @objc private func screensChanged() { cancel() }

    /// An app-modal alert (e.g. a vault password prompt triggered by a hotkey) would sit below the screen-saver-level
    /// overlay, invisible but capturing input. Cancel the capture so the alert is visible and nothing is stuck.
    @objc private func otherWindowBecameKey(_ n: Notification) {
        guard !overlaysSuspended, let w = n.object as? NSWindow, !windows.contains(where: { $0 === w }) else { return }
        if w.level == .modalPanel || NSApp.modalWindow === w { cancel() }
    }

    // MARK: CaptureOverlayDelegate

    func overlayShouldBeginSelection(_ view: CaptureOverlayView) -> Bool {
        !views.contains { $0 !== view && $0.selectionLocked }
    }

    func overlayDidBeginSelection(_ view: CaptureOverlayView) {
        for v in views where v !== view { v.clearSelection() }
        active = view
        closePopover()
    }

    func overlay(_ view: CaptureOverlayView, didFinishSelection instantCopy: Bool, windowClick: Bool) {
        active = view
        if instantCopy { perform(.copy, sender: nil); return }
        if windowClick, let a = Self.outputAction(settings.screenshotWindowAction) { perform(a, sender: nil); return }
        view.beginEditing()
    }

    func overlay(_ view: CaptureOverlayView, perform action: CaptureAction, sender: NSView?) {
        active = view
        perform(action, sender: sender)
    }

    func overlayDidCancel(_ view: CaptureOverlayView) { cancel() }

    static func outputAction(_ a: ScreenshotAction) -> CaptureAction? {
        switch a {
        case .copy: return .copy
        case .save: return .save
        case .upload: return .upload
        case .editor: return nil
        }
    }

    // MARK: keyboard

    func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)
        let hasSelection = active?.selection != nil
        switch e.keyCode {
        case 53:                                                     // Esc
            if popover?.isShown == true { closePopover(); return true }
            cancel(); return true
        case 36, 76:                                                 // Return / Enter
            guard hasSelection else { NSSound.beep(); return true }
            if let a = Self.outputAction(settings.screenshotDefaultAction) { perform(a, sender: nil) } else { NSSound.beep() }
            return true
        case let k where (123...126).contains(k) && !cmd:                          // arrows: nudge
            // With an annotation selected the arrows belong to the annotation (the canvas nudges it).
            if active?.canvas?.hasSelection == true || active?.canvas?.isEditingText == true { return false }
            let step: CGFloat = shift ? 10 : 1
            let d: (CGFloat, CGFloat) = e.keyCode == 123 ? (-step, 0) : e.keyCode == 124 ? (step, 0) : e.keyCode == 125 ? (0, step) : (0, -step)
            if active?.nudge(dx: d.0, dy: d.1) != true { NSSound.beep() }
            return true
        case let k where (k == 51 || k == 117) && !cmd:                                     // Delete: remove selected annotation
            active?.canvas?.deleteSelected()
            return true
        default: break
        }
        guard cmd, let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        switch ch {
        case "a": selectWholeDisplay(); return true
        case "z":
            if shift { active?.canvas?.redo() } else { active?.canvas?.undo() }
            active?.toolbar?.refresh()
            return true
        case "w", ".": cancel(); return true
        default: break
        }
        guard hasSelection else { return false }
        switch ch {
        case "c": perform(.copy, sender: nil)
        case "s": perform(.save, sender: nil)
        case "d": perform(.upload, sender: nil)
        case "p": perform(.print, sender: nil)
        case "g": perform(.searchSimilar, sender: nil)
        case "b": perform(.beautify, sender: nil)
        case "t": perform(.pin, sender: nil)
        default: return false
        }
        return true
    }

    private func selectWholeDisplay() {
        let mouse = NSEvent.mouseLocation
        guard let v = views.first(where: { $0.snapshot.frame.contains(mouse) }) ?? active ?? views.first else { return }
        if views.contains(where: { $0.selectionLocked }) { NSSound.beep(); return }
        overlayDidBeginSelection(v)
        v.setSelection(v.bounds)
        overlay(v, didFinishSelection: false, windowClick: false)
    }

    // MARK: actions

    /// Final pixels: annotations flattened, then Beautify when enabled for this capture.
    func finalImage() -> CGImage? {
        guard let v = active, let base = v.renderedSelection() else { return nil }
        guard beautify.enabled else { return base }
        return BeautifyRenderer.render(base, pixelScale: v.snapshot.pixelScale, style: beautify.style)
    }

    func perform(_ action: CaptureAction, sender: NSView?) {
        if action == .close { cancel(); return }
        if action == .beautify { toggleBeautify(sender: sender); return }
        guard let v = active, let img = finalImage() else { NSSound.beep(); return }
        let scale = v.snapshot.pixelScale
        let selGlobal = v.selection.map {
            ScreenshotGeometry.viewToGlobal(CGPoint(x: $0.minX, y: $0.minY), displayFrame: v.snapshot.frame)
        } ?? NSEvent.mouseLocation
        if action != .save { output.playShutter() }     // save plays it once the file is written
        switch action {
        case .copy:
            end(restoreFocus: true)
            if output.copy(img) { state.message("Screenshot copied (\(img.width) × \(img.height))") }
        case .save:
            save(img)
        case .upload:
            end(restoreFocus: false)
            CaptureSharePanel.show(image: img, state: state, output: output, autoUpload: true)
        case .share:
            end(restoreFocus: false)
            CaptureSharePanel.show(image: img, state: state, output: output, autoUpload: false)
        case .searchSimilar:
            end(restoreFocus: false)
            CaptureSharePanel.show(image: img, state: state, output: output, autoUpload: true, after: .searchSimilar)
        case .print:
            end(restoreFocus: false)
            output.print(img)
        case .pin:
            end(restoreFocus: true)
            let size = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
            var topLeft = selGlobal
            if beautify.enabled, let sel = v.selection {
                // Keep the screenshot itself roughly where it was: centre the larger beautified image on it.
                topLeft.x -= (size.width - sel.width) / 2
                topLeft.y += (size.height - sel.height) / 2
            }
            let out = output
            PinnedScreenshotWindow.pin(img, pointSize: size, topLeft: topLeft,
                                       onCopy: { image in if out.copy(image, addHistory: false) { out.state.message("Screenshot copied") } },
                                       onSave: { image in out.save(image) })
            output.addToHistory(img)
        case .close, .beautify:
            break
        }
    }

    /// Ends the session only after a successful save. Cancelling the save panel (or a write error) returns to the
    /// overlay with the selection and annotations intact, so the screenshot isn't lost.
    private func save(_ img: CGImage) {
        let asking = settings.screenshotAskWhereToSave
        // The save panel is a modal-panel-level window: lower the screen-saver-level overlays so it is visible, and
        // don't treat it as a foreign alert that cancels the capture.
        if asking { suspendOverlays(true) }
        output.save(img) { [weak self] url in
            guard let self, !self.ended else { return }
            if asking { self.suspendOverlays(false) }
            if url != nil {
                self.output.playShutter()
                self.end(restoreFocus: !asking)
            } else {
                self.resumeEditing()
            }
        }
    }

    private var overlaysSuspended = false

    private func suspendOverlays(_ on: Bool) {
        overlaysSuspended = on
        for w in windows { w.level = on ? .normal : .screenSaver }
    }

    private func resumeEditing() {
        guard let v = active else { return }
        v.window?.makeKeyAndOrderFront(nil)
        v.window?.makeFirstResponder(v.canvas ?? v)
        NSCursor.crosshair.set()
    }

    private func toggleBeautify(sender: NSView?) {
        if popover?.isShown == true { closePopover(); return }
        guard let anchor = sender ?? active?.actionBar?.button(for: .beautify) else {
            beautify.enabled.toggle(); return
        }
        if !beautify.enabled { beautify.enabled = true }
        popover = CaptureBeautifyPopover.show(model: beautify, relativeTo: anchor)
    }

    private func closePopover() {
        popover?.performClose(nil)
        popover = nil
    }

    func cancel() { end(restoreFocus: true) }

    private func end(restoreFocus: Bool) {
        guard !ended else { return }
        ended = true
        closePopover()
        for w in windows {
            w.keyHandler = nil
            w.overlay.removeEditing()
            w.orderOut(nil)
            w.close()
        }
        windows.removeAll()
        NSCursor.arrow.set()
        if restoreFocus, let app = previousApp, !app.isTerminated { app.activate(options: []) }
        NotificationCenter.default.removeObserver(self)
        onEnd?()
        onEnd = nil
    }
}
