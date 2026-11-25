// Vault crypto primitives for locked clips / sticky notes (pure CryptoKit + CommonCrypto, no UI, no Keychain).
//
//  - Data key: random 256-bit AES key. Every locked blob is AES-256-GCM sealed under it (combined
//    representation: 12-byte nonce ‖ ciphertext ‖ 16-byte tag) with AAD that binds the blob to its row.
//  - Password method: the data key is wrapped (AES-GCM, AAD "DittoMac vault wrap v1") under a KEK derived
//    from the user's DittoMac password with PBKDF2-HMAC-SHA256 (600 000 iterations by default).
//  - Nothing here logs, prints or persists secrets. See docs/kb/vault.md.

import Foundation
import CryptoKit
import CommonCrypto
import Security

public enum VaultError: Error, Equatable, LocalizedError {
    case invalidCiphertext
    case wrongPassword
    case weakPassword(String)
    case keyDerivationFailed
    case invalidKey
    case unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .invalidCiphertext: return "The locked data is damaged or was encrypted with a different key."
        case .wrongPassword: return "The password is incorrect."
        case .weakPassword(let why): return why
        case .keyDerivationFailed: return "Could not derive a key from the password."
        case .invalidKey: return "The vault key is invalid."
        case .unsupportedVersion: return "The vault was created by a newer version of DittoMac."
        }
    }
}

public enum PasswordStrength: Int, Sendable, Comparable {
    case tooShort, weak, fair, strong
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .tooShort: return "Too short (at least \(Vault.minPasswordLength) characters)"
        case .weak: return "Weak: use more characters or mix letters, digits and symbols"
        case .fair: return "Fair"
        case .strong: return "Strong"
        }
    }
}

public enum Vault {
    public static let keyByteCount = 32
    public static let saltByteCount = 16
    public static let defaultIterations = 600_000
    /// Any stored or supplied iteration count is clamped into this range (protects against a tampered
    /// settings blob that asks for 1 iteration, or one that asks for 2^31 and hangs the app).
    public static let iterationRange: ClosedRange<Int> = 100_000...2_000_000
    public static let minPasswordLength = 8
    /// AES-GCM combined-representation overhead (nonce + tag).
    public static let sealOverhead = 12 + 16
    public static let wrapAAD = Data("DittoMac vault wrap v1".utf8)
    static let verifierLabel = Data("DittoMac vault verifier v1".utf8)

    // MARK: keys & randomness

    public static func newDataKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    public static func randomBytes(_ count: Int) -> Data {
        var out = Data(count: count)
        let rc = out.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        if rc != errSecSuccess {   // practically never; fall back to CryptoKit's CSPRNG
            return SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
        }
        return out
    }

    /// Raw bytes of a key (for Keychain storage only).
    public static func keyData(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    public static func key(from data: Data) throws -> SymmetricKey {
        guard data.count == keyByteCount else { throw VaultError.invalidKey }
        return SymmetricKey(data: data)
    }

    // MARK: AES-256-GCM

    /// Seals `data` (AES-256-GCM, random nonce) and returns the combined representation.
    public static func seal(_ data: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, authenticating: aad)
        guard let combined = box.combined else { throw VaultError.invalidCiphertext }
        return combined
    }

    /// Opens a combined AES-GCM blob. Throws `.invalidCiphertext` on any tampering, wrong key or wrong AAD.
    public static func open(_ sealed: Data, key: SymmetricKey, aad: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw VaultError.invalidCiphertext
        }
    }

    // MARK: PBKDF2

    public static func clampIterations(_ n: Int) -> Int { clampIterations(n, minimum: iterationRange.lowerBound) }

    static func clampIterations(_ n: Int, minimum: Int) -> Int {
        min(max(n, minimum), iterationRange.upperBound)
    }

    /// PBKDF2-HMAC-SHA256 → 256-bit key. The password is NFC-normalised so the same visible password
    /// typed on different keyboards derives the same key.
    public static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        try deriveKey(password: password, salt: salt, iterations: iterations, minimumIterations: iterationRange.lowerBound)
    }

    /// Test hook: `minimumIterations` lowers the clamp floor so unit tests stay fast.
    static func deriveKey(password: String, salt: Data, iterations: Int, minimumIterations: Int) throws -> SymmetricKey {
        let rounds = clampIterations(iterations, minimum: minimumIterations)
        var pw = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var pwBuffer: [UInt8] = pw.isEmpty ? [0] : pw     // non-nil base address for an empty password
        // Best effort: wipe our copies of the password bytes (Swift Strings themselves can't be zeroed).
        defer {
            for i in pw.indices { pw[i] = 0 }
            for i in pwBuffer.indices { pwBuffer[i] = 0 }
        }
        var out = [UInt8](repeating: 0, count: keyByteCount)
        let rc = salt.withUnsafeBytes { saltBuf -> Int32 in
            pwBuffer.withUnsafeBufferPointer { pwBuf -> Int32 in
                pwBuf.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pwBuffer.count) { pwPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwPtr, pw.count,
                                         saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                         &out, out.count)
                }
            }
        }
        guard rc == Int32(kCCSuccess) else { throw VaultError.keyDerivationFailed }
        defer { for i in out.indices { out[i] = 0 } }
        return SymmetricKey(data: out)
    }

    // MARK: verifier / constant time

    /// HMAC-SHA256(KEK, label). Lets unlock reject a wrong password before attempting AES-GCM and
    /// distinguish "wrong password" from "damaged blob". Reveals nothing beyond what the GCM tag does.
    public static func passwordVerifier(kek: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: verifierLabel, using: kek))
    }

    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }

    // MARK: wrapping

    /// Everything stored for the password method. Contains no plaintext key and no password.
    public struct WrappedKey: Codable, Equatable, Sendable {
        public var version: Int
        public var salt: Data
        public var iterations: Int
        public var wrapped: Data        // AES-GCM(KEK, dataKey, AAD wrapAAD)
        public var verifier: Data       // passwordVerifier(KEK)

        public init(version: Int = 1, salt: Data, iterations: Int, wrapped: Data, verifier: Data) {
            self.version = version
            self.salt = salt
            self.iterations = iterations
            self.wrapped = wrapped
            self.verifier = verifier
        }

        public func encoded() throws -> Data { try JSONEncoder().encode(self) }
        public static func decode(_ data: Data) throws -> WrappedKey { try JSONDecoder().decode(WrappedKey.self, from: data) }
    }

    public static func wrap(dataKey: SymmetricKey, password: String, iterations: Int = defaultIterations) throws -> WrappedKey {
        try wrap(dataKey: dataKey, password: password, iterations: iterations, minimumIterations: iterationRange.lowerBound)
    }

    static func wrap(dataKey: SymmetricKey, password: String, iterations: Int, minimumIterations: Int) throws -> WrappedKey {
        if let problem = passwordProblem(password) { throw VaultError.weakPassword(problem) }
        let salt = randomBytes(saltByteCount)
        let rounds = clampIterations(iterations, minimum: minimumIterations)
        let kek = try deriveKey(password: password, salt: salt, iterations: rounds, minimumIterations: minimumIterations)
        let wrapped = try seal(keyData(dataKey), key: kek, aad: wrapAAD)
        return WrappedKey(salt: salt, iterations: rounds, wrapped: wrapped, verifier: passwordVerifier(kek: kek))
    }

    public static func unwrap(_ w: WrappedKey, password: String) throws -> SymmetricKey {
        try unwrap(w, password: password, minimumIterations: iterationRange.lowerBound)
    }

    static func unwrap(_ w: WrappedKey, password: String, minimumIterations: Int) throws -> SymmetricKey {
        guard w.version == 1 else { throw VaultError.unsupportedVersion }
        let kek = try deriveKey(password: password, salt: w.salt, iterations: w.iterations, minimumIterations: minimumIterations)
        guard constantTimeEqual(passwordVerifier(kek: kek), w.verifier) else { throw VaultError.wrongPassword }
        let raw: Data
        do { raw = try open(w.wrapped, key: kek, aad: wrapAAD) } catch { throw VaultError.wrongPassword }
        return try key(from: raw)
    }

    // MARK: password policy

    /// nil when acceptable, otherwise a user-facing reason.
    public static func passwordProblem(_ password: String) -> String? {
        if password.count < minPasswordLength { return "The password must have at least \(minPasswordLength) characters." }
        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The password can’t be only spaces." }
        return nil
    }

    public static func strength(_ p: String) -> PasswordStrength {
        guard p.count >= minPasswordLength else { return .tooShort }
        var classes = 0
        if p.rangeOfCharacter(from: .lowercaseLetters) != nil { classes += 1 }
        if p.rangeOfCharacter(from: .uppercaseLetters) != nil { classes += 1 }
        if p.rangeOfCharacter(from: .decimalDigits) != nil { classes += 1 }
        if p.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) != nil { classes += 1 }
        let distinct = Set(p).count
        if distinct <= 3 { return .weak }
        if p.count >= 16 || (p.count >= 12 && classes >= 3) { return .strong }
        if p.count >= 10 || classes >= 3 { return .fair }
        return .weak
    }

    // MARK: AAD helpers (used by ClipStore)

    static func dataAAD(clipID: Int64, type: String) -> Data { Data(("clip|" + String(clipID) + "|" + type).utf8) }
    static func textAAD(clipID: Int64) -> Data { Data(("text|" + String(clipID)).utf8) }
}
