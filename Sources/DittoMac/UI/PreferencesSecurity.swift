// PreferencesSecurity.swift — Security tab: locked notes (vault) method, password, auto-lock, status, reset.
import Combine
import SwiftUI
import DittoCore

struct SecurityPrefs: View {
    @ObservedObject var m: PrefsModel
    @LState private var tick = 0
    @LState private var message: String?
    @LState private var isError = false
    @LState private var setupMethod: VaultMethod = .system

    private static let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var vault: VaultService? { m.state.vault as? VaultService }

    private var autoLockBinding: Binding<Int> {
        Binding(get: { vault?.autoLockMinutes ?? m.s.vaultAutoLockMinutes },
                set: { v in
                    if let vault { vault.autoLockMinutes = v } else { m.s.vaultAutoLockMinutes = v }
                    m.changed()
                })
    }

    private var methodBinding: Binding<VaultMethod> {
        Binding(get: { (vault?.isSetUp ?? false) ? (vault?.method ?? .system) : setupMethod },
                set: { new in
                    guard let vault else { return }
                    guard vault.isSetUp else { setupMethod = new; return }
                    guard new != vault.method else { return }
                    vault.configure(method: new, newPassword: nil) { ok in
                        report(ok ? (new == .system ? "Locked notes now unlock with your Mac password or Touch ID."
                                                    : "Locked notes are now protected by your DittoMac password.")
                                  : "The protection method was not changed.", error: !ok)
                    }
                })
    }

    var body: some View {
        let _ = tick
        let setUp = vault?.isSetUp ?? false
        let unlocked = vault?.isUnlocked ?? false
        Form {
            Section("Locked notes") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Image(systemName: unlocked ? "lock.open" : "lock").foregroundStyle(unlocked ? Color.orange : Color.secondary)
                        Text(vault?.statusText ?? "Unavailable")
                    }
                }
                LabeledContent("Locked notes") { Text("\(vault?.lockedCount ?? 0)") }
                HStack {
                    if setUp {
                        Button(unlocked ? "Lock Now" : "Unlock…") {
                            guard let vault else { return }
                            if unlocked { vault.lockNow() } else {
                                vault.requestUnlock(reason: "unlock your locked notes") { _ in tick += 1 }
                            }
                        }
                    } else {
                        Button("Set Up…") {
                            vault?.configure(method: setupMethod, newPassword: nil) { ok in
                                report(ok ? "Locked notes are set up. Lock a clip from its right-click menu." : "Setup was cancelled.", error: !ok)
                            }
                        }
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(isError ? Color.red : Color.green) }
                Text("Locked notes are encrypted, hidden until unlocked, and are never removed by Delete, Delete All, "
                     + "Delete Non-Used, Delete Clip Data, expiry or the history limit. They are not exported or synced.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Unlock with") {
                Picker("Method", selection: methodBinding) {
                    Text("My Mac login password or Touch ID").tag(VaultMethod.system)
                    Text("A separate DittoMac password").tag(VaultMethod.password)
                }
                .pickerStyle(.radioGroup)
                if setUp, vault?.method == .password {
                    Button("Change DittoMac Password…") {
                        vault?.configure(method: .password, newPassword: nil) { ok in
                            report(ok ? "Password changed." : "The password was not changed.", error: !ok)
                        }
                    }
                }
                Text(explanation(for: methodBinding.wrappedValue))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Auto-lock") {
                Stepper(value: autoLockBinding, in: DittoCore.Settings.vaultAutoLockRange) {
                    let n = autoLockBinding.wrappedValue
                    Text(n == 0 ? "Stay unlocked until DittoMac quits" : "Lock after \(n) minute\(n == 1 ? "" : "s") of inactivity")
                }
                Toggle("Lock when the Mac sleeps or the screen locks", isOn: m.b(\.vaultLockOnSleep))
                Text("Locked notes also lock whenever DittoMac quits.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Forgot your password?") {
                HStack {
                    Button("Reset Vault…", role: .destructive) {
                        vault?.resetVault { ok in if ok { report("The vault was reset. All locked notes were deleted.", error: false) } }
                    }
                    .disabled(!setUp)
                    Spacer()
                }
                Text("Resetting permanently deletes every locked note and the vault key. It is the only way back in if the "
                     + "DittoMac password is forgotten.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dittoVaultChanged)) { _ in tick += 1 }
        .onReceive(Self.ticker) { _ in if vault?.isUnlocked == true { tick += 1 } }
    }

    private func explanation(for method: VaultMethod) -> String {
        switch method {
        case .system:
            return "Unlock with Touch ID or your Mac login password in the standard macOS prompt; DittoMac never sees "
                + "the password. The notes are encrypted with a key kept in your login Keychain on this Mac. This protects "
                + "the database file, backups and copies in sync folders. Someone who is logged in as you and can unlock "
                + "your Keychain could still read the notes: the prompt is an app-level gate."
        case .password:
            return "The encryption key is itself encrypted with your DittoMac password (PBKDF2-SHA256, 600,000 rounds). "
                + "Without the password the key can’t be derived and the notes can’t be read, even from a copy of the "
                + "database and your Keychain. A forgotten password can’t be recovered."
        }
    }

    private func report(_ text: String, error: Bool) {
        message = text
        isError = error
        tick += 1
    }
}
