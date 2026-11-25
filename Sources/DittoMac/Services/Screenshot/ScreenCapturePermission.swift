// ScreenCapturePermission.swift — Screen Recording permission: preflight anywhere, request only on an explicit click.
import AppKit

@MainActor
enum ScreenCapturePermission {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Safe to call at any time (never prompts).
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Only call from an explicit user action (button click). Returns the current state.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSystemSettings() { NSWorkspace.shared.open(settingsURL) }

    static let explanation = """
    DittoMac needs Screen Recording permission to take screenshots. macOS asks for it once; screenshots stay on \
    your Mac unless you choose Upload.

    1. Click “Grant Access” (or “Open System Settings”) and switch on DittoMac under Privacy & Security › Screen & \
    System Audio Recording.
    2. macOS may ask you to quit and reopen DittoMac before the permission takes effect.

    DittoMac is ad-hoc signed, so after an update macOS may treat it as a new app: if screenshots stop working, \
    switch DittoMac off and on again in that list (or remove it with “–” and add it again).
    """

    /// Friendly alert with Grant Access / Open System Settings / Cancel.
    static func showAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "Allow DittoMac to capture the screen"
        a.informativeText = explanation
        a.icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        a.addButton(withTitle: "Grant Access")
        a.addButton(withTitle: "Open System Settings")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if !request() {
                // Already denied once: macOS won't show its prompt again, so take the user to the setting.
                openSystemSettings()
            }
        case .alertSecondButtonReturn:
            openSystemSettings()
        default:
            break
        }
    }
}
