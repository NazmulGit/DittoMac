// Keychain.swift — minimal generic-password wrapper. Values never logged.

import Foundation
import Security

enum Keychain {
    static let service = "io.github.dittomac"

    struct KeychainError: Error, LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain error \(status)" }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        setPresence(true, account: account)
    }

    static func get(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        setPresence(false, account: account)
    }

    // MARK: presence (no secret read)

    private static let presenceLock = NSLock()
    nonisolated(unsafe) private static var presence: [String: Bool] = [:]

    private static func setPresence(_ v: Bool, account: String) {
        presenceLock.lock(); presence[account] = v; presenceLock.unlock()
    }

    /// Existence check that never fetches the secret (attributes only, so no Keychain access prompt).
    static func exists(account: String) -> Bool {
        var query = baseQuery(account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    /// Cached `exists`: the Keychain is queried once per account and then only after `set` / `delete` (or
    /// `refreshPresence`). Safe to call from SwiftUI bodies on the main thread.
    static func has(account: String) -> Bool {
        presenceLock.lock()
        let cached = presence[account]
        presenceLock.unlock()
        if let cached { return cached }
        let v = exists(account: account)
        setPresence(v, account: account)
        return v
    }

    /// Forgets the cached answer for `account` (the next `has` asks the Keychain again).
    static func refreshPresence(account: String) {
        presenceLock.lock(); presence[account] = nil; presenceLock.unlock()
    }
}
