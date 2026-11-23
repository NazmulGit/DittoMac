import Testing
import Foundation
import CryptoKit
@testable import DittoCore

private let testKey = FriendsProtocol.deriveKey(passphrase: "correct horse battery", iterations: 10)
private let otherKey = FriendsProtocol.deriveKey(passphrase: "incorrect horse battery", iterations: 10)

private func pair(clientKey: SymmetricKey = testKey, serverKey: SymmetricKey = testKey) throws -> (FriendsSession, FriendsSession) {
    let c = FriendsSession(role: .client, key: clientKey, deviceName: "Alice-Mac")
    let s = FriendsSession(role: .server, key: serverKey, deviceName: "Bob-Mac")
    let ch = c.makeHello(), sh = s.makeHello()
    _ = try s.receiveHello(ch)
    _ = try c.receiveHello(sh)
    return (c, s)
}

private func established() throws -> (FriendsSession, FriendsSession) {
    let (c, s) = try pair()
    #expect(try s.open(frame: c.seal(.confirm)) == .confirm)
    #expect(try c.open(frame: s.seal(.confirm)) == .confirm)
    return (c, s)
}

private func sampleClip() -> FriendsClip {
    FriendsClip(description: "héllo wörld ✓", sourceDevice: "Alice-Mac", formats: [
        FriendsFormat(type: "public.utf8-plain-text", data: Data("hello".utf8)),
        FriendsFormat(type: "public.png", data: Data((0..<1000).map { UInt8($0 & 0xff) })),
    ])
}

@Suite struct FriendsProtocolTests {
    @Test func happyPath() throws {
        let c = FriendsSession(role: .client, key: testKey, deviceName: "Alice-Mac")
        let s = FriendsSession(role: .server, key: testKey, deviceName: "Bob-Mac")
        let ch = c.makeHello(), sh = s.makeHello()
        #expect(try s.receiveHello(ch) == "Alice-Mac")
        #expect(try c.receiveHello(sh) == "Bob-Mac")
        #expect(try s.open(frame: c.seal(.confirm)) == .confirm)
        #expect(try c.open(frame: s.seal(.confirm)) == .confirm)
        let clip = FriendsMessage.clip(sampleClip())
        #expect(try s.open(frame: c.seal(clip)) == clip)
        #expect(try c.open(frame: s.seal(.ack)) == .ack)
        #expect(try s.open(frame: c.seal(.bye)) == .bye)
    }

    @Test func helloLengthHelper() throws {
        let h = FriendsSession(role: .client, key: testKey, deviceName: "Alice").makeHello()
        #expect(try FriendsHello.totalLength(prefix: h.prefix(10)) == nil)
        #expect(try FriendsHello.totalLength(prefix: h) == h.count)
        #expect(throws: FriendsError.self) { try FriendsHello.totalLength(prefix: Data("XXXX".utf8)) }
    }

    @Test func helloSizeAndVersion() throws {
        let h = FriendsSession(role: .client, key: testKey, deviceName: "Alice").makeHello()
        #expect(h[4] == 2)
        #expect(h.count == 4 + 1 + 32 + 32 + 1 + 5 + 32)
        let maxH = FriendsSession(role: .client, key: testKey, deviceName: String(repeating: "x", count: 200)).makeHello()
        #expect(maxH.count == FriendsProtocol.maxHelloBytes)
        #expect(try FriendsHello.totalLength(prefix: maxH) == FriendsProtocol.maxHelloBytes)
        #expect(FriendsProtocol.maxHelloBytes == 166)
    }

    @Test func makeHelloIsStableWithinSession() throws {
        let c = FriendsSession(role: .client, key: testKey, deviceName: "A")
        #expect(c.makeHello() == c.makeHello())
    }

    @Test func v1HelloRejected() throws {
        // Old v1 layout: "DMF1" | 1 | nonce[32] | nameLen | name | mac[32], MAC'd with the v1 scheme.
        let nonce = Data(repeating: 7, count: 32), name = Data("Old-Mac".utf8)
        var macIn = Data("hello".utf8); macIn.append(1); macIn.append(nonce); macIn.append(name)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: macIn, using: testKey))
        var v1 = Data("DMF1".utf8); v1.append(1); v1.append(nonce); v1.append(UInt8(name.count)); v1.append(name); v1.append(mac)
        #expect(throws: FriendsError.unsupportedVersion) { try FriendsHello.totalLength(prefix: v1.prefix(5)) }
        #expect(throws: FriendsError.unsupportedVersion) { try FriendsHello.totalLength(prefix: v1) }
        #expect(throws: FriendsError.unsupportedVersion) { try FriendsHello.decode(v1) }
        let s = FriendsSession(role: .server, key: testKey, deviceName: "B")
        _ = s.makeHello()
        #expect(throws: FriendsError.unsupportedVersion) { try s.receiveHello(v1) }
        #expect(!s.isEstablished)
    }

    @Test func sessionsWithSamePassphraseHaveDistinctKeys() throws {
        let (c1, s1) = try pair()
        let (c2, s2) = try pair()
        func raw(_ k: SymmetricKey?) -> Data { k!.withUnsafeBytes { Data($0) } }
        // Each pair agrees...
        #expect(raw(c1.sendKey) == raw(s1.recvKey))
        #expect(raw(c1.recvKey) == raw(s1.sendKey))
        #expect(raw(c1.sendKey) != raw(c1.recvKey))
        // ...but two sessions with the same passphrase never share keys.
        #expect(raw(c1.sendKey) != raw(c2.sendKey))
        #expect(raw(c1.recvKey) != raw(c2.recvKey))
        #expect(raw(s1.sendKey) != raw(s2.sendKey))
        // Ephemeral keys differ per session too.
        let h1 = try FriendsHello.decode(FriendsSession(role: .client, key: testKey, deviceName: "A").makeHello())
        let h2 = try FriendsHello.decode(FriendsSession(role: .client, key: testKey, deviceName: "A").makeHello())
        #expect(h1.ephemeralPublicKey != h2.ephemeralPublicKey)
        #expect(h1.ephemeralPublicKey.count == 32)
    }

    @Test func sessionKeysNotDerivableFromPassphraseAlone() throws {
        // A v1-style derivation from the long-term key + nonces must not reproduce the v2 keys.
        let c = FriendsSession(role: .client, key: testKey, deviceName: "A")
        let s = FriendsSession(role: .server, key: testKey, deviceName: "B")
        let ch = c.makeHello(), sh = s.makeHello()
        _ = try s.receiveHello(ch); _ = try c.receiveHello(sh)
        let cn = try FriendsHello.decode(ch).nonce, sn = try FriendsHello.decode(sh).nonce
        let cp = try FriendsHello.decode(ch).ephemeralPublicKey, sp = try FriendsHello.decode(sh).ephemeralPublicKey
        for salt in [cn + sn, cn + sn + cp + sp] {
            for info in ["DittoMac v1 c2s", "DittoMac v2 c2s"] {
                let guess = HKDF<SHA256>.deriveKey(inputKeyMaterial: testKey, salt: salt, info: Data(info.utf8), outputByteCount: 32)
                #expect(guess.withUnsafeBytes { Data($0) } != c.sendKey!.withUnsafeBytes { Data($0) })
            }
        }
    }

    @Test func tamperedEphemeralKeyFailsHMAC() throws {
        let c = FriendsSession(role: .client, key: testKey, deviceName: "Alice")
        let s = FriendsSession(role: .server, key: testKey, deviceName: "Bob")
        var ch = c.makeHello(); _ = s.makeHello()
        // Swap in a different, valid public key (an active MITM's own key).
        let mitm = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        ch.replaceSubrange(37 ..< 69, with: mitm)
        #expect(throws: FriendsError.authenticationFailed) { try s.receiveHello(ch) }
        // Single bit flip too.
        var ch2 = c.makeHello()
        ch2[50] ^= 0x01
        #expect(throws: FriendsError.authenticationFailed) { try s.receiveHello(ch2) }
        #expect(!s.isEstablished)
    }

    @Test func zeroOrLowOrderPublicKeyRejected() throws {
        // Even with a valid MAC (an insider), degenerate keys are refused.
        let s = FriendsSession(role: .server, key: testKey, deviceName: "B")
        _ = s.makeHello()
        let zero = FriendsHello.make(role: .client, key: testKey, nonce: Data(count: 32),
                                     ephemeralPublicKey: Data(count: 32), deviceName: "Z").encode()
        #expect(throws: FriendsError.invalidPublicKey) { try s.receiveHello(zero) }
        // u = 1 is a low-order point: X25519 output is all zeros.
        var one = Data(count: 32); one[0] = 1
        let low = FriendsHello.make(role: .client, key: testKey, nonce: Data(count: 32),
                                    ephemeralPublicKey: one, deviceName: "L").encode()
        #expect(throws: FriendsError.invalidPublicKey) { try s.receiveHello(low) }
        #expect(!s.isEstablished)
    }

    @Test func ephemeralKeyNotReusedAfterHandshake() throws {
        let (c, s) = try pair()
        // A second hello on the same session is refused; the ephemeral private key is gone.
        let other = FriendsSession(role: .server, key: testKey, deviceName: "X")
        #expect(throws: FriendsError.handshakeAlreadyComplete) { try c.receiveHello(other.makeHello()) }
        _ = s
    }

    @Test func wrongPassphraseRejectedAtHello() throws {
        let c = FriendsSession(role: .client, key: testKey, deviceName: "A")
        let s = FriendsSession(role: .server, key: otherKey, deviceName: "B")
        let ch = c.makeHello(); _ = s.makeHello()
        #expect(throws: FriendsError.authenticationFailed) { try s.receiveHello(ch) }
    }

    @Test func reflectedHelloRejected() throws {
        let c = FriendsSession(role: .client, key: testKey, deviceName: "A")
        let ch = c.makeHello()
        #expect(throws: FriendsError.authenticationFailed) { try c.receiveHello(ch) }
    }

    @Test func tamperedCiphertextRejected() throws {
        let (c, s) = try established()
        var f = try c.seal(.ack)
        f[f.count - 1] ^= 1
        #expect(throws: FriendsError.decryptionFailed) { try s.open(frame: f) }
        var g = try c.seal(.ack)   // counter 2; session state unaffected by failure of counter-1 frame
        g[20] ^= 0x80
        #expect(throws: FriendsError.self) { try s.open(frame: g) }
    }

    @Test func replayAndReorderRejected() throws {
        let (c, s) = try established()
        let f1 = try c.seal(.ack), f2 = try c.seal(.ack), f3 = try c.seal(.bye)
        #expect(throws: FriendsError.unexpectedCounter) { try s.open(frame: f2) }   // reorder
        #expect(try s.open(frame: f1) == .ack)
        #expect(throws: FriendsError.unexpectedCounter) { try s.open(frame: f1) }   // replay
        #expect(try s.open(frame: f2) == .ack)
        #expect(try s.open(frame: f3) == .bye)
    }

    @Test func reflectionOfOwnFrameRejected() throws {
        let (c, s) = try established()
        let f = try c.seal(.ack)
        _ = try s.open(frame: f)
        #expect(throws: FriendsError.self) { try c.open(frame: f) }   // wrong direction key
    }

    @Test func oldSessionReplayFails() throws {
        let (c1, _) = try pair()
        let old = try c1.seal(.confirm)
        let (_, s2) = try pair()
        #expect(throws: FriendsError.self) { try s2.open(frame: old) }
    }

    @Test func confirmRequiredFirst() throws {
        let (c, s) = try pair()
        #expect(throws: FriendsError.confirmRequired) { try c.seal(.ack) }
        _ = s
    }

    @Test func oversizeLengthRejectedBeforeBuffering() throws {
        let acc = FrameAccumulator()
        var hdr = Data([0x7f, 0xff, 0xff, 0xff])
        #expect(throws: FriendsError.frameTooLarge) { try acc.append(hdr) }
        #expect(acc.bufferedByteCount == 0)
        let acc2 = FrameAccumulator()
        let over = UInt32(FriendsProtocol.maxFrameBytes + 1)
        hdr = Data([UInt8(over >> 24), UInt8((over >> 16) & 0xff), UInt8((over >> 8) & 0xff), UInt8(over & 0xff)])
        #expect(throws: FriendsError.frameTooLarge) { try acc2.append(hdr) }
        // Poisoned afterwards.
        #expect(throws: FriendsError.self) { try acc2.append(Data([0])) }
        // Session.open also rejects.
        let (_, s) = try established()
        #expect(throws: FriendsError.frameTooLarge) { try s.open(frame: hdr + Data(count: 10)) }
    }

    @Test func accumulatorHandlesArbitraryChunking() throws {
        let (c, s) = try established()
        let msgs: [FriendsMessage] = [.clip(sampleClip()), .ack, .bye]
        var stream = Data()
        for m in msgs { stream.append(try c.seal(m)) }
        let acc = FrameAccumulator()
        var got = [FriendsMessage]()
        var i = 0
        var step = 1
        while i < stream.count {
            let end = min(stream.count, i + step)
            for f in try acc.append(stream.subdata(in: i ..< end)) { got.append(try s.open(frame: f)) }
            i = end; step = (step % 7) + 1
        }
        #expect(got == msgs)
        #expect(acc.bufferedByteCount == 0)
    }

    @Test func largestClipFitsOneFrame() throws {
        let (c, s) = try established()
        let big = FriendsClip(description: "", sourceDevice: "", formats: [
            FriendsFormat(type: "public.data", data: Data(count: FriendsProtocol.maxClipDataBytes))])
        let f = try c.seal(.clip(big))
        #expect(f.count - 4 <= FriendsProtocol.maxFrameBytes)
        #expect(try s.open(frame: f) == .clip(big))
        let tooBig = FriendsClip(description: "", sourceDevice: "", formats: [
            FriendsFormat(type: "public.data", data: Data(count: FriendsProtocol.maxClipDataBytes + 1))])
        #expect(throws: FriendsError.clipTooLarge) { try c.seal(.clip(tooBig)) }
    }

    @Test func invalidUTIRejected() throws {
        let (c, _) = try established()
        for bad in ["", "public/png", "a b", "x\u{0}y", "é", "../../etc", String(repeating: "a", count: 129)] {
            let clip = FriendsClip(description: "", sourceDevice: "", formats: [FriendsFormat(type: bad, data: Data())])
            #expect(throws: FriendsError.invalidField) { try c.seal(.clip(clip)) }
        }
        #expect(FriendsMessage.isValidUTI("com.apple.flat-rtfd"))
        #expect(FriendsMessage.isValidUTI(String(repeating: "a", count: 128)))
    }

    @Test func decodeRejectsInvalidUTIFromWire() throws {
        // Hand-built clip with a bad UTI char.
        var w = ByteWriter()
        w.u8(2); w.u16(0); w.u8(0); w.u8(1); w.u8(3); w.raw(Array("a/b".utf8)); w.u32(0)
        #expect(throws: FriendsError.invalidField) { try FriendsMessage.decode(Data(w.bytes)) }
    }

    @Test func formatCountCap() throws {
        let (c, _) = try established()
        let fmts = (0 ..< 17).map { FriendsFormat(type: "public.t\($0)", data: Data()) }
        #expect(throws: FriendsError.tooManyFormats) { try c.seal(.clip(FriendsClip(description: "", sourceDevice: "", formats: fmts))) }
        var w = ByteWriter()
        w.u8(2); w.u16(0); w.u8(0); w.u8(200)
        #expect(throws: FriendsError.tooManyFormats) { try FriendsMessage.decode(Data(w.bytes)) }
        let ok = FriendsClip(description: "", sourceDevice: "", formats: Array(fmts.prefix(16)))
        #expect(try FriendsMessage.decode(FriendsMessage.clip(ok).encode()) == .clip(ok))
    }

    @Test func stringCaps() throws {
        let long = String(repeating: "x", count: 4097)
        #expect(throws: FriendsError.invalidField) {
            try FriendsMessage.clip(FriendsClip(description: long, sourceDevice: "", formats: [])).encode()
        }
        #expect(throws: FriendsError.invalidField) {
            try FriendsMessage.clip(FriendsClip(description: "", sourceDevice: String(repeating: "y", count: 65), formats: [])).encode()
        }
        // Long device name is truncated at hello, never exceeds 64 bytes on the wire.
        let h = FriendsSession(role: .client, key: testKey, deviceName: String(repeating: "é", count: 100)).makeHello()
        #expect(try FriendsHello.decode(h).deviceName.utf8.count <= 64)
    }

    @Test func declaredLengthsBeyondBufferRejected() throws {
        var w = ByteWriter()   // format claims 4 GiB of data
        w.u8(2); w.u16(0); w.u8(0); w.u8(1); w.u8(1); w.raw([0x61]); w.u32(0xffff_ffff)
        #expect(throws: FriendsError.clipTooLarge) { try FriendsMessage.decode(Data(w.bytes)) }
        var w2 = ByteWriter()
        w2.u8(2); w2.u16(0); w2.u8(0); w2.u8(1); w2.u8(1); w2.raw([0x61]); w2.u32(100); w2.raw([1, 2, 3])
        #expect(throws: FriendsError.malformedMessage) { try FriendsMessage.decode(Data(w2.bytes)) }
        #expect(throws: FriendsError.trailingBytes) { try FriendsMessage.decode(Data([1, 0])) }
        #expect(throws: FriendsError.unknownMessageType) { try FriendsMessage.decode(Data([9])) }
    }

    @Test func passphraseValidation() {
        #expect(!FriendsProtocol.validatePassphrase(""))
        #expect(!FriendsProtocol.validatePassphrase("LetMeIn"))
        #expect(!FriendsProtocol.validatePassphrase("elevenchars"))
        #expect(FriendsProtocol.validatePassphrase("twelve chars"))
        #expect(!FriendsProtocol.validatePassphrase(String(repeating: "a", count: 2000)))
    }

    @Test func kdfIsDeterministicAndPassphraseSensitive() {
        let a = FriendsProtocol.deriveKey(passphrase: "abcdefghijkl", iterations: 5)
        let b = FriendsProtocol.deriveKey(passphrase: "abcdefghijkl", iterations: 5)
        let c = FriendsProtocol.deriveKey(passphrase: "abcdefghijkm", iterations: 5)
        let d = FriendsProtocol.deriveKey(passphrase: "abcdefghijkl", iterations: 6)
        #expect(a.withUnsafeBytes { Data($0) } == b.withUnsafeBytes { Data($0) })
        #expect(a.withUnsafeBytes { Data($0) } != c.withUnsafeBytes { Data($0) })
        #expect(a.withUnsafeBytes { Data($0) } != d.withUnsafeBytes { Data($0) })
        #expect(FriendsProtocol.kdfIterations == 600_000)
        #expect(FriendsProtocol.port == 23443)
    }

    @Test func fuzzDecodePathsNeverCrash() throws {
        var rng = SystemRandomNumberGenerator()
        let (_, s) = try established()
        let clipSeed = try FriendsMessage.clip(sampleClip()).encode()
        for i in 0 ..< 2000 {
            let n = Int.random(in: 0 ... 200, using: &rng)
            var d = Data((0 ..< n).map { _ in UInt8.random(in: 0 ... 255, using: &rng) })
            if i % 3 == 0 && n > 0 { d[0] = [1, 2, 3, 4][i % 4] }               // plausible tags
            if i % 5 == 0 { d = Data(clipSeed.prefix(Int.random(in: 0 ... clipSeed.count, using: &rng))) }   // truncated valid
            if i % 7 == 0 && !clipSeed.isEmpty { var m = clipSeed; m[Int.random(in: 0 ..< m.count, using: &rng)] = UInt8.random(in: 0 ... 255, using: &rng); d = m }
            _ = try? FriendsMessage.decode(d)
            _ = try? FriendsHello.decode(d)
            _ = try? FriendsHello.totalLength(prefix: d)
            _ = try? s.open(frame: d)
            let acc = FrameAccumulator()
            _ = try? acc.append(d)
            let probe = FriendsSession(role: .server, key: testKey, deviceName: "p")
            _ = probe.makeHello()
            _ = try? probe.receiveHello(d)
        }
    }
}
