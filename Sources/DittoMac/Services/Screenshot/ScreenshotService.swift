// ScreenshotService.swift — Lightshot-style capture entry points, hotkeys and permission handling.
// Flow: hotkey/menu → permission check → optional countdown → frozen snapshot of every display → overlay session
// (or, for full-screen with a non-editor action, straight to the output).
import AppKit
import DittoCore

@MainActor
final class ScreenshotService: ScreenshotServicing {
    unowned let state: AppState
    private let capture: ScreenCaptureProviding
    private(set) lazy var output = ScreenshotOutput(state: state)
    private var session: CaptureSession?
    private let countdown = CaptureCountdown()
    private var busy = false
    private(set) var hotkeyProblems: [String] = []
    private var lastReportedHotkeyFailures: Set<String> = []

    init(state: AppState, capture: ScreenCaptureProviding? = nil) {
        self.state = state
        self.capture = capture ?? SystemScreenCapture()
    }

    // MARK: ScreenshotServicing

    func captureArea() { start(.area) }
    func captureWindow() { start(.window) }
    func captureFullScreen() { start(.fullScreen) }

    func registerHotkeys() {
        guard let hotkeys = state.hotkeys else { return }
        var failed: [String] = []
        for name in Settings.screenshotHotkeyNames {
            let v = state.settings.screenshotHotkey(name)
            guard v != 0 else { hotkeys.unregister(name: name); continue }
            let combo = KeyCombo(encoded: v)
            let ok = hotkeys.register(name: name, combo: combo) { [weak self] in
                switch name {
                case "captureWindow": self?.captureWindow()
                case "captureFullScreen": self?.captureFullScreen()
                default: self?.captureArea()
                }
            }
            if !ok { failed.append("\(PrefsModel.title(forHotkey: name)) (\(combo.displayString))") }
        }
        hotkeyProblems = failed.map { "\($0) is in use by another app or macOS: choose a different capture shortcut." }
        let set = Set(failed)
        if !failed.isEmpty {
            NSLog("DittoMac: screenshot hotkeys refused by macOS: \(failed.joined(separator: ", "))")
            // Reported once per distinct failure (registerHotkeys runs on every shortcut change).
            if set != lastReportedHotkeyFailures {
                state.message("Screenshot hotkey is in use by another app: \(failed.joined(separator: ", ")). Change it in Preferences ▸ Screenshots")
            }
        }
        lastReportedHotkeyFailures = set
    }

    /// `prompt: true` must only come from an explicit user action (it may show the macOS prompt).
    func hasScreenRecordingPermission(prompt: Bool) -> Bool {
        if ScreenCapturePermission.isGranted { return true }
        if prompt { ScreenCapturePermission.request() }
        return ScreenCapturePermission.isGranted
    }

    // MARK: flow

    private func start(_ mode: CaptureMode) {
        // A capture hotkey pressed during the countdown cancels it.
        if countdown.isActive {
            countdown.cancel()
            busy = false
            state.message("Screenshot cancelled")
            return
        }
        guard session == nil, !busy else { return }        // one capture at a time
        guard capture.hasPermission() else { ScreenCapturePermission.showAlert(); return }
        busy = true
        state.hideQuickPaste?()                            // the popup must not end up in the snapshot
        let delay = state.settings.screenshotDelaySeconds
        if delay > 0 {
            countdown.start(seconds: delay, onCancel: { [weak self] in
                self?.busy = false
                self?.state.message("Screenshot cancelled")
            }, completion: { [weak self] in self?.snap(mode) })
        } else {
            snap(mode)
        }
    }

    /// Set by the screen-parameters notification while a snapshot is being taken.
    private final class DisplayChangeFlag: @unchecked Sendable { var changed = false }

    private func snap(_ mode: CaptureMode) {
        let includeCursor = state.settings.screenshotIncludeCursor
        // Registered *before* the await so a display change during the capture can't slip through unnoticed.
        let flag = DisplayChangeFlag()
        let observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                              object: nil, queue: .main) { _ in flag.changed = true }
        Task { @MainActor [weak self] in
            guard let self else { NotificationCenter.default.removeObserver(observer); return }
            defer { self.busy = false; NotificationCenter.default.removeObserver(observer) }
            do {
                self.state.hideQuickPaste?()
                try? await Task.sleep(nanoseconds: 100_000_000)     // let the window server drop a just-hidden popup
                let snaps = try await self.capture.snapshotAllDisplays(includeCursor: includeCursor)
                guard !flag.changed, ScreenshotGeometry.displaysMatch(captured: snaps.map(\.frame), current: NSScreen.screens.map(\.frame)) else {
                    self.state.message("Displays changed while capturing — screenshot cancelled, try again")
                    return
                }
                let wins = mode == .window ? self.capture.onScreenWindows(excludingPID: ProcessInfo.processInfo.processIdentifier) : []
                self.handle(snaps, windows: wins, mode: mode)
            } catch ScreenCaptureError.noPermission {
                ScreenCapturePermission.showAlert()
            } catch {
                self.state.message(error.localizedDescription)
            }
        }
    }

    private func handle(_ snaps: [DisplaySnapshot], windows: [CaptureWindowInfo], mode: CaptureMode) {
        guard !snaps.isEmpty else { state.message(ScreenCaptureError.noDisplays.localizedDescription); return }
        if mode == .fullScreen, let action = CaptureSession.outputAction(state.settings.screenshotFullScreenAction) {
            let mouse = NSEvent.mouseLocation
            let idx = ScreenshotGeometry.displayIndex(containing: mouse, frames: snaps.map(\.frame)) ?? 0
            directOutput(snaps[min(max(idx, 0), snaps.count - 1)], action: action)
            return
        }
        let s = CaptureSession(state: state, mode: mode, snapshots: snaps, windowList: windows, output: output)
        s.onEnd = { [weak self] in self?.session = nil }
        session = s
        s.present(preselect: mode == .fullScreen)
    }

    /// Full-screen capture without the editor: copy / save / upload the whole display.
    private func directOutput(_ snap: DisplaySnapshot, action: CaptureAction) {
        var img = snap.image
        if state.settings.screenshotBeautifyAutoApplyFlag {
            img = BeautifyRenderer.render(img, pixelScale: snap.pixelScale, style: CaptureBeautifyModel.defaultStyle(state.settings))
        }
        output.playShutter()
        switch action {
        case .copy:
            if output.copy(img) { state.message("Full-screen screenshot copied (\(img.width) × \(img.height))") }
        case .save:
            output.save(img)
        case .upload:
            CaptureSharePanel.show(image: img, state: state, output: output, autoUpload: true)
        default:
            if output.copy(img) { state.message("Screenshot copied") }
        }
    }
}
