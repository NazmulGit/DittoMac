// LoginItem.swift — launch-at-login via SMAppService (macOS 13+). Only works from a real .app bundle.

import Foundation
import ServiceManagement

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// True when the system wants the user to approve the item in System Settings › Login Items.
    static var requiresApproval: Bool { status == .requiresApproval }

    static var statusText: String {
        switch status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Not registered"
        case .requiresApproval: return "Needs approval in System Settings › General › Login Items"
        case .notFound: return "Unavailable (run DittoMac from its .app bundle)"
        @unknown default: return "Unknown"
        }
    }

    /// Registers or unregisters the main app as a login item.
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if status == .enabled || status == .requiresApproval { try SMAppService.mainApp.unregister() }
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
