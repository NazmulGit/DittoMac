// Vault (locked notes) preferences. Only non-secret values live here: no password, key, salt or wrapped key
// is ever written to UserDefaults (those live in the login Keychain, see VaultService).

import Foundation

extension Settings {
    public static let vaultAutoLockRange: ClosedRange<Int> = 0...240

    /// "system" (Touch ID / Mac login password) or "password" (separate DittoMac password).
    public var vaultMethod: String {
        get { defaults.string(forKey: "vaultMethod") ?? "system" }
        set { defaults.set(newValue == "password" ? "password" : "system", forKey: "vaultMethod") }
    }

    /// True once the vault has a key (set up by the first lock or from Security preferences).
    public var vaultConfigured: Bool {
        get { defaults.bool(forKey: "vaultConfigured") }
        set { defaults.set(newValue, forKey: "vaultConfigured") }
    }

    /// Minutes of inactivity before an unlocked vault locks again (0 = stay unlocked until quit). Default 5.
    public var vaultAutoLockMinutes: Int {
        get {
            let v = defaults.object(forKey: "vaultAutoLockMinutes") == nil ? 5 : defaults.integer(forKey: "vaultAutoLockMinutes")
            return min(max(v, Self.vaultAutoLockRange.lowerBound), Self.vaultAutoLockRange.upperBound)
        }
        set {
            defaults.set(min(max(newValue, Self.vaultAutoLockRange.lowerBound), Self.vaultAutoLockRange.upperBound),
                         forKey: "vaultAutoLockMinutes")
        }
    }

    /// Lock when the Mac sleeps or the screen locks. Default on.
    public var vaultLockOnSleep: Bool {
        get { defaults.object(forKey: "vaultLockOnSleep") == nil ? true : defaults.bool(forKey: "vaultLockOnSleep") }
        set { defaults.set(newValue, forKey: "vaultLockOnSleep") }
    }

    /// Vault keys. `vaultMethod` and `vaultConfigured` describe Keychain state, so a settings reset must not
    /// remove them (the app would forget it has locked notes); only the behaviour keys are user preferences.
    public static let vaultKeys: Set<String> = ["vaultMethod", "vaultConfigured", "vaultAutoLockMinutes", "vaultLockOnSleep"]
    public static let vaultResettableKeys: Set<String> = ["vaultAutoLockMinutes", "vaultLockOnSleep"]
}
