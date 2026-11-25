// SyncConfigChange.swift — decides what a Preferences change means for the running sync driver (pure, testable).
//
// Typing a device name or moving a stepper must not start a forced full sync per keystroke. Only settings that
// change *what is synced or where* restart sync; the interval only reschedules the timers; the device name, the
// size limit and the backup count are simply read by the next scheduled run.
import Foundation

public struct SyncConfigSnapshot: Equatable, Sendable {
    public var enabled: Bool
    public var includeImages: Bool
    public var includeRich: Bool
    public var backups: Bool
    public var hasPassphrase: Bool
    public var folderPath: String
    public var intervalMinutes: Int
    public var deviceName: String
    public var maxTotalMB: Int
    public var backupKeep: Int

    public init(enabled: Bool, includeImages: Bool, includeRich: Bool, backups: Bool, hasPassphrase: Bool,
                folderPath: String, intervalMinutes: Int, deviceName: String, maxTotalMB: Int, backupKeep: Int) {
        self.enabled = enabled; self.includeImages = includeImages; self.includeRich = includeRich
        self.backups = backups; self.hasPassphrase = hasPassphrase; self.folderPath = folderPath
        self.intervalMinutes = intervalMinutes; self.deviceName = deviceName
        self.maxTotalMB = maxTotalMB; self.backupKeep = backupKeep
    }

    public enum Change: Equatable, Sendable {
        /// Nothing to do now; changed values are picked up by the next scheduled run.
        case none
        /// Only the check interval changed: recreate the push timer, no sync.
        case reschedule
        /// Start over: new timers and a forced full sync.
        case restart
    }

    public func change(from old: SyncConfigSnapshot?) -> Change {
        guard let old else { return .restart }
        if enabled != old.enabled || includeImages != old.includeImages || includeRich != old.includeRich
            || backups != old.backups || hasPassphrase != old.hasPassphrase || folderPath != old.folderPath {
            return .restart
        }
        if intervalMinutes != old.intervalMinutes { return .reschedule }
        return .none
    }
}
