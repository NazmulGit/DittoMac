import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import DittoCore

/// Fast iteration floor for tests (production clamps to Vault.iterationRange).
private let testIterations = 1_000

private func formatsTRP() -> [ClipFormat] {
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.append(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
    return [ClipFormat(type: ClipUTI.plainText, data: Data("secret body text 🔐".utf8)),
            ClipFormat(type: ClipUTI.rtf, data: Data(#"{\rtf1\ansi {\b bold secret}}"#.utf8)),
            ClipFormat(type: ClipUTI.png, data: png)]
}

@discardableResult
private func addFormats(_ s: ClipStore, _ formats: [ClipFormat], _ desc: String, parent: Int64 = -1) throws -> Int64 {
    switch try s.addClip(formats: formats, description: desc, sourceApp: "test", parentID: parent) {
    case .inserted(let id), .duplicateBumped(let id): return id
    case .rejected: throw SQLiteError(code: -1, message: "rejected")
    }
}

private func strip(_ f: [ClipFormat]) -> [ClipFormat] { f.map { ClipFormat(type: $0.type, data: $0.data) } }

@Suite struct VaultCryptoTests {
    @Test func sealOpenRoundTripAndTamperDetection() throws {
        let key = Vault.newDataKey()
        let aad = Data("clip|1|public.utf8-plain-text".utf8)
        let msg = Data("hello vault".utf8)
        let sealed = try Vault.seal(msg, key: key, aad: aad)
        #expect(sealed.count == msg.count + Vault.sealOverhead)
        #expect(try Vault.open(sealed, key: key, aad: aad) == msg)
        // Fresh nonce each time.
        #expect(try Vault.seal(msg, key: key, aad: aad) != sealed)
        // Flip each region: nonce, ciphertext, tag.
        for i in [0, 13, sealed.count - 1] {
            var bad = sealed
            bad[i] ^= 0x01
            #expect(throws: VaultError.invalidCiphertext) { try Vault.open(bad, key: key, aad: aad) }
        }
        #expect(throws: VaultError.invalidCiphertext) { try Vault.open(sealed, key: Vault.newDataKey(), aad: aad) }
        #expect(throws: VaultError.invalidCiphertext) { try Vault.open(sealed, key: key, aad: Data("clip|2|x".utf8)) }
        #expect(throws: VaultError.invalidCiphertext) { try Vault.open(Data([1, 2, 3]), key: key, aad: aad) }
        // Empty payloads work too.
        #expect(try Vault.open(try Vault.seal(Data(), key: key, aad: aad), key: key, aad: aad).isEmpty)
    }

    @Test func iterationClamp() {
        #expect(Vault.clampIterations(1) == 100_000)
        #expect(Vault.clampIterations(-5) == 100_000)
        #expect(Vault.clampIterations(600_000) == 600_000)
        #expect(Vault.clampIterations(Int.max) == 2_000_000)
        #expect(Vault.clampIterations(5, minimum: testIterations) == testIterations)
        #expect(Vault.defaultIterations == 600_000)
    }

    @Test func pbkdf2KnownAnswer() throws {
        // RFC 7914 §11 PBKDF2-HMAC-SHA256 vector: P="passwd", S="salt", c=1, first 32 bytes.
        let key = try Vault.deriveKey(password: "passwd", salt: Data("salt".utf8), iterations: 1, minimumIterations: 1)
        let hex = Vault.keyData(key).map { String(format: "%02x", $0) }.joined()
        #expect(hex == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
        // Deterministic, salt-sensitive, NFC-normalised.
        let a = try Vault.deriveKey(password: "caf\u{E9}12345", salt: Data("s".utf8), iterations: 10, minimumIterations: 1)
        let b = try Vault.deriveKey(password: "cafe\u{301}12345", salt: Data("s".utf8), iterations: 10, minimumIterations: 1)
        let c = try Vault.deriveKey(password: "caf\u{E9}12345", salt: Data("t".utf8), iterations: 10, minimumIterations: 1)
        #expect(Vault.keyData(a) == Vault.keyData(b))
        #expect(Vault.keyData(a) != Vault.keyData(c))
        // Empty password doesn't crash.
        _ = try Vault.deriveKey(password: "", salt: Data("s".utf8), iterations: 1, minimumIterations: 1)
    }

    @Test func wrapUnwrapAndWrongPassword() throws {
        let dataKey = Vault.newDataKey()
        let w = try Vault.wrap(dataKey: dataKey, password: "correct horse", iterations: testIterations, minimumIterations: testIterations)
        #expect(w.iterations == testIterations)
        #expect(w.salt.count == Vault.saltByteCount)
        #expect(!w.wrapped.isEmpty && w.verifier.count == 32)
        // Stored blob contains no plaintext key.
        let blob = try w.encoded()
        #expect(blob.range(of: Vault.keyData(dataKey)) == nil)
        let back = try Vault.unwrap(try Vault.WrappedKey.decode(blob), password: "correct horse", minimumIterations: testIterations)
        #expect(Vault.keyData(back) == Vault.keyData(dataKey))
        #expect(throws: VaultError.wrongPassword) {
            try Vault.unwrap(w, password: "correct horsE", minimumIterations: testIterations)
        }
        // Tampered wrapped key (verifier still matches) → treated as wrong password, never a bad key.
        var t = w
        t.wrapped[t.wrapped.count - 1] ^= 1
        #expect(throws: VaultError.wrongPassword) { try Vault.unwrap(t, password: "correct horse", minimumIterations: testIterations) }
        var v = w
        v.version = 99
        #expect(throws: VaultError.unsupportedVersion) { try Vault.unwrap(v, password: "correct horse", minimumIterations: testIterations) }
        // A stored low iteration count is clamped up in production, so unwrap with the real floor fails.
        #expect(throws: VaultError.wrongPassword) { try Vault.unwrap(w, password: "correct horse") }
    }

    @Test func passwordPolicyAndStrength() {
        #expect(Vault.passwordProblem("short") != nil)
        #expect(Vault.passwordProblem("        ") != nil)
        #expect(Vault.passwordProblem("eightchr") == nil)
        #expect(throws: VaultError.self) { try Vault.wrap(dataKey: Vault.newDataKey(), password: "1234567") }
        #expect(Vault.strength("abc") == .tooShort)
        #expect(Vault.strength("aaaaaaaaaa") == .weak)
        #expect(Vault.strength("Tr0ub4dor&3x") == .strong)
        #expect(Vault.strength("correct horse battery") == .strong)
    }

    @Test func constantTimeCompare() {
        #expect(Vault.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!Vault.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        #expect(!Vault.constantTimeEqual(Data([1, 2]), Data([1, 2, 3])))
        #expect(Vault.constantTimeEqual(Data(), Data()))
        let d = Data([9, 1, 2, 3])
        #expect(Vault.constantTimeEqual(d.dropFirst(), Data([1, 2, 3])))
    }

    @Test func keyFromDataValidatesLength() throws {
        #expect(throws: VaultError.invalidKey) { try Vault.key(from: Data(count: 16)) }
        let k = Vault.newDataKey()
        #expect(Vault.keyData(try Vault.key(from: Vault.keyData(k))) == Vault.keyData(k))
    }
}

@Suite struct VaultStoreTests {
    @Test func lockRemoveLockRoundTripRestoresBytesExactly() throws {
        let s = try ClipStore.inMemory()
        let id = try addFormats(s, formatsTRP(), "my secret")
        var c = try #require(try s.clip(id: id))
        c.quickPasteText = "qp-secret"
        try s.update(c)
        let before = try #require(try s.clip(id: id))
        let beforeFormats = strip(try s.formats(clipID: id))

        #expect(throws: ClipStoreError.locked) { try s.lock(ids: [id]) }
        s.vaultKey = Vault.newDataKey()
        #expect(try s.lock(ids: [id]) == 1)
        #expect(try s.lock(ids: [id]) == 0)          // already locked
        #expect(try s.lockedCount() == 1)

        // Unlocked session: transparent decryption.
        let open = try #require(try s.clip(id: id))
        #expect(open.isLocked && open.text == "my secret" && open.quickPasteText == "qp-secret")
        #expect(strip(try s.formats(clipID: id)) == beforeFormats)
        #expect(try s.data(clipID: id, type: ClipUTI.png) == beforeFormats[2].data)
        #expect(try s.formatTypes(clipID: id).map(\.size) == beforeFormats.map(\.data.count))
        #expect(try s.clips(ClipFilter()).first?.text == "my secret")

        #expect(try s.removeLock(ids: [id]) == 1)
        let after = try #require(try s.clip(id: id))
        #expect(!after.isLocked)
        #expect(after.text == before.text && after.quickPasteText == before.quickPasteText && after.crc == before.crc)
        #expect(strip(try s.formats(clipID: id)) == beforeFormats)
        #expect(try s.lockedCount() == 0)
    }

    @Test func lockedClipReadsAsPlaceholderWithoutKey() throws {
        let s = try ClipStore.inMemory()
        let id = try addFormats(s, formatsTRP(), "hidden description")
        let crc = try #require(try s.clip(id: id)).crc
        try s.lock(ids: [id], key: Vault.newDataKey())          // lock without opening the session
        #expect(s.vaultKey == nil)
        let c = try #require(try s.clip(id: id))
        #expect(c.isLocked)
        #expect(c.text == ClipStore.lockedPlaceholder && c.text == "Locked note")
        #expect(c.quickPasteText.isEmpty)
        #expect(c.crc != crc)
        #expect(try s.formats(clipID: id).isEmpty)
        #expect(try s.formatTypes(clipID: id).isEmpty)
        #expect(try s.data(clipID: id, type: ClipUTI.plainText) == nil)
        // Wrong key: still placeholder, no formats, removeLock refuses and changes nothing.
        s.vaultKey = Vault.newDataKey()
        #expect(try s.clip(id: id)?.text == "Locked note")
        #expect(try s.formats(clipID: id).isEmpty)
        #expect(throws: ClipStoreError.decryptionFailed) { try s.removeLock(ids: [id]) }
        #expect(try s.clip(id: id)?.isLocked == true)
    }

    @Test func plaintextNeverStoredForLockedClip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("v.db").path
        let s = try ClipStore(path: path)
        let marker = "ZZ-UNIQUE-PLAINTEXT-MARKER-1234567890"
        let id = try addFormats(s, [ClipFormat(type: ClipUTI.plainText, data: Data((marker + " body").utf8))], marker + " desc")
        let key = Vault.newDataKey()
        s.vaultKey = key
        try s.lock(ids: [id])
        // Edits while unlocked are re-encrypted, never written to mText.
        var c = try #require(try s.clip(id: id))
        c.text = marker + " edited"
        c.quickPasteText = marker + " qp"
        try s.update(c)
        try s.replaceFormats(clipID: id, formats: [ClipFormat(type: ClipUTI.plainText, data: Data((marker + " new").utf8))],
                             description: marker + " newdesc")
        #expect(try s.clip(id: id)?.text == marker + " newdesc")
        #expect(try s.clip(id: id)?.quickPasteText == marker + " qp")
        #expect(try s.data(clipID: id, type: ClipUTI.plainText) == Data((marker + " new").utf8))
        try s.vacuum()
        var bytes = Data()
        for suffix in ["", "-wal"] { bytes.append((try? Data(contentsOf: URL(fileURLWithPath: path + suffix))) ?? Data()) }
        #expect(bytes.range(of: Data(marker.utf8)) == nil)

        // Without key: text edits ignored, other fields still saved, replaceFormats refused.
        s.vaultKey = nil
        var p = try #require(try s.clip(id: id))
        p.text = "attempted overwrite"
        p.dontAutoDelete = true
        p.isLocked = false                                     // can't unlock through update
        try s.update(p)
        #expect(throws: ClipStoreError.locked) {
            try s.replaceFormats(clipID: id, formats: [textFormat("x")], description: "x")
        }
        s.vaultKey = key
        let q = try #require(try s.clip(id: id))
        #expect(q.isLocked && q.dontAutoDelete && q.text == marker + " newdesc")
        // A clip still holding the placeholder (read while locked) doesn't clobber the stored text.
        var r = p
        r.text = ClipStore.lockedPlaceholder
        r.quickPasteText = ""
        try s.update(r)
        #expect(try s.clip(id: id)?.text == marker + " newdesc")
    }

    @Test func deleteProtectionThroughEveryPath() throws {
        let s = try ClipStore.inMemory()
        let key = Vault.newDataKey()
        let locked = try addFormats(s, formatsTRP(), "locked")
        let group = try s.createGroup(name: "G")
        let lockedChild = try addFormats(s, [textFormat("child secret")], "child", parent: group)
        for i in 0..<5 { try add(s, "plain \(i)") }
        try s.lock(ids: [locked, lockedChild], key: key)
        let lockedSet: Set<Int64> = [locked, lockedChild]
        func survivors() throws -> Set<Int64> { Set(try s.lockedIDs()) }

        // delete(ids:)
        let plain = try add(s, "to delete")
        #expect(try s.delete(ids: [locked, lockedChild, plain]) == 1)
        #expect(try survivors() == lockedSet)
        #expect(try s.clip(id: plain) == nil)

        // Group delete re-parents (doesn't delete) the locked child.
        try s.delete(ids: [group])
        #expect(try s.clip(id: lockedChild)?.parentID == Ditto.topLevelParent)
        #expect(try survivors() == lockedSet)

        // Retention by max entries and by expiry.
        _ = try s.applyRetention(maxEntries: 1, expireDays: nil)
        #expect(try survivors() == lockedSet)
        _ = try s.applyRetention(maxEntries: nil, expireDays: 1, now: Date().addingTimeInterval(30 * 86_400))
        #expect(try survivors() == lockedSet)

        // deleteNonUsedClips
        for i in 0..<3 { try add(s, "nonused \(i)") }
        _ = try s.deleteNonUsedClips()
        #expect(try survivors() == lockedSet)

        // deleteData (whole clips and single formats) and clipsMatching
        #expect(try s.clipsMatching(dataFilter: ClipDataFilter()).allSatisfy { !$0.clip.isLocked })
        try s.deleteData(clipIDs: [locked], types: nil)
        try s.deleteData(clipIDs: [locked], types: [ClipUTI.plainText, ClipUTI.rtf, ClipUTI.png])
        s.vaultKey = key
        #expect(try s.formats(clipID: locked).count == 3)
        s.vaultKey = nil
        #expect(try survivors() == lockedSet)

        // deleteFormat on a locked clip without the key is a no-op.
        s.vaultKey = key
        let fid = try #require(try s.formats(clipID: locked).first?.id)
        s.vaultKey = nil
        try s.deleteFormat(formatID: fid)
        s.vaultKey = key
        #expect(try s.formats(clipID: locked).count == 3)
        s.vaultKey = nil

        // deleteAll keeps locked clips (and moves them out of deleted groups).
        let g2 = try s.createGroup(name: "G2")
        try s.move(ids: [lockedChild], toGroup: g2)              // moving a locked clip still works
        #expect(try s.clip(id: lockedChild)?.parentID == g2)
        try add(s, "plain again")
        #expect(try s.deleteAll() >= 2)
        #expect(try survivors() == lockedSet)
        #expect(try s.clip(id: lockedChild)?.parentID == Ditto.topLevelParent)
        #expect(try s.count(ClipFilter()) == 2)

        // vacuum / maintenance
        try s.vacuum()
        #expect(try survivors() == lockedSet)

        // copyClips skips locked
        #expect(try s.copyClips(ids: [locked], toGroup: Ditto.topLevelParent).isEmpty)

        // deleteLocked needs an unlocked session.
        #expect(throws: ClipStoreError.locked) { try s.deleteLocked(ids: [locked]) }
        s.vaultKey = key
        #expect(try s.deleteLocked(ids: [locked]) == 1)
        #expect(try s.lockedIDs() == [lockedChild])
        // Vault reset purges without a key.
        s.vaultKey = nil
        #expect(try s.purgeLockedClips() == 1)
        #expect(try s.lockedCount() == 0)
        #expect(try s.stats().formats == 0)
    }

    @Test func stickyAndFlagsStillWorkOnLockedClips() throws {
        let s = try ClipStore.inMemory()
        let id = try add(s, "note")
        try s.lock(ids: [id], key: Vault.newDataKey())
        try s.makeTopSticky(id: id, inGroup: false)
        #expect(try s.clip(id: id)?.isSticky == true)
        try s.removeSticky(id: id)
        try s.moveToTop(id: id)
        try s.markPasted(id: id, moveToTop: true)
        #expect(try s.clip(id: id)?.isLocked == true)
    }

    @Test func searchNeverMatchesLockedContent() throws {
        let s = try ClipStore.inMemory()
        let id = try addFormats(s, [textFormat("needle in a locked body")], "needle desc")
        try add(s, "plain haystack")
        try s.lock(ids: [id], key: Vault.newDataKey())
        var f = ClipFilter()
        for text in ["needle", "body"] {
            var q = SearchQuery(text, mode: .contains)
            q.searchDescription = true; q.searchFullText = true; q.searchQuickPaste = true
            f.search = q
            #expect(try s.clips(f).isEmpty)
        }
        var q = SearchQuery(".", mode: .regex)
        q.searchDescription = false; q.searchFullText = true; q.searchQuickPaste = false
        f.search = q
        #expect(try s.clips(f).map(\.text) == ["plain haystack"])
    }

    @Test func dedupeDoesNotTouchLockedClips() throws {
        let s = try ClipStore.inMemory()
        let id = try add(s, "same")
        try s.lock(ids: [id], key: Vault.newDataKey())
        guard case .inserted(let newID) = try s.addClip(formats: [textFormat("same")], description: "same", sourceApp: "") else {
            Issue.record("expected insert"); return
        }
        #expect(newID != id)
    }

    @Test func exportSkipsLockedAndImportSkipsEncrypted() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = try ClipStore(path: dir.appendingPathComponent("src.db").path)
        let g = try s.createGroup(name: "Group")
        let a = try add(s, "visible")
        let b = try add(s, "secret", parent: g)
        let c = try add(s, "visible child", parent: g)
        let key = Vault.newDataKey()
        s.vaultKey = key
        try s.lock(ids: [b])
        let out = dir.appendingPathComponent("x.dittoclips")
        #expect(try ImportExport.exportClips(ids: [a, b, g], from: s, to: out) == 2)
        _ = c
        let exported = try ClipStore(path: out.path)
        #expect(try exported.lockedCount() == 0)
        #expect(Set(try exported.clips(ClipFilter()).map(\.text)) == ["visible", "visible child"])

        // Importing a whole DittoMac v2 database never brings encrypted rows in.
        let target = try ClipStore.inMemory()
        let summary = try ImportExport.importClips(from: dir.appendingPathComponent("src.db"), into: target)
        #expect(summary.clipsImported == 2)
        #expect(try target.lockedCount() == 0)
        #expect(!(try target.clips(ClipFilter()).map(\.text)).contains("Locked note"))
    }

    @Test func migratesV1DatabaseToV2() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("v1.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let v1 = """
        CREATE TABLE Main(lID INTEGER PRIMARY KEY AUTOINCREMENT, lDate INTEGER NOT NULL, mText TEXT NOT NULL DEFAULT '',
          lShortCut INTEGER NOT NULL DEFAULT 0, lDontAutoDelete INTEGER NOT NULL DEFAULT 0, CRC INTEGER NOT NULL DEFAULT 0,
          bIsGroup INTEGER NOT NULL DEFAULT 0, lParentID INTEGER NOT NULL DEFAULT -1, QuickPasteText TEXT NOT NULL DEFAULT '',
          clipOrder REAL NOT NULL DEFAULT 0, clipGroupOrder REAL NOT NULL DEFAULT 0, globalShortCut INTEGER NOT NULL DEFAULT 0,
          lastPasteDate INTEGER NOT NULL DEFAULT 0, stickyClipOrder REAL NOT NULL DEFAULT -2147483647,
          stickyClipGroupOrder REAL NOT NULL DEFAULT -2147483647, MoveToGroupShortCut INTEGER NOT NULL DEFAULT 0,
          GlobalMoveToGroupShortCut INTEGER NOT NULL DEFAULT 0, sourceApp TEXT NOT NULL DEFAULT '');
        CREATE TABLE Data(lID INTEGER PRIMARY KEY AUTOINCREMENT, lParentID INTEGER NOT NULL REFERENCES Main(lID) ON DELETE CASCADE,
          strClipBoardFormat TEXT NOT NULL, ooData BLOB NOT NULL);
        CREATE TABLE CopyBuffers(lID INTEGER PRIMARY KEY AUTOINCREMENT, lClipID INTEGER, lCopyBuffer INTEGER);
        INSERT INTO Main(lDate, mText, CRC, clipOrder, clipGroupOrder, lastPasteDate, QuickPasteText)
          VALUES(1700000000, 'old clip', 0, 1, 1, 1700000000, 'oq');
        INSERT INTO Data(lParentID, strClipBoardFormat, ooData) VALUES(1, 'public.utf8-plain-text', CAST('old body' AS BLOB));
        PRAGMA user_version = 1;
        """
        #expect(sqlite3_exec(db, v1, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let s = try ClipStore(path: path)
        let c = try #require(try s.clip(id: 1))
        #expect(c.text == "old clip" && c.quickPasteText == "oq" && !c.isLocked)
        #expect(try s.data(clipID: 1, type: ClipUTI.plainText) == Data("old body".utf8))
        // Schema is v2 and works.
        var check: OpaquePointer?
        #expect(sqlite3_open(path, &check) == SQLITE_OK)
        var st: OpaquePointer?
        sqlite3_prepare_v2(check, "PRAGMA user_version", -1, &st, nil)
        #expect(sqlite3_step(st) == SQLITE_ROW)
        #expect(sqlite3_column_int(st, 0) == 2)
        sqlite3_finalize(st)
        sqlite3_close(check)
        let key = Vault.newDataKey()
        s.vaultKey = key
        try s.lock(ids: [1])
        s.vaultKey = nil
        // Reopen: still v2, still locked, migration is idempotent.
        let reopened = try ClipStore(path: path)
        #expect(try reopened.clip(id: 1)?.text == "Locked note")
        reopened.vaultKey = key
        #expect(try reopened.clip(id: 1)?.text == "old clip")
    }

    @Test func vaultSourcesUseBoundParametersOnly() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/DittoCore")
        let keywords = ["SELECT", "INSERT", "UPDATE", "DELETE", "WHERE", "LIKE", "REGEXP", "GLOB", "ORDER BY"]
        for file in ["ClipStore.swift", "ImportExport.swift", "Vault.swift"] {
            let src = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for (n, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where keywords.contains(where: { line.contains($0) }) {
                #expect(!line.contains("\\("), "string interpolation in SQL at \(file):\(n + 1)")
            }
        }
    }

    @Test func concurrentLockUnlockSmoke() throws {
        let s = try ClipStore.inMemory()
        var ids: [Int64] = []
        for i in 0..<40 { ids.append(try add(s, "c\(i)")) }
        let key = Vault.newDataKey()
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            switch i % 4 {
            case 0: _ = try? s.lock(ids: [ids[i]], key: key)
            case 1: _ = try? s.clips(ClipFilter())
            case 2: s.vaultKey = (i % 8 == 1) ? key : nil
            default: _ = try? s.formats(clipID: ids[i]); _ = try? s.delete(ids: [ids[i]])
            }
        }
        s.vaultKey = key
        for id in try s.lockedIDs() {
            #expect(try s.formats(clipID: id).count == 1)
            #expect(try s.clip(id: id)?.text.hasPrefix("c") == true)
        }
        let n = try s.lockedCount()
        #expect(try s.removeLock(ids: ids) == n)
        #expect(try s.lockedCount() == 0)
    }
}
