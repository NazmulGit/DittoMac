// FriendsProtocol.swift
//
// Secure LAN clip-sharing ("Friends") wire protocol for DittoMac. Pure logic: Foundation, CryptoKit and
// CommonCrypto only. The app layer owns sockets and drives this API with bytes.
//
// DESIGN (see docs/kb/friends-protocol.md and docs/kb/security-review-port.md)
//
//  Long-term key  : PBKDF2-HMAC-SHA256(passphrase NFC/UTF-8, salt "DittoMac-Friends-v1", 600_000 iterations).
//                   Iterations and salt are LOCAL constants and are never read from the wire.
//  Ephemeral key  : every FriendsSession generates a fresh Curve25519 (X25519) key-agreement key in init.
//                   It is never persisted or reused, and is discarded once the session keys are derived.
//  Hello (unframed, self-delimiting; protocol version 2, version 1 is rejected):
//                   "DMF1" | version u8 (=2) | nonce[32] | ephPub[32] | nameLen u8 (<=64) | name (UTF-8) | mac[32]
//                   mac = HMAC-SHA256(longTermKey, "DittoMac v2 hello" | roleByte | nonce | ephPub | nameLen | name);
//                   role: client=1, server=2. Use `FriendsHello.totalLength(prefix:)` to learn the Hello length
//                   (at most `FriendsProtocol.maxHelloBytes`).
//  Session keys   : dh  = X25519(ownEphemeral, peerEphemeral)  (all-zero / invalid points rejected)
//                   psk = HMAC-SHA256(longTermKey, "DittoMac v2 psk")
//                   HKDF-SHA256(ikm: dh | psk, salt: clientNonce | serverNonce | clientPub | serverPub,
//                   info: "DittoMac v2 c2s" / "DittoMac v2 s2c") -> one 32-byte key per direction.
//                   Forward secrecy: recording a session and later learning the passphrase does not reveal the
//                   session keys (the ephemeral private keys are gone). Hello MACs still allow an offline
//                   passphrase guess by anyone who sees a Hello; a PAKE would be needed to remove that.
//  Frames         : u32 big-endian length (<= maxFrameBytes) | ChaChaPoly combined (nonce12 | ciphertext | tag16).
//                   nonce = 4 zero bytes | u64 big-endian counter, starting at 0 per direction; the receiver
//                   requires exactly the next expected counter (no replay, no reorder, no drop-and-continue).
//                   AAD = "DMF1" | directionByte (0 = client->server, 1 = server->client).
//  First frame    : each side's first encrypted frame must be `.confirm` (wrong passphrase fails fast).
//  Messages       : explicit binary encoding, fixed-width big-endian integers, every length bounds-checked.
//                   There is NO file-request message.
//
// Caps: frame 16 MiB, clip data 16 MiB - 64 KiB (so a maximal clip fits one frame), description 4096 B,
// device name 64 B, <=16 formats, format type <=128 B of [A-Za-z0-9.-].
//
// Threading: a FriendsSession is not thread-safe; use it from one queue. Errors never contain key material.

import Foundation
import CryptoKit
import CommonCrypto

// MARK: - Errors

public enum FriendsError: Error, Equatable {
    case invalidPassphrase
    case malformedHello
    case unsupportedVersion
    case invalidDeviceName
    case authenticationFailed        // hello MAC mismatch (wrong passphrase / wrong role / tampering)
    case invalidPublicKey            // peer ephemeral key all-zero, invalid, or yields an all-zero shared secret
    case handshakeNotComplete
    case handshakeAlreadyComplete
    case frameTooLarge
    case frameTooSmall
    case malformedFrame
    case decryptionFailed
    case unexpectedCounter           // replay / reorder / drop
    case counterExhausted
    case confirmRequired             // first frame in a direction must be Confirm
    case malformedMessage
    case unknownMessageType
    case invalidField                // string/UTI/length violation
    case tooManyFormats
    case clipTooLarge
    case trailingBytes
}

// MARK: - Constants and key derivation

public enum FriendsProtocol {
    public static let port: UInt16 = 23443
    public static let maxFrameBytes = 16 * 1024 * 1024
    public static let maxClipDataBytes = maxFrameBytes - 64 * 1024
    public static let maxDescriptionBytes = 4096
    public static let maxDeviceNameBytes = 64
    public static let maxFormats = 16
    public static let maxFormatTypeBytes = 128
    public static let minPassphraseLength = 12
    public static let maxPassphraseBytes = 1024
    public static let kdfIterations = 600_000

    static let magic: [UInt8] = Array("DMF1".utf8)
    static let version: UInt8 = 2
    static let nonceBytes = 32
    static let publicKeyBytes = 32
    static let macBytes = 32
    /// Largest possible Hello on the wire (maximal device name).
    public static let maxHelloBytes = FriendsHello.nameLengthOffset + 1 + maxDeviceNameBytes + macBytes
    static let appSalt = Data("DittoMac-Friends-v1".utf8)
    /// 12-byte nonce + 16-byte tag + at least 1 plaintext byte.
    static let minSealedBytes = 12 + 16 + 1

    public static func validatePassphrase(_ s: String) -> Bool {
        s.count >= minPassphraseLength && s.utf8.count <= maxPassphraseBytes
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: SymmetricKey] = [:]

    /// Derive (and cache per passphrase) the long-term key with the production KDF parameters.
    /// Slow by design (~0.3 s); call off the main thread.
    public static func deriveKey(passphrase: String) -> SymmetricKey {
        let id = cacheID(passphrase)
        cacheLock.lock()
        if let k = cache[id] { cacheLock.unlock(); return k }
        cacheLock.unlock()
        let k = deriveKey(passphrase: passphrase, iterations: kdfIterations)
        cacheLock.lock()
        cache[id] = k
        cacheLock.unlock()
        return k
    }

    /// Test hook: low iteration counts only ever come from local callers, never the wire.
    static func deriveKey(passphrase: String, iterations: Int) -> SymmetricKey {
        let pw = passphrase.precomposedStringWithCanonicalMapping.utf8.map { Int8(bitPattern: $0) }
        var out = [UInt8](repeating: 0, count: 32)
        let salt = [UInt8](appSalt)
        let status = pw.withUnsafeBufferPointer { pwp in
            salt.withUnsafeBufferPointer { sp in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwp.baseAddress,
                    pw.count, sp.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations), &out, out.count)
            }
        }
        precondition(status == Int32(kCCSuccess), "PBKDF2 failed")
        let key = SymmetricKey(data: out)
        for i in out.indices { out[i] = 0 }
        return key
    }

    private static func cacheID(_ p: String) -> String {
        let d = SHA256.hash(data: Data(p.precomposedStringWithCanonicalMapping.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Roles

public enum FriendsRole: UInt8 {
    case client = 1
    case server = 2
    var peer: FriendsRole { self == .client ? .server : .client }
}

// MARK: - Byte helpers

struct ByteWriter {
    var bytes = [UInt8]()
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xff)) }
    mutating func u32(_ v: UInt32) { for s in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func u64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((v >> UInt64(s)) & 0xff)) } }
    mutating func raw<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes.append(contentsOf: s) }
}

struct ByteReader {
    let bytes: [UInt8]
    var pos = 0
    init(_ d: Data) { bytes = [UInt8](d) }
    var remaining: Int { bytes.count - pos }
    mutating func take(_ n: Int, _ err: FriendsError = .malformedMessage) throws -> ArraySlice<UInt8> {
        guard n >= 0, n <= remaining else { throw err }
        defer { pos += n }
        return bytes[pos ..< pos + n]
    }
    mutating func u16() throws -> Int { let s = try take(2); return s.reduce(0) { ($0 << 8) | Int($1) } }
    mutating func u32() throws -> Int { let s = try take(4); return s.reduce(0) { ($0 << 8) | Int($1) } }
}

// MARK: - Hello

public struct FriendsHello: Equatable {
    public let nonce: Data
    /// The sender's ephemeral X25519 public key (32 bytes raw representation).
    public let ephemeralPublicKey: Data
    public let deviceName: String
    public let mac: Data

    static let publicKeyOffset = 4 + 1 + FriendsProtocol.nonceBytes
    static let nameLengthOffset = publicKeyOffset + FriendsProtocol.publicKeyBytes

    static func macInput(role: FriendsRole, nonce: Data, ephemeralPublicKey: Data, name: Data) -> Data {
        var d = Data("DittoMac v2 hello".utf8)
        d.append(role.rawValue)
        d.append(nonce)
        d.append(ephemeralPublicKey)
        d.append(UInt8(name.count))
        d.append(name)
        return d
    }

    static func make(role: FriendsRole, key: SymmetricKey, nonce: Data, ephemeralPublicKey: Data, deviceName: String) -> FriendsHello {
        let name = Data(deviceName.utf8)
        let input = macInput(role: role, nonce: nonce, ephemeralPublicKey: ephemeralPublicKey, name: name)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
        return FriendsHello(nonce: nonce, ephemeralPublicKey: ephemeralPublicKey, deviceName: deviceName, mac: mac)
    }

    public func encode() -> Data {
        let name = Array(deviceName.utf8)
        var w = ByteWriter()
        w.raw(FriendsProtocol.magic)
        w.u8(FriendsProtocol.version)
        w.raw(nonce)
        w.raw(ephemeralPublicKey)
        w.u8(UInt8(name.count))
        w.raw(name)
        w.raw(mac)
        return Data(w.bytes)
    }

    /// Given the bytes received so far on a fresh connection, the total Hello length once known
    /// (nil if more bytes are needed to tell). Throws if the prefix can already be rejected
    /// (bad magic, any version other than the current one, over-long name).
    public static func totalLength(prefix: Data) throws -> Int? {
        let p = [UInt8](prefix.prefix(nameLengthOffset + 1))
        for (i, m) in FriendsProtocol.magic.enumerated() where p.count > i && p[i] != m { throw FriendsError.malformedHello }
        if p.count > 4, p[4] != FriendsProtocol.version { throw FriendsError.unsupportedVersion }
        guard p.count > nameLengthOffset else { return nil }
        let n = Int(p[nameLengthOffset])
        guard n <= FriendsProtocol.maxDeviceNameBytes else { throw FriendsError.invalidDeviceName }
        return nameLengthOffset + 1 + n + FriendsProtocol.macBytes
    }

    public static func decode(_ data: Data) throws -> FriendsHello {
        var r = ByteReader(data)
        guard Array(try r.take(4, .malformedHello)) == FriendsProtocol.magic else { throw FriendsError.malformedHello }
        let ver = try r.take(1, .malformedHello).first!
        guard ver == FriendsProtocol.version else { throw FriendsError.unsupportedVersion }
        let nonce = Data(try r.take(FriendsProtocol.nonceBytes, .malformedHello))
        let pub = Data(try r.take(FriendsProtocol.publicKeyBytes, .malformedHello))
        let n = Int(try r.take(1, .malformedHello).first!)
        guard n <= FriendsProtocol.maxDeviceNameBytes else { throw FriendsError.invalidDeviceName }
        let nameData = Data(try r.take(n, .malformedHello))
        guard let name = String(data: nameData, encoding: .utf8) else { throw FriendsError.invalidDeviceName }
        let mac = Data(try r.take(FriendsProtocol.macBytes, .malformedHello))
        guard r.remaining == 0 else { throw FriendsError.malformedHello }
        return FriendsHello(nonce: nonce, ephemeralPublicKey: pub, deviceName: name, mac: mac)
    }

    /// Constant-time verification of the peer's MAC.
    func verify(key: SymmetricKey, senderRole: FriendsRole) -> Bool {
        let input = Self.macInput(role: senderRole, nonce: nonce, ephemeralPublicKey: ephemeralPublicKey,
                                  name: Data(deviceName.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: input, using: key)
    }
}

// MARK: - Messages

public struct FriendsFormat: Equatable {
    public var type: String
    public var data: Data
    public init(type: String, data: Data) { self.type = type; self.data = data }
}

public struct FriendsClip: Equatable {
    public var description: String
    public var sourceDevice: String
    public var formats: [FriendsFormat]
    public init(description: String, sourceDevice: String, formats: [FriendsFormat]) {
        self.description = description; self.sourceDevice = sourceDevice; self.formats = formats
    }
}

public enum FriendsMessage: Equatable {
    case confirm
    case clip(FriendsClip)
    case ack
    case bye

    private enum Tag: UInt8 { case confirm = 1, clip = 2, ack = 3, bye = 4 }

    static func isValidUTI(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= FriendsProtocol.maxFormatTypeBytes else { return false }
        return s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x2D }
    }

    func encode() throws -> Data {
        var w = ByteWriter()
        switch self {
        case .confirm: w.u8(Tag.confirm.rawValue)
        case .ack: w.u8(Tag.ack.rawValue)
        case .bye: w.u8(Tag.bye.rawValue)
        case .clip(let c):
            let desc = Array(c.description.utf8), src = Array(c.sourceDevice.utf8)
            guard desc.count <= FriendsProtocol.maxDescriptionBytes, src.count <= FriendsProtocol.maxDeviceNameBytes else { throw FriendsError.invalidField }
            guard c.formats.count <= FriendsProtocol.maxFormats else { throw FriendsError.tooManyFormats }
            var total = 0
            for f in c.formats {
                guard Self.isValidUTI(f.type) else { throw FriendsError.invalidField }
                total += f.data.count
                guard total <= FriendsProtocol.maxClipDataBytes else { throw FriendsError.clipTooLarge }
            }
            w.u8(Tag.clip.rawValue)
            w.u16(UInt16(desc.count)); w.raw(desc)
            w.u8(UInt8(src.count)); w.raw(src)
            w.u8(UInt8(c.formats.count))
            for f in c.formats {
                let t = Array(f.type.utf8)
                w.u8(UInt8(t.count)); w.raw(t)
                w.u32(UInt32(f.data.count)); w.raw(f.data)
            }
        }
        return Data(w.bytes)
    }

    static func decode(_ data: Data) throws -> FriendsMessage {
        var r = ByteReader(data)
        guard r.remaining >= 1 else { throw FriendsError.malformedMessage }
        let tagByte = try r.take(1).first!
        guard let tag = Tag(rawValue: tagByte) else { throw FriendsError.unknownMessageType }
        let msg: FriendsMessage
        switch tag {
        case .confirm: msg = .confirm
        case .ack: msg = .ack
        case .bye: msg = .bye
        case .clip:
            let dl = try r.u16()
            guard dl <= FriendsProtocol.maxDescriptionBytes else { throw FriendsError.invalidField }
            guard let desc = String(data: Data(try r.take(dl)), encoding: .utf8) else { throw FriendsError.invalidField }
            let sl = Int(try r.take(1).first!)
            guard sl <= FriendsProtocol.maxDeviceNameBytes else { throw FriendsError.invalidField }
            guard let src = String(data: Data(try r.take(sl)), encoding: .utf8) else { throw FriendsError.invalidField }
            let count = Int(try r.take(1).first!)
            guard count <= FriendsProtocol.maxFormats else { throw FriendsError.tooManyFormats }
            var formats = [FriendsFormat]()
            var total = 0
            for _ in 0 ..< count {
                let tl = Int(try r.take(1).first!)
                guard tl >= 1, tl <= FriendsProtocol.maxFormatTypeBytes else { throw FriendsError.invalidField }
                guard let t = String(data: Data(try r.take(tl)), encoding: .utf8), isValidUTI(t) else { throw FriendsError.invalidField }
                let n = try r.u32()
                total += n
                guard total <= FriendsProtocol.maxClipDataBytes else { throw FriendsError.clipTooLarge }
                formats.append(FriendsFormat(type: t, data: Data(try r.take(n))))   // bounds-checked before copy
            }
            msg = .clip(FriendsClip(description: desc, sourceDevice: src, formats: formats))
        }
        guard r.remaining == 0 else { throw FriendsError.trailingBytes }
        return msg
    }
}

// MARK: - Session

public final class FriendsSession {
    public let role: FriendsRole
    private let longTermKey: SymmetricKey
    private let deviceName: String
    private let ownNonce: Data
    /// Fresh per session; set to nil as soon as the session keys are derived, so it can never be reused.
    private var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private let ephemeralPublic: Data
    private var helloBytes: Data?
    private(set) var sendKey: SymmetricKey?
    private(set) var recvKey: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0
    private var sentConfirm = false
    private var receivedConfirm = false
    private var helloMade = false

    public var isEstablished: Bool { sendKey != nil }

    public init(role: FriendsRole, key: SymmetricKey, deviceName: String) {
        self.role = role
        self.longTermKey = key
        self.deviceName = FriendsSession.truncate(deviceName, toBytes: FriendsProtocol.maxDeviceNameBytes)
        var rng = SystemRandomNumberGenerator()
        self.ownNonce = Data((0 ..< FriendsProtocol.nonceBytes).map { _ in UInt8.random(in: 0 ... 255, using: &rng) })
        let eph = Curve25519.KeyAgreement.PrivateKey()
        self.ephemeralKey = eph
        self.ephemeralPublic = eph.publicKey.rawRepresentation
    }

    static func truncate(_ s: String, toBytes n: Int) -> String {
        var out = ""
        var used = 0
        for ch in s {
            let c = ch.utf8.count
            if used + c > n { break }
            out.append(ch); used += c
        }
        return out
    }

    /// This session's Hello. Calling it again returns the same bytes (one ephemeral key per session).
    public func makeHello() -> Data {
        helloMade = true
        if let h = helloBytes { return h }
        let h = FriendsHello.make(role: role, key: longTermKey, nonce: ownNonce,
                                  ephemeralPublicKey: ephemeralPublic, deviceName: deviceName).encode()
        helloBytes = h
        return h
    }

    /// Verifies the peer's Hello and derives the session keys. Returns the peer's (display-only) device name.
    public func receiveHello(_ data: Data) throws -> String {
        guard sendKey == nil else { throw FriendsError.handshakeAlreadyComplete }
        guard helloMade else { throw FriendsError.handshakeNotComplete }
        guard let eph = ephemeralKey else { throw FriendsError.handshakeAlreadyComplete }
        let hello = try FriendsHello.decode(data)
        // Authenticate before touching the peer's public key.
        guard hello.verify(key: longTermKey, senderRole: role.peer) else { throw FriendsError.authenticationFailed }
        let peerPub = hello.ephemeralPublicKey
        guard peerPub.contains(where: { $0 != 0 }), peerPub != ephemeralPublic else { throw FriendsError.invalidPublicKey }
        let shared: SharedSecret
        do {
            let pk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPub)
            shared = try eph.sharedSecretFromKeyAgreement(with: pk)
        } catch { throw FriendsError.invalidPublicKey }
        var ikm = shared.withUnsafeBytes { Data($0) }
        defer { ikm.resetBytes(in: 0 ..< ikm.count) }
        guard ikm.contains(where: { $0 != 0 }) else { throw FriendsError.invalidPublicKey }
        ikm.append(Data(HMAC<SHA256>.authenticationCode(for: Data("DittoMac v2 psk".utf8), using: longTermKey)))

        let isClient = role == .client
        var salt = isClient ? ownNonce + hello.nonce : hello.nonce + ownNonce
        salt.append(isClient ? ephemeralPublic : peerPub)
        salt.append(isClient ? peerPub : ephemeralPublic)
        let ikmKey = SymmetricKey(data: ikm)
        func derive(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: ikmKey, salt: salt, info: Data(info.utf8), outputByteCount: 32)
        }
        let c2s = derive("DittoMac v2 c2s"), s2c = derive("DittoMac v2 s2c")
        sendKey = isClient ? c2s : s2c
        recvKey = isClient ? s2c : c2s
        ephemeralKey = nil   // forward secrecy: the private half never outlives the handshake
        return hello.deviceName
    }

    private func aad(sending: Bool) -> Data {
        let clientToServer = (role == .client) == sending
        return Data(FriendsProtocol.magic + [clientToServer ? 0 : 1])
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var w = ByteWriter()
        w.u32(0); w.u64(counter)
        return try ChaChaPoly.Nonce(data: w.bytes)
    }

    /// Encrypts a message into a complete length-prefixed frame. The first message must be `.confirm`.
    public func seal(_ msg: FriendsMessage) throws -> Data {
        guard let key = sendKey else { throw FriendsError.handshakeNotComplete }
        if !sentConfirm { guard msg == .confirm else { throw FriendsError.confirmRequired } }
        guard sendCounter != UInt64.max else { throw FriendsError.counterExhausted }
        let plain = try msg.encode()
        guard plain.count + 28 <= FriendsProtocol.maxFrameBytes else { throw FriendsError.frameTooLarge }
        let box = try ChaChaPoly.seal(plain, using: key, nonce: try Self.nonce(sendCounter), authenticating: aad(sending: true))
        let combined = box.combined
        var w = ByteWriter()
        w.u32(UInt32(combined.count))
        w.raw(combined)
        sendCounter += 1
        sentConfirm = true
        return Data(w.bytes)
    }

    /// Decrypts one complete frame (length prefix included, as yielded by `FrameAccumulator`).
    /// State only advances on success; the first accepted message must be `.confirm`.
    public func open(frame: Data) throws -> FriendsMessage {
        guard let key = recvKey else { throw FriendsError.handshakeNotComplete }
        let b = [UInt8](frame)
        guard b.count >= 4 else { throw FriendsError.malformedFrame }
        let len = b[0...3].reduce(0) { ($0 << 8) | Int($1) }
        guard len <= FriendsProtocol.maxFrameBytes else { throw FriendsError.frameTooLarge }
        guard len >= FriendsProtocol.minSealedBytes else { throw FriendsError.frameTooSmall }
        guard b.count == 4 + len else { throw FriendsError.malformedFrame }
        guard recvCounter != UInt64.max else { throw FriendsError.counterExhausted }
        let combined = Data(b[4...])
        let expected = try Self.nonce(recvCounter)
        guard combined.prefix(12) == Data(expected) else { throw FriendsError.unexpectedCounter }
        let plain: Data
        do {
            let box = try ChaChaPoly.SealedBox(combined: combined)
            plain = try ChaChaPoly.open(box, using: key, authenticating: aad(sending: false))
        } catch { throw FriendsError.decryptionFailed }
        let msg = try FriendsMessage.decode(plain)
        if !receivedConfirm { guard msg == .confirm else { throw FriendsError.confirmRequired } }
        recvCounter += 1
        receivedConfirm = true
        return msg
    }
}

// MARK: - Streaming frame accumulator

/// Turns arbitrary TCP chunks into complete frames. A length prefix above `maxFrameBytes` (or below the
/// minimum) is rejected as soon as its 4 bytes arrive, before any body is buffered. After an error the
/// accumulator is poisoned and the connection must be dropped.
public final class FrameAccumulator {
    private var buffer = [UInt8]()
    private var poisoned = false
    public init() {}

    public var bufferedByteCount: Int { buffer.count }

    public func append(_ chunk: Data) throws -> [Data] {
        guard !poisoned else { throw FriendsError.malformedFrame }
        buffer.append(contentsOf: chunk)
        var frames = [Data]()
        var offset = 0
        while buffer.count - offset >= 4 {
            let len = buffer[offset ..< offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            if len > FriendsProtocol.maxFrameBytes { poisoned = true; buffer.removeAll(); throw FriendsError.frameTooLarge }
            if len < FriendsProtocol.minSealedBytes { poisoned = true; buffer.removeAll(); throw FriendsError.frameTooSmall }
            guard buffer.count - offset >= 4 + len else { break }
            frames.append(Data(buffer[offset ..< offset + 4 + len]))
            offset += 4 + len
        }
        if offset > 0 { buffer.removeSubrange(0 ..< offset) }
        return frames
    }
}
