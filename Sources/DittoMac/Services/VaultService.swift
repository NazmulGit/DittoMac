// VaultService.swift — locked clips / sticky notes ("Vault").
//
// Data key: 32 random bytes; every locked blob is AES-256-GCM encrypted under it by ClipStore.
//  - Method `.system` (default): the data key lives in the login Keychain (this device only). Unlocking is
//    gated by LocalAuthentication `.deviceOwnerAuthentication` (Touch ID or the Mac login password in the macOS
//    prompt; the app never sees the password). Ad-hoc-signed apps can't use data-protection-keychain access
//    control, so the biometric/password check is an app-level gate on top of encryption at rest.
//  - Method `.password`: only the data key wrapped under a PBKDF2-SHA256 KEK of the user's DittoMac password
//    (+ salt, iterations, verifier) is stored, so locked notes can't be decrypted without the password.
// While unlocked the key sits in `state.store.vaultKey`; it is cleared after inactivity, on sleep / screen lock
// (setting), on quit, and by `lockNow()`. Passwords and keys are never logged or written to UserDefaults.
// Design and threat model: docs/kb/vault.md.

import AppKit
import CryptoKit
import DittoCore
import LocalAuthentication
import Security

extension Notification.Name {
    /// Posted (main thread) when the vault locks, unlocks, is set up / reset, or its method or settings change.
    static let dittoVaultChanged = Notification.Name("io.github.dittomac.vaultChanged")
}

/// Generic-password items for the vault (separate service from `Keychain`, values never logged).
private enum VaultKeychain {
    static let service = "io.github.dittomac.vault"
    static let dataKeyAccount = "dataKey"          // .system: raw 32-byte data key
    static let wrappedKeyAccount = "wrappedKey"    // .password: JSON Vault.WrappedKey (no plaintext key)

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func set(_ data: Data, account: String) throws {
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                    kSecAttrLabel as String: "DittoMac locked notes",
                                    kSecAttrSynchronizable as String: false]
        var status = SecItemUpdate(base(account) as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(account)
            add.merge(attrs) { $1 }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Keychain.KeychainError(status: status) }
    }

    /// Outcome of reading a vault item. Only `.notFound` is definitive; any other failure (access denied after an
    /// ad-hoc re-sign, user cancelled the Keychain prompt, Keychain locked) is transient and must never steer the
    /// user toward Reset Vault.
    enum ReadResult {
        case found(Data)
        case notFound
        case failed(OSStatus)
    }

    static func read(account: String) -> ReadResult {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            if let d = out as? Data { return .found(d) }
            return .failed(errSecDecode)
        case errSecItemNotFound: return .notFound
        default: return .failed(status)
        }
    }

    static func get(account: String) -> Data? {
        if case .found(let d) = read(account: account) { return d }
        return nil
    }

    /// Message for a vault-key read that failed, or nil when the item is simply absent (the caller then shows the
    /// reset guidance).
    static func deniedMessage(_ r: ReadResult) -> String? {
        guard case .failed(let status) = r else { return nil }
        return "Keychain denied access — choose Always Allow and retry. DittoMac couldn’t read the key for your locked notes "
            + "from your login Keychain (error \(status)). Your notes are not lost; try again, and click Always Allow when "
            + "macOS asks."
    }

    /// Existence check that doesn't read the secret (no Keychain access prompt).
    static func exists(account: String) -> Bool {
        var q = base(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    static func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}

@MainActor
final class VaultService: VaultServicing {
    unowned let state: AppState
    private var settings: DittoCore.Settings { state.settings }

    private var lastActivity = Date()
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var authInProgress = false
    private var pendingUnlock: [(Bool) -> Void] = []
    /// Wrong DittoMac password back-off: 3 free tries, then 1 s, 2 s, 4 s … capped at 30 s.
    private var failedAttempts = 0
    private var retryAfter = Date.distantPast

    static let freeAttempts = 3
    static let maxBackoff: TimeInterval = 30

    init(state: AppState) {
        self.state = state
        recoverConfiguration()
        installObservers()
    }

    // MARK: VaultServicing

    var isSetUp: Bool { settings.vaultConfigured }
    var method: VaultMethod { VaultMethod(rawValue: settings.vaultMethod) ?? .system }
    var isUnlocked: Bool { state.store.vaultKey != nil }

    var autoLockMinutes: Int {
        get { settings.vaultAutoLockMinutes }
        set {
            settings.vaultAutoLockMinutes = newValue
            noteActivity()
            postVaultChanged()
        }
    }

    func requestUnlock(reason: String, completion: @escaping (Bool) -> Void) {
        if isUnlocked { noteActivity(); completion(true); return }
        guard isSetUp else { completion(false); return }
        pendingUnlock.append(completion)
        guard !authInProgress else { return }
        authInProgress = true
        switch method {
        case .system:
            authenticateSystem(reason: reason) { [weak self] ok, message in
                guard let self else { return }
                guard ok else {
                    if let message { VaultPrompts.showError("Couldn’t unlock your notes", message) }
                    self.finishUnlock(false)
                    return
                }
                let read = VaultKeychain.read(account: VaultKeychain.dataKeyAccount)
                if let denied = VaultKeychain.deniedMessage(read) {
                    VaultPrompts.showError("Keychain denied access", denied)
                    self.finishUnlock(false)
                    return
                }
                guard case .found(let raw) = read, let key = try? Vault.key(from: raw) else {
                    VaultPrompts.showError("The vault key is missing",
                                           "DittoMac couldn’t read the key for your locked notes from your login Keychain. "
                                           + "If it was deleted, the notes can’t be recovered; use Reset Vault in "
                                           + "Preferences ▸ Security to start over.")
                    self.finishUnlock(false)
                    return
                }
                self.setUnlocked(key)
                self.finishUnlock(true)
            }
        case .password:
            promptPasswordUnlock(reason: reason, error: nil)
        }
    }

    func lockNow() {
        state.store.vaultKey = nil
        timer?.invalidate()
        timer = nil
        ClipDragWriter.purgeLockedStaging()     // plaintext files staged for dragging locked notes out
        postVaultChanged()
        state.clipsChanged()
    }

    func lock(clipIDs: [Int64], completion: @escaping (Bool) -> Void) {
        let ids = clipIDs.filter { (try? state.store.clip(id: $0)).flatMap { $0.map { !$0.isGroup && !$0.isLocked } } ?? false }
        guard !ids.isEmpty else { completion(false); return }
        guard isSetUp else {
            runSetup { [weak self] ok in
                guard let self, ok else { completion(false); return }
                self.performLock(ids, completion: completion)
            }
            return
        }
        performLock(ids, completion: completion)
    }

    func removeLock(clipIDs: [Int64], completion: @escaping (Bool) -> Void) {
        guard !clipIDs.isEmpty, isSetUp else { completion(false); return }
        let n = clipIDs.count
        requestUnlock(reason: n == 1 ? "remove the lock from a note" : "remove the lock from \(n) notes") { [weak self] ok in
            guard let self, ok else { completion(false); return }
            do {
                let done = try self.state.store.removeLock(ids: clipIDs)
                self.noteActivity()
                self.state.clipsChanged()
                self.postVaultChanged()
                if done > 0 { self.state.message(done == 1 ? "Lock removed" : "Lock removed from \(done) notes") }
                completion(done > 0)
            } catch {
                VaultPrompts.showError("Couldn’t remove the lock", error.localizedDescription)
                completion(false)
            }
        }
    }

    func configure(method newMethod: VaultMethod, newPassword: String?, completion: @escaping (Bool) -> Void) {
        guard isSetUp else {
            setUp(method: newMethod, password: newPassword, verifySystemAuth: true, completion: completion)
            return
        }
        // Changing the method or password always needs fresh proof (Touch ID / Mac password, or the current DittoMac
        // password), even when the session is already unlocked: otherwise anyone at an unlocked session could swap
        // the password, or move a password-protected key into the Keychain (`.system`).
        reauthenticate(reason: "change how your locked notes are protected") { [weak self] ok in
            guard let self, ok, let key = self.state.store.vaultKey else { completion(false); return }
            self.storeKey(key, method: newMethod, password: newPassword) { stored in
                if stored { self.noteActivity(); self.postVaultChanged() }
                completion(stored)
            }
        }
    }

    // MARK: extras for the UI (cast `state.vault as? VaultService`)

    /// Number of locked clips in the database.
    var lockedCount: Int { (try? state.store.lockedCount()) ?? 0 }

    /// When the unlocked session will lock by itself (nil when locked or auto-lock is off).
    var autoLockDate: Date? {
        guard isUnlocked, autoLockMinutes > 0 else { return nil }
        return lastActivity.addingTimeInterval(TimeInterval(autoLockMinutes * 60))
    }

    /// "Locked", "Unlocked — locks in 4 min", "Not set up" …
    var statusText: String {
        guard isSetUp else { return "Not set up" }
        guard isUnlocked else { return "Locked" }
        guard let when = autoLockDate else { return "Unlocked until DittoMac quits" }
        let secs = max(0, Int(when.timeIntervalSinceNow.rounded(.up)))
        if secs < 60 { return "Unlocked — locks in \(secs) s" }
        return "Unlocked — locks in \((secs + 59) / 60) min"
    }

    /// Extend the unlocked session (call when the user views / pastes / edits a locked note).
    func noteActivity() {
        lastActivity = Date()
        if isUnlocked { startTimer() }
    }

    /// Deliberately delete clips that may be locked: authenticates, confirms (when `confirm`), then deletes.
    func deleteLockedClips(clipIDs: [Int64], confirm: Bool = true, completion: @escaping (Bool) -> Void) {
        guard !clipIDs.isEmpty else { completion(false); return }
        requestUnlock(reason: "delete locked notes") { [weak self] ok in
            guard let self, ok else { completion(false); return }
            if confirm, !VaultPrompts.confirmDeleteLocked(count: clipIDs.count) { completion(false); return }
            do {
                let n = try self.state.store.deleteLocked(ids: clipIDs)
                self.noteActivity()
                self.state.clipsChanged()
                self.postVaultChanged()
                completion(n > 0)
            } catch {
                VaultPrompts.showError("Couldn’t delete", error.localizedDescription)
                completion(false)
            }
        }
    }

    /// Forgotten password / lost key: after a typed confirmation, permanently deletes every locked clip and the
    /// vault key, and returns the vault to "not set up".
    func resetVault(completion: @escaping (Bool) -> Void) {
        guard VaultPrompts.confirmReset(lockedCount: lockedCount) else { completion(false); return }
        do {
            try state.store.purgeLockedClips()
        } catch {
            VaultPrompts.showError("Couldn’t reset the vault", error.localizedDescription)
            completion(false)
            return
        }
        state.store.vaultKey = nil
        timer?.invalidate()
        timer = nil
        ClipDragWriter.purgeLockedStaging()
        VaultKeychain.delete(account: VaultKeychain.dataKeyAccount)
        VaultKeychain.delete(account: VaultKeychain.wrappedKeyAccount)
        settings.vaultConfigured = false
        settings.vaultMethod = VaultMethod.system.rawValue
        failedAttempts = 0
        retryAfter = .distantPast
        state.clipsChanged()
        postVaultChanged()
        completion(true)
    }

    // MARK: lock / unlock internals

    private func performLock(_ ids: [Int64], completion: @escaping (Bool) -> Void) {
        func finish(_ key: SymmetricKey?, session: Bool) {
            do {
                let n = session ? try state.store.lock(ids: ids) : try state.store.lock(ids: ids, key: key!)
                state.clipsChanged()
                postVaultChanged()
                if n > 0 { state.message(n == 1 ? "Note locked" : "\(n) notes locked") }
                completion(n > 0)
            } catch {
                VaultPrompts.showError("Couldn’t lock", error.localizedDescription)
                completion(false)
            }
        }
        if isUnlocked { noteActivity(); finish(nil, session: true); return }
        // Locking reveals nothing, so with the system method the Keychain key is used directly (no prompt and
        // the session stays locked). The password method has no stored key: it needs the password.
        if method == .system, let raw = VaultKeychain.get(account: VaultKeychain.dataKeyAccount),
           let key = try? Vault.key(from: raw) {
            finish(key, session: false)
            return
        }
        requestUnlock(reason: "lock more notes") { ok in
            guard ok else { completion(false); return }
            finish(nil, session: true)
        }
    }

    private func setUnlocked(_ key: SymmetricKey) {
        state.store.vaultKey = key
        failedAttempts = 0
        retryAfter = .distantPast
        noteActivity()
        state.clipsChanged()
        postVaultChanged()
    }

    private func finishUnlock(_ ok: Bool) {
        authInProgress = false
        let callbacks = pendingUnlock
        pendingUnlock = []
        callbacks.forEach { $0(ok) }
    }

    /// LocalAuthentication prompt (Touch ID, or the Mac login password). `message` is nil on user cancel.
    private func authenticateSystem(reason: String, completion: @escaping @MainActor (Bool, String?) -> Void) {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            completion(false, (err?.localizedDescription ?? "This Mac can’t verify your identity.")
                       + " Your Mac account needs a login password. You can use a DittoMac password instead.")
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            var message: String?
            if !ok, let e = error as? LAError,
               ![.userCancel, .systemCancel, .appCancel].contains(e.code) {
                message = e.localizedDescription
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(ok, message) } }
        }
    }

    private func promptPasswordUnlock(reason: String, error: String?) {
        let read = VaultKeychain.read(account: VaultKeychain.wrappedKeyAccount)
        if let denied = VaultKeychain.deniedMessage(read) {
            VaultPrompts.showError("Keychain denied access", denied)
            finishUnlock(false)
            return
        }
        guard case .found(let blob) = read, let wrapped = try? Vault.WrappedKey.decode(blob) else {
            VaultPrompts.showError("The vault key is missing",
                                   "DittoMac couldn’t read the protected key for your locked notes from your login Keychain. "
                                   + "Use Reset Vault in Preferences ▸ Security to start over.")
            finishUnlock(false)
            return
        }
        guard let password = VaultPrompts.askPassword(reason: reason, error: error ?? backoffMessage()) else {
            finishUnlock(false)
            return
        }
        if Date() < retryAfter {   // too early: not checked, not counted
            promptPasswordUnlock(reason: reason, error: nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Vault.unwrap(wrapped, password: password) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case .success(let key):
                        self.setUnlocked(key)
                        self.finishUnlock(true)
                    case .failure(let e):
                        if case VaultError.wrongPassword = e {
                            self.registerFailure()
                            self.promptPasswordUnlock(reason: reason, error: "Wrong password." + (self.backoffMessage().map { " " + $0 } ?? ""))
                        } else {
                            VaultPrompts.showError("Couldn’t unlock your notes", e.localizedDescription)
                            self.finishUnlock(false)
                        }
                    }
                }
            }
        }
    }

    /// Fresh authentication even when the session is unlocked (a locked session simply unlocks).
    private func reauthenticate(reason: String, completion: @escaping (Bool) -> Void) {
        guard isUnlocked else { requestUnlock(reason: reason, completion: completion); return }
        guard !authInProgress else { completion(false); return }
        authInProgress = true
        let done: (Bool) -> Void = { [weak self] ok in
            self?.authInProgress = false
            completion(ok)
        }
        switch method {
        case .system:
            authenticateSystem(reason: reason) { ok, message in
                if !ok, let message { VaultPrompts.showError("Couldn’t verify it’s you", message) }
                done(ok)
            }
        case .password:
            verifyPassword(reason: reason, error: nil, completion: done)
        }
    }

    /// Checks the current DittoMac password (same back-off as unlocking) without changing the session.
    private func verifyPassword(reason: String, error: String?, completion: @escaping (Bool) -> Void) {
        let read = VaultKeychain.read(account: VaultKeychain.wrappedKeyAccount)
        if let denied = VaultKeychain.deniedMessage(read) {
            VaultPrompts.showError("Keychain denied access", denied)
            completion(false)
            return
        }
        guard case .found(let blob) = read, let wrapped = try? Vault.WrappedKey.decode(blob) else { completion(false); return }
        guard let password = VaultPrompts.askPassword(reason: reason, error: error ?? backoffMessage()) else {
            completion(false)
            return
        }
        if Date() < retryAfter {   // too early: not checked, not counted
            verifyPassword(reason: reason, error: nil, completion: completion)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Vault.unwrap(wrapped, password: password) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case .success:
                        self.failedAttempts = 0
                        self.retryAfter = .distantPast
                        completion(true)
                    case .failure(let e):
                        if case VaultError.wrongPassword = e {
                            self.registerFailure()
                            self.verifyPassword(reason: reason, error: "Wrong password." + (self.backoffMessage().map { " " + $0 } ?? ""),
                                                completion: completion)
                        } else {
                            VaultPrompts.showError("Couldn’t verify your password", e.localizedDescription)
                            completion(false)
                        }
                    }
                }
            }
        }
    }

    private func registerFailure() {
        failedAttempts += 1
        let over = failedAttempts - Self.freeAttempts
        guard over > 0 else { return }
        let delay = min(Self.maxBackoff, pow(2, Double(over - 1)))
        retryAfter = Date().addingTimeInterval(delay)
    }

    private func backoffMessage() -> String? {
        let wait = retryAfter.timeIntervalSinceNow
        guard wait > 0 else { return nil }
        return "Too many attempts: wait \(Int(wait.rounded(.up))) s before trying again."
    }

    // MARK: setup / key storage

    private func runSetup(completion: @escaping (Bool) -> Void) {
        guard let choice = VaultPrompts.chooseMethod() else { completion(false); return }
        setUp(method: choice, password: nil, verifySystemAuth: true, completion: completion)
    }

    private func setUp(method newMethod: VaultMethod, password: String?, verifySystemAuth: Bool,
                       completion: @escaping (Bool) -> Void) {
        let key = Vault.newDataKey()
        let finish: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            if ok {
                self.settings.vaultConfigured = true
                self.setUnlocked(key)
            }
            completion(ok)
        }
        if newMethod == .system && verifySystemAuth {
            authenticateSystem(reason: "set up locked notes") { [weak self] ok, message in
                guard let self else { return }
                guard ok else {
                    if let message { VaultPrompts.showError("Couldn’t use your Mac password", message) }
                    completion(false)
                    return
                }
                self.storeKey(key, method: .system, password: nil, completion: finish)
            }
        } else {
            storeKey(key, method: newMethod, password: password, completion: finish)
        }
    }

    /// Persists `key` for `newMethod` (new item first, then the old one is removed).
    private func storeKey(_ key: SymmetricKey, method newMethod: VaultMethod, password: String?,
                          completion: @escaping (Bool) -> Void) {
        switch newMethod {
        case .system:
            do {
                try VaultKeychain.set(Vault.keyData(key), account: VaultKeychain.dataKeyAccount)
            } catch {
                VaultPrompts.showError("Couldn’t save the vault key", error.localizedDescription)
                completion(false)
                return
            }
            VaultKeychain.delete(account: VaultKeychain.wrappedKeyAccount)
            settings.vaultMethod = VaultMethod.system.rawValue
            completion(true)
        case .password:
            let pw: String
            if let password, Vault.passwordProblem(password) == nil {
                pw = password
            } else {
                guard let entered = VaultPrompts.newPassword(error: password.flatMap(Vault.passwordProblem)) else {
                    completion(false)
                    return
                }
                pw = entered
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try Vault.wrap(dataKey: key, password: pw).encoded() }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        do {
                            try VaultKeychain.set(try result.get(), account: VaultKeychain.wrappedKeyAccount)
                        } catch {
                            VaultPrompts.showError("Couldn’t save the vault key", error.localizedDescription)
                            completion(false)
                            return
                        }
                        VaultKeychain.delete(account: VaultKeychain.dataKeyAccount)
                        self.settings.vaultMethod = VaultMethod.password.rawValue
                        completion(true)
                    }
                }
            }
        }
    }

    /// If settings were lost but locked clips or vault Keychain items remain, treat the vault as set up again
    /// (otherwise a new key would be created and the old notes would become unreadable).
    private func recoverConfiguration() {
        guard !settings.vaultConfigured else { return }
        let hasData = VaultKeychain.exists(account: VaultKeychain.dataKeyAccount)
        let hasWrapped = VaultKeychain.exists(account: VaultKeychain.wrappedKeyAccount)
        guard hasData || hasWrapped || lockedCount > 0 else { return }
        settings.vaultConfigured = true
        if hasWrapped && !hasData { settings.vaultMethod = VaultMethod.password.rawValue }
        else if hasData { settings.vaultMethod = VaultMethod.system.rawValue }
    }

    // MARK: auto-lock

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAutoLock() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func checkAutoLock() {
        guard isUnlocked else { timer?.invalidate(); timer = nil; return }
        if let when = autoLockDate, Date() >= when { lockNow() }
    }

    private func installObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        let lockIfEnabled: @MainActor () -> Void = { [weak self] in
            guard let self, self.settings.vaultLockOnSleep, self.isUnlocked else { return }
            self.lockNow()
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let token = ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lockIfEnabled() }
            }
            observers.append((ws, token))
        }
        let dist = DistributedNotificationCenter.default()
        let token = dist.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { lockIfEnabled() }
        }
        observers.append((dist, token))
        let quit = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.store.vaultKey = nil }
        }
        observers.append((NotificationCenter.default, quit))
    }

    private func postVaultChanged() {
        NotificationCenter.default.post(name: .dittoVaultChanged, object: nil)
    }
}
