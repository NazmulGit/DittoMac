import Foundation
import CryptoKit
import Testing
@testable import DittoCore

private let pass = "correct horse battery"
private let fastIters = SyncLimits.minIterations      // keep tests quick; production default is 600k
private let base: Double = 1_700_000_000                // Nov 2023, comfortably inside the sane date range

private struct LCG: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 1 | (s << 63) }
}

@discardableResult
private func addClip(_ s: ClipStore, _ text: String, date: Double? = nil, parent: Int64 = -1,
                     extra: [ClipFormat] = [], source: String = "test") throws -> Int64 {
    guard case .inserted(let id) = try s.addClip(formats: [textFormat(text)] + extra, description: text, sourceApp: source, parentID: parent) else {
        throw SyncError.io("add failed")
    }
    if let date, var c = try s.clip(id: id) { c.date = Date(timeIntervalSince1970: date); c.lastPasteDate = c.date; try s.update(c) }
    return id
}

private func engine(_ store: ClipStore) -> SyncEngine { SyncEngine(store: store, stateDirectory: nil, deviceID: UUID().uuidString) }

private func hashes(_ e: SyncEngine, _ o: SyncOptions = SyncOptions()) throws -> Set<String> {
    Set(try e.makeSnapshot(deviceName: "t", options: o).clips.map(\.contentHash))
}

private func sampleSnapshot() -> SyncSnapshot {
    let f = SyncFormat(type: ClipUTI.plainText, data: Data("hello".utf8))
    let h = SyncHash.contentHash([ClipFormat(type: f.type, data: f.data)])
    return SyncSnapshot(deviceID: UUID().uuidString, deviceName: "Test Mac", createdAt: base,
                        groups: [SyncGroup(uid: "g1", name: "Work")],
                        clips: [SyncClip(contentHash: h, date: base, lastPasteDate: base, description: "hello", groupUID: "g1", formats: [f])])
}

/// Encrypts arbitrary compressed bytes with the container format (for bomb / garbage-payload tests).
private func sealRaw(_ compressed: Data, passphrase: String = pass, iterations: Int = fastIters) throws -> Data {
    let salt = Data(repeating: 7, count: 16), nonce = Data(repeating: 9, count: 12)
    var header = SyncLimits.magic
    header.append(SyncLimits.version); header.append(SyncUtil.be32(UInt32(iterations))); header.append(salt); header.append(nonce)
    let key = try SyncKDF.key(passphrase: passphrase, salt: salt, iterations: iterations)
    let box = try AES.GCM.seal(compressed, using: key, nonce: try AES.GCM.Nonce(data: nonce), authenticating: header)
    return header + box.ciphertext + box.tag
}

@Suite struct SyncTests {

    // MARK: container

    @Test func roundTrip() throws {
        let snap = sampleSnapshot()
        let blob = try SyncCodec.seal(snap, passphrase: pass, iterations: fastIters)
        #expect(blob.prefix(7) == SyncLimits.magic)
        #expect(!blob.contains(Data("hello".utf8)))
        let back = try SyncCodec.open(blob, passphrase: pass)
        #expect(back.clips == snap.clips)
        #expect(back.groups == snap.groups)
        #expect(back.deviceName == "Test Mac")
    }

    @Test func wrongPassphraseFails() throws {
        let blob = try SyncCodec.seal(sampleSnapshot(), passphrase: pass, iterations: fastIters)
        #expect(throws: SyncError.wrongPassphraseOrCorrupt) { try SyncCodec.open(blob, passphrase: "another passphrase!") }
        #expect(throws: SyncError.passphraseTooShort) { try SyncCodec.open(blob, passphrase: "short") }
    }

    @Test func tamperedHeaderOrCiphertextFails() throws {
        let blob = try SyncCodec.seal(sampleSnapshot(), passphrase: pass, iterations: fastIters)
        // every byte after the version: iterations, salt, nonce, ciphertext, tag
        for i in [8, 11, 12, 20, 27, 28, 35, 39, 40, 41, blob.count / 2, blob.count - 17, blob.count - 1] {
            var t = blob
            t[i] ^= 0x01
            #expect(throws: (any Error).self) { try SyncCodec.open(t, passphrase: pass) }
        }
        var badMagic = blob; badMagic[0] ^= 1
        #expect(throws: SyncError.notASnapshot) { try SyncCodec.open(badMagic, passphrase: pass) }
        var badVersion = blob; badVersion[7] = 2
        #expect(throws: SyncError.unsupportedVersion(2)) { try SyncCodec.open(badVersion, passphrase: pass) }
    }

    @Test func iterationCountIsClampedBeforeDerivation() throws {
        let blob = try SyncCodec.seal(sampleSnapshot(), passphrase: pass, iterations: fastIters)
        func with(_ iters: UInt32) -> Data {
            var t = blob
            t.replaceSubrange(8..<12, with: SyncUtil.be32(iters))
            return t
        }
        let start = Date()
        for v: UInt32 in [4_000_000_000, UInt32.max, 2_000_001, 99_999, 0, 1] {
            #expect(throws: SyncError.badIterations) { try SyncCodec.open(with(v), passphrase: pass) }
        }
        #expect(Date().timeIntervalSince(start) < 1.0)    // rejected without deriving (billions of rounds would take hours)
        #expect(throws: SyncError.badIterations) { try SyncCodec.seal(sampleSnapshot(), passphrase: pass, iterations: 50) }
        #expect(throws: SyncError.badIterations) { try SyncCodec.seal(sampleSnapshot(), passphrase: pass, iterations: 5_000_000) }
    }

    @Test func decompressionBombIsRejected() throws {
        let zeros = Data(count: 8 * 1024 * 1024)
        let bomb = try SyncZlib.compress(zeros)
        #expect(bomb.count < 100_000)
        let blob = try sealRaw(bomb)
        #expect(throws: SyncError.tooLarge) { try SyncCodec.open(blob, passphrase: pass, maxDecompressedBytes: 1024 * 1024) }
        // within the cap it is decompressed but is not valid JSON
        #expect(throws: SyncError.malformed("unreadable contents")) { try SyncCodec.open(blob, passphrase: pass) }
    }

    @Test func garbagePayloadsAreMalformedNotCrashes() throws {
        #expect(throws: (any Error).self) { try SyncCodec.open(try sealRaw(Data([1, 2, 3, 4, 5, 6])), passphrase: pass) }
        #expect(throws: (any Error).self) { try SyncCodec.open(try sealRaw(Data()), passphrase: pass) }
        let notJSON = try SyncZlib.compress(Data("{\"deviceID\": 5}".utf8))
        #expect(throws: SyncError.malformed("unreadable contents")) { try SyncCodec.open(try sealRaw(notJSON), passphrase: pass) }
    }

    @Test func fuzzNeverCrashes() throws {
        var rng = LCG(s: 0xD177_0001)
        let valid = try SyncCodec.seal(sampleSnapshot(), passphrase: pass, iterations: fastIters)
        func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }) }
        var rejected = 0
        func attempt(_ d: Data) { if (try? SyncCodec.open(d, passphrase: pass)) == nil { rejected += 1 } }
        for _ in 0..<300 { attempt(bytes(Int.random(in: 0...400, using: &rng))) }                    // random bytes
        for _ in 0..<300 {                                                                            // valid header, random body
            attempt(valid.prefix(SyncLimits.headerLength) + bytes(Int.random(in: 16...3000, using: &rng)))
        }
        for _ in 0..<200 { attempt(valid.prefix(Int.random(in: 0..<valid.count, using: &rng))) }      // truncations
        for _ in 0..<200 {                                                                            // bit flips
            var t = valid
            t[Int.random(in: 0..<t.count, using: &rng)] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
            attempt(t)
        }
        #expect(rejected == 1000)
    }

    // MARK: validation

    @Test func utiValidation() {
        for ok in ["public.utf8-plain-text", "com.apple.flat-rtfd", "a", "X+y_z.1-2", String(repeating: "a", count: 128)] { #expect(SyncUTI.isValid(ok)) }
        for bad in ["", "has space", "../etc/passwd", "a/b", "tab\t", "nul\u{0}", "é", "a;b", String(repeating: "a", count: 129)] { #expect(!SyncUTI.isValid(bad)) }
    }

    @Test func validatorDropsHostileContent() throws {
        let big = Data(count: SyncLimits.maxFormatBytes + 1)
        let ok = SyncFormat(type: ClipUTI.plainText, data: Data("fine".utf8))
        let h = SyncHash.contentHash([ClipFormat(type: ok.type, data: ok.data)])
        var s = SyncSnapshot(deviceID: UUID().uuidString, deviceName: "N\u{0}ame\n", createdAt: .infinity,
                             groups: [SyncGroup(uid: "a", name: "A", parentUID: "b"), SyncGroup(uid: "b", name: "B", parentUID: "a"),
                                      SyncGroup(uid: "../x", name: "bad uid"), SyncGroup(uid: "c", name: "")],
                             clips: [])
        s.clips = [
            SyncClip(contentHash: "xyz", date: base, lastPasteDate: base, description: "bad hash", formats: [ok]),
            SyncClip(contentHash: h, date: 1000, lastPasteDate: .nan, description: String(repeating: "d", count: 300_000),
                     groupUID: "missing", formats: [ok, SyncFormat(type: "../../etc/passwd", data: Data([1])),
                                                    SyncFormat(type: ClipUTI.png, data: big), SyncFormat(type: ClipUTI.png, data: Data())]),
            SyncClip(contentHash: h, date: base, lastPasteDate: base, description: "duplicate hash", formats: [ok]),
            SyncClip(contentHash: String(repeating: "a", count: 64), date: base, lastPasteDate: base, description: "no valid formats",
                     formats: [SyncFormat(type: "bad type", data: Data([1]))]),
        ]
        let now = Date(timeIntervalSince1970: base)
        let out = try SyncValidator.sanitize(s, now: now)
        #expect(out.clips.count == 1)
        let c = out.clips[0]
        #expect(c.formats.count == 1 && c.formats[0].type == ClipUTI.plainText)
        #expect(c.description.count == SyncLimits.maxTextChars)
        #expect(c.date == base)                                  // 1970 clamped to "now"
        #expect(c.lastPasteDate >= c.date)
        #expect(c.groupUID == nil)
        #expect(out.deviceName == "Name")
        #expect(out.createdAt == base)
        #expect(out.groups.map(\.uid).sorted() == ["a", "b"])
        #expect(out.groups.contains { $0.parentUID == nil })     // the a<->b cycle is broken
        // structural limits throw
        var many = sampleSnapshot()
        many.clips = Array(repeating: many.clips[0], count: SyncLimits.maxClips + 1)
        #expect(throws: (any Error).self) { try SyncValidator.sanitize(many, now: now) }
        var badID = sampleSnapshot(); badID.deviceID = "../../x"
        #expect(throws: (any Error).self) { try SyncValidator.sanitize(badID, now: now) }
        // future dates are clamped
        var future = sampleSnapshot(); future.clips[0].date = base + 10 * 365 * 86_400
        #expect(try SyncValidator.sanitize(future, now: now).clips[0].date <= base + 2 * 86_400)
    }

    // MARK: merge

    @Test func mergeBothWaysConvergesAndPreservesMetadata() throws {
        let a = try ClipStore.inMemory(), b = try ClipStore.inMemory()
        let ea = engine(a), eb = engine(b)
        try addClip(a, "alpha", date: base + 100)
        let g = try a.createGroup(name: "Work")
        let beta = try addClip(a, "beta", date: base + 200, parent: g)
        try a.makeTopSticky(id: beta, inGroup: true)
        let gamma = try addClip(a, "gamma", date: base + 50)
        var gc = try #require(try a.clip(id: gamma)); gc.dontAutoDelete = true; gc.quickPasteText = "qp"; gc.shortcut = 12345; try a.update(gc)
        try addClip(b, "delta", date: base + 300)

        let sa = try ea.makeSnapshot(deviceName: "A")
        #expect(sa.clips.count == 3)
        #expect(sa.clips.map(\.date) == [base + 200, base + 100, base + 50])    // newest first
        let m1 = try eb.merge(sa)
        #expect(m1.imported == 3 && m1.groupsCreated == 1)
        let sb = try eb.makeSnapshot(deviceName: "B")
        let m2 = try ea.merge(sb)
        #expect(m2.imported == 1)
        #expect(try hashes(ea) == hashes(eb))
        #expect(try hashes(ea).count == 4)

        // metadata preserved on B
        let all = try b.clips(ClipFilter(limit: 0))
        let bBeta = try #require(all.first { $0.text == "beta" })
        #expect(bBeta.date == Date(timeIntervalSince1970: base + 200))
        let grp = try #require(try b.clip(id: bBeta.parentID))
        #expect(grp.isGroup && grp.text == "Work")
        #expect(bBeta.stickyClipGroupOrder != Ditto.stickySentinel)
        let bGamma = try #require(all.first { $0.text == "gamma" })
        #expect(bGamma.dontAutoDelete && bGamma.quickPasteText == "qp")
        #expect(bGamma.shortcut == 0)                                            // shortcuts are never synced
        #expect(bGamma.date == Date(timeIntervalSince1970: base + 50))
        // chronological placement: delta (newest) stays above the imported older clips
        let ordered = try b.clips(ClipFilter(limit: 0)).filter { $0.stickyClipOrder == Ditto.stickySentinel }
            .sorted { $0.clipOrder > $1.clipOrder }.map(\.text)
        #expect(ordered.first == "delta")

        // idempotent
        let before = try b.count(ClipFilter(limit: 0))
        let again = try eb.merge(sa)
        #expect(again.imported == 0 && again.alreadyPresent == 3)
        #expect(try b.count(ClipFilter(limit: 0)) == before)
        let groupsBefore = try b.groups().count
        _ = try eb.merge(sa)
        #expect(try b.groups().count == groupsBefore)
    }

    @Test func lockedAndCopyBufferClipsAreNeverSynced() throws {
        let a = try ClipStore.inMemory()
        let key = SymmetricKey(size: .bits256)
        a.vaultKey = key
        let secret = try addClip(a, "top secret")
        try addClip(a, "visible")
        try addClip(a, "buffer one", source: "copybuffer")
        #expect(try a.lock(ids: [secret], key: key) == 1)
        let e = engine(a)
        let snap = try e.makeSnapshot(deviceName: "A")
        #expect(snap.clips.map(\.description) == ["visible"])
        let blob = try SyncCodec.seal(snap, passphrase: pass, iterations: fastIters)
        #expect(!blob.contains(Data("secret".utf8)))
        // also not after the vault is locked again (no key) and not via a backup
        a.vaultKey = nil
        #expect(try e.makeSnapshot(deviceName: "A").clips.count == 1)
    }

    @Test func tombstonesStopDeletedClipsComingBack() throws {
        let a = try ClipStore.inMemory(), b = try ClipStore.inMemory()
        let ea = engine(a), eb = engine(b)
        try addClip(a, "one", date: base + 1)
        try addClip(a, "two", date: base + 2)
        let sa = try ea.makeSnapshot(deviceName: "A")
        #expect(try eb.merge(sa).imported == 2)
        // user deletes "two" on B
        let two = try #require(try b.clips(ClipFilter(limit: 0)).first { $0.text == "two" })
        try b.delete(ids: [two.id])
        let r = try eb.merge(sa)                                          // sync sees the clip vanished, tombstones it
        #expect(r.imported == 0 && r.tombstoned == 1)
        #expect(try b.count(ClipFilter(limit: 0)) == 1)
        // an explicit restore ignores tombstones
        #expect(try eb.merge(sa, honourTombstones: false).imported == 1)
        try b.delete(ids: [try #require(try b.clips(ClipFilter(limit: 0)).first { $0.text == "two" }).id])
        _ = try eb.merge(sa)
        // tombstones expire after 90 days
        let later = Date().addingTimeInterval(91 * 86_400)
        #expect(try eb.merge(sa, now: later).imported == 1)
        // copying the same content again by hand clears a tombstone and does not duplicate on the next sync
        let two2 = try #require(try b.clips(ClipFilter(limit: 0)).first { $0.text == "two" })
        try b.delete(ids: [two2.id])
        _ = try eb.merge(sa)
        try addClip(b, "two")
        let r2 = try eb.merge(sa)
        #expect(r2.imported == 0 && r2.tombstoned == 0)
    }

    @Test func importedClipKeepsItsHashWhenFormatsWereFiltered() throws {
        let a = try ClipStore.inMemory(), b = try ClipStore.inMemory()
        let ea = engine(a), eb = engine(b)
        let png = ClipFormat(type: ClipUTI.png, data: Data(repeating: 0x89, count: 5000))
        try addClip(a, "pic and text", extra: [png])
        var o = SyncOptions(); o.includeImages = false
        let slim = try ea.makeSnapshot(deviceName: "A", options: o)
        #expect(slim.clips.count == 1 && slim.clips[0].formats.map(\.type) == [ClipUTI.plainText])
        _ = try eb.merge(slim)
        // B pushes the clip back with the original hash, so A does not import a "different" slimmed copy
        let back = try eb.makeSnapshot(deviceName: "B")
        #expect(back.clips.map(\.contentHash) == slim.clips.map(\.contentHash))
        #expect(try ea.merge(back).imported == 0)
        // image-only clips vanish when images are off
        try addClip(a, "img only", extra: []) ; _ = try a.addClip(formats: [png], description: "png", sourceApp: "x")
        let withImages = try ea.makeSnapshot(deviceName: "A")
        let without = try ea.makeSnapshot(deviceName: "A", options: o)
        #expect(withImages.clips.count == without.clips.count + 1)
        // rich formats off
        var r = SyncOptions(); r.includeRichFormats = false
        try addClip(a, "rich", extra: [ClipFormat(type: ClipUTI.rtf, data: Data("{\\rtf1 x}".utf8))])
        let rich = try ea.makeSnapshot(deviceName: "A", options: r)
        #expect(rich.clips.flatMap(\.formats).allSatisfy { $0.type != ClipUTI.rtf })
    }

    @Test func capsAreRespected() throws {
        let a = try ClipStore.inMemory()
        let ea = engine(a)
        for i in 0..<10 { try addClip(a, String(repeating: Character(UnicodeScalar(97 + UInt8(i))), count: 1000), date: base + Double(i)) }
        var o = SyncOptions(); o.maxTotalBytes = 3500
        let s = try ea.makeSnapshot(deviceName: "A", options: o)
        #expect(s.clips.count == 3)
        #expect(s.clips.map(\.date) == [base + 9, base + 8, base + 7])        // newest first
        var c = SyncOptions(); c.maxClips = 2
        #expect(try ea.makeSnapshot(deviceName: "A", options: c).clips.count == 2)
        var p = SyncOptions(); p.perFormatBytes = 500
        #expect(try ea.makeSnapshot(deviceName: "A", options: p).clips.isEmpty)
        // import limit
        let b = try ClipStore.inMemory()
        let eb = engine(b)
        let m = try eb.merge(try ea.makeSnapshot(deviceName: "A"), maxNewClips: 4)
        #expect(m.imported == 4 && m.limited == 6)
        #expect(try b.clips(ClipFilter(limit: 0)).map(\.date.timeIntervalSince1970).sorted() == [base + 6, base + 7, base + 8, base + 9])
    }

    @Test func editedClipsGetANewHash() throws {
        let a = try ClipStore.inMemory()
        let ea = engine(a)
        let id = try addClip(a, "before")
        let h1 = try hashes(ea)
        try a.replaceFormats(clipID: id, formats: [textFormat("after")], description: "after")
        let h2 = try hashes(ea)
        #expect(h1 != h2 && h2.count == 1)
    }

    @Test func hashIgnoresFormatOrder() {
        let x = ClipFormat(type: "a.b", data: Data([1])), y = ClipFormat(type: "c.d", data: Data([2]))
        #expect(SyncHash.contentHash([x, y]) == SyncHash.contentHash([y, x]))
        #expect(SyncHash.contentHash([x]) != SyncHash.contentHash([ClipFormat(type: "a.b", data: Data([2]))]))
        #expect(SyncHash.contentHash([x]) != SyncHash.contentHash([ClipFormat(type: "a.c", data: Data([1]))]))
    }

    @Test func hostileSnapshotMergeWritesOnlyValidatedClips() throws {
        let b = try ClipStore.inMemory()
        let eb = engine(b)
        var s = sampleSnapshot()
        s.clips.append(SyncClip(contentHash: String(repeating: "b", count: 64), date: base, lastPasteDate: base, description: "evil",
                                formats: [SyncFormat(type: "../../x", data: Data([1])), SyncFormat(type: ClipUTI.fileURL, data: Data("file:///etc/passwd".utf8))]))
        let m = try eb.merge(s)
        #expect(m.imported == 1)                                                // only the valid text clip
        let types = try b.clips(ClipFilter(limit: 0)).flatMap { try b.formatTypes(clipID: $0.id).map(\.type) }
        #expect(types == [ClipUTI.plainText])
    }

    // MARK: state files

    @Test func stateSurvivesRestartAndTombstonesPersist() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try ClipStore.inMemory(), b = try ClipStore.inMemory()
        let id = UUID().uuidString
        let ea = engine(a)
        try addClip(a, "persisted", date: base)
        let sa = try ea.makeSnapshot(deviceName: "A")
        var eb: SyncEngine? = SyncEngine(store: b, stateDirectory: dir, deviceID: id)
        #expect(try eb!.merge(sa).imported == 1)
        try b.delete(ids: [try #require(try b.clips(ClipFilter(limit: 0)).first).id])
        #expect(try eb!.merge(sa).tombstoned == 1)
        eb = nil
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(SyncEngine.tombstoneFileName).path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let eb2 = SyncEngine(store: b, stateDirectory: dir, deviceID: id)
        let r = try eb2.merge(sa)
        #expect(r.imported == 0 && r.tombstoned == 1)
    }

    // MARK: folder runs

    private func request(_ name: String, backupKeep: Int? = nil) -> SyncRunRequest {
        var r = SyncRunRequest()
        r.deviceName = name
        r.iterations = fastIters
        r.backupKeep = backupKeep
        return r
    }

    @Test func folderSyncBetweenTwoMacs() throws {
        let tmp = tempDir()
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = try ClipStore.inMemory(), b = try ClipStore.inMemory()
        let ea = engine(a), eb = engine(b)
        try addClip(a, "from A", date: base + 1)
        try addClip(b, "from B", date: base + 2)
        let folder = try SyncFolder.open(baseFolder: tmp)
        #expect(folder.url.lastPathComponent == "DittoMac Sync")
        #expect((try FileManager.default.attributesOfItem(atPath: folder.url.path)[.posixPermissions] as? Int) == 0o700)

        let r1 = ea.run(folder: folder, passphrase: pass, request: request("Mac A"))
        #expect(r1.pushed && r1.hardError == nil && r1.merge.imported == 0)
        let r2 = eb.run(folder: folder, passphrase: pass, request: request("Mac B"))
        #expect(r2.pushed && r2.merge.imported == 1)
        let r3 = ea.run(folder: folder, passphrase: pass, request: request("Mac A"))
        #expect(r3.merge.imported == 1)
        #expect(try hashes(ea) == hashes(eb))

        // files: only device-<id>.dmsync, mode 0600, no temp leftovers
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
        #expect(names.count == 2 && names.allSatisfy { $0.hasPrefix("device-") && $0.hasSuffix(".dmsync") })
        for n in names {
            #expect((try FileManager.default.attributesOfItem(atPath: folder.url.appendingPathComponent(n).path)[.posixPermissions] as? Int) == 0o600)
        }
        // device list: names come from the decrypted payload
        #expect(r3.devices.count == 2)
        #expect(r3.devices.contains { $0.isThisDevice && $0.deviceName == "Mac A" })
        #expect(r3.devices.contains { $0.deviceName == "Mac B" && $0.status == .ok && $0.clipCount == 2 })

        // unchanged state: no rewrite
        let r4 = ea.run(folder: folder, passphrase: pass, request: request("Mac A"))
        #expect(r4.pushSkippedUnchanged && !r4.pushed)
        try addClip(a, "new on A", date: base + 3)
        #expect(ea.run(folder: folder, passphrase: pass, request: request("Mac A")).pushed)
        // remote change detection
        #expect(eb.hasRemoteChanges(in: folder))
        _ = eb.run(folder: folder, passphrase: pass, request: request("Mac B"))
        #expect(!eb.hasRemoteChanges(in: folder))
        #expect(try hashes(ea) == hashes(eb))

        // a Mac with the wrong passphrase sees an unreadable device and imports nothing
        let c = try ClipStore.inMemory()
        let rc = engine(c).run(folder: folder, passphrase: "a different passphrase", request: request("Mac C"))
        #expect(rc.merge.imported == 0)
        #expect(rc.devices.filter { $0.status == .wrongPassphrase }.count == 2)
        #expect(try c.count(ClipFilter(limit: 0)) == 0)
    }

    @Test func folderIgnoresStrangeFilesAndSymlinks() throws {
        let tmp = tempDir()
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = try SyncFolder.open(baseFolder: tmp)
        let fm = FileManager.default
        try Data("x".utf8).write(to: folder.url.appendingPathComponent("device-evil.dmsync"))
        try Data("x".utf8).write(to: folder.url.appendingPathComponent("../escape.dmsync".replacingOccurrences(of: "../", with: "")))
        try Data("x".utf8).write(to: tmp.appendingPathComponent("target.bin"))
        try fm.createSymbolicLink(at: folder.url.appendingPathComponent("device-\(UUID().uuidString).dmsync"),
                                  withDestinationURL: tmp.appendingPathComponent("target.bin"))
        #expect(folder.deviceFiles().isEmpty)
        #expect(throws: (any Error).self) { try folder.write(Data(), named: "../x.dmsync") }
        #expect(throws: (any Error).self) { try folder.write(Data(), named: "x.txt") }
        #expect(throws: (any Error).self) { _ = try SyncFolder.open(baseFolder: tmp.appendingPathComponent("missing")) }
        // a garbage device file is reported, never crashes the run
        let other = UUID().uuidString
        try Data(repeating: 0x41, count: 500).write(to: folder.url.appendingPathComponent(SyncFolder.deviceFileName(other)))
        let a = try ClipStore.inMemory()
        let rep = engine(a).run(folder: folder, passphrase: pass, request: request("A"))
        #expect(rep.hardError == nil && rep.devices.contains { $0.fileName.contains(other.uppercased()) && $0.status == .unreadable })
    }

    @Test func rollingBackupsAreCreatedAndPruned() throws {
        let tmp = tempDir()
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = try ClipStore.inMemory()
        let ea = engine(a)
        try addClip(a, "backed up", date: base)
        let folder = try SyncFolder.open(baseFolder: tmp)
        let req = request("My Mac/2", backupKeep: 2)
        var written: [String] = []
        for day in 0..<4 {
            let rep = ea.run(folder: folder, passphrase: pass, request: req, now: Date(timeIntervalSince1970: base + Double(day) * 86_400 + 3600))
            if let f = rep.backupFile { written.append(f) }
            // same day again: no second backup
            #expect(ea.run(folder: folder, passphrase: pass, request: req, now: Date(timeIntervalSince1970: base + Double(day) * 86_400 + 7200)).backupFile == nil)
        }
        #expect(written.count == 4)
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).filter { $0.hasPrefix("backup-") }.sorted()
        #expect(backups.count == 2)
        #expect(backups == Array(written.sorted().suffix(2)))
        #expect(backups.allSatisfy { !$0.contains("/") && $0.hasSuffix("-My-Mac-2.dmsync") })
        // restore from a backup into an empty store (with different tombstone state)
        let b = try ClipStore.inMemory()
        let m = try engine(b).restore(from: folder.url.appendingPathComponent(backups[0]), passphrase: pass)
        #expect(m.imported == 1)
        #expect(throws: (any Error).self) { _ = try engine(b).restore(from: folder.url.appendingPathComponent(backups[0]), passphrase: "wrong passphrase!!") }
    }

    @Test func settingsDefaultsAndClamps() {
        let d = UserDefaults(suiteName: "dittomac-sync-test-\(UUID().uuidString)")!
        let s = Settings(defaults: d)
        #expect(!s.syncEnabled && s.syncIntervalMinutes == 5 && s.syncIncludeImages && s.syncIncludeRich)
        #expect(s.syncMaxTotalMB == 150 && !s.syncBackups && s.syncBackupKeep == 7)
        s.syncIntervalMinutes = 999; #expect(s.syncIntervalMinutes == 60)
        s.syncIntervalMinutes = 0; #expect(s.syncIntervalMinutes == 1)
        s.syncBackupKeep = 100; #expect(s.syncBackupKeep == 30)
        s.syncMaxTotalMB = 1; #expect(s.syncMaxTotalMB == 10)
        let id = s.syncDeviceID
        #expect(UUID(uuidString: id) != nil && s.syncDeviceID == id)
        #expect(!s.syncDeviceName.isEmpty)
        #expect(s.syncOptions.maxTotalBytes == 10 * 1024 * 1024)
    }
}
