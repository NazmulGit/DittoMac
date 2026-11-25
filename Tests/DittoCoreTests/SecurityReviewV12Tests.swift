// Regression tests for the v1.2 security review (docs/kb/security-review-v12.md).
import CryptoKit
import Foundation
import Testing
@testable import DittoCore

private func secTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("dm-sec12-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@discardableResult
private func add(_ s: ClipStore, _ formats: [ClipFormat], _ desc: String) throws -> Int64 {
    guard case .inserted(let id) = try s.addClip(formats: formats, description: desc, sourceApp: "test") else {
        throw SyncError.io("add failed")
    }
    return id
}

@Suite struct SecurityReviewV12Tests {
    // S5: background readers must never get a locked clip's plaintext, even while the vault is unlocked.
    @Test func unlockedFormatsRefusesLockedClipsEvenWhileUnlocked() throws {
        let s = try ClipStore.inMemory()
        let plain = try add(s, [textFormat("public text")], "public")
        let secret = try add(s, [textFormat("top secret")], "secret")
        s.vaultKey = Vault.newDataKey()
        try s.lock(ids: [secret])
        #expect(try s.formats(clipID: secret).first?.data == Data("top secret".utf8))   // unlocked session reads it
        #expect(try s.unlockedFormats(clipID: secret) == nil)                          // ...but not this API
        #expect(try s.unlockedFormats(clipID: plain)?.first?.data == Data("public text".utf8))
        // The sync snapshot (built through it) never contains the locked note.
        let e = SyncEngine(store: s, stateDirectory: nil, deviceID: UUID().uuidString)
        let snap = try e.makeSnapshot(deviceName: "Mac")
        #expect(snap.clips.count == 1)
        #expect(!snap.clips.contains { $0.formats.contains { $0.data == Data("top secret".utf8) } })
        #expect(!snap.clips.contains { $0.description.contains("secret") })
    }

    // S7: file-reference pasteboard types are neither exported nor imported.
    @Test func syncDropsFileReferenceTypes() throws {
        let o = SyncOptions()
        for t in ["NSFilenamesPboardType", ClipUTI.fileURL, "com.apple.pasteboard.promised-file-url", "org.dittomac.internal"] {
            #expect(!SyncEngine.includes(type: t, size: 10, o))
        }
        #expect(SyncEngine.includes(type: ClipUTI.plainText, size: 10, o))

        let s = try ClipStore.inMemory()
        let e = SyncEngine(store: s, stateDirectory: nil, deviceID: UUID().uuidString)
        let plist = Data(#"<plist><array><string>/Users/victim/.ssh/id_ed25519</string></array></plist>"#.utf8)
        let text = Data("hello".utf8)
        let fmts = [ClipFormat(type: ClipUTI.plainText, data: text), ClipFormat(type: "NSFilenamesPboardType", data: plist)]
        let clip = SyncClip(contentHash: SyncHash.contentHash(fmts), date: 1_700_000_000, lastPasteDate: 1_700_000_000,
                            description: "hello", formats: fmts.map { SyncFormat(type: $0.type, data: $0.data) })
        let m = try e.merge(SyncSnapshot(deviceID: UUID().uuidString, deviceName: "Other", createdAt: 1_700_000_000, clips: [clip]),
                            now: Date(timeIntervalSince1970: 1_700_000_100))
        #expect(m.imported == 1)
        let id = try #require(try s.clips(ClipFilter(limit: 0)).first?.id)
        #expect(try s.formats(clipID: id).map(\.type) == [ClipUTI.plainText])
    }

    // S6: reading sync files never follows a symlink, and a symlinked "DittoMac Sync" folder is refused.
    @Test func syncFileReadsRefuseSymlinks() throws {
        let dir = try secTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real.dmsync")
        try Data("DMSYNC1-test".utf8).write(to: real)
        #expect(try SyncFolder.readLimited(real) == Data("DMSYNC1-test".utf8))
        let link = dir.appendingPathComponent("device-link.dmsync")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: SyncError.self) { try SyncFolder.readLimited(link) }
        #expect(throws: SyncError.self) { try SyncFolder.readLimited(dir) }     // a directory is not a regular file

        let cloud = dir.appendingPathComponent("Cloud", isDirectory: true)
        let elsewhere = dir.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cloud.appendingPathComponent(SyncFolder.directoryName), withDestinationURL: elsewhere)
        #expect(throws: SyncError.self) { try SyncFolder.open(baseFolder: cloud) }
        // A normal folder still works.
        let ok = dir.appendingPathComponent("Cloud2", isDirectory: true)
        try FileManager.default.createDirectory(at: ok, withIntermediateDirectories: true)
        #expect(try SyncFolder.open(baseFolder: ok).url.lastPathComponent == SyncFolder.directoryName)
    }

    // U1: a cross-host redirect that would re-send the upload body (307/308 keep POST) is refused.
    @Test func crossHostRedirectNeverResendsTheBody() {
        let from = URL(string: "https://upload.example.com/u")
        let other = URL(string: "https://elsewhere.example.net/x")
        #expect(RedirectPolicy.decide(from: from, to: other, method: "POST") == .refuse)
        #expect(RedirectPolicy.decide(from: from, to: other, method: "PUT") == .refuse)
        #expect(RedirectPolicy.decide(from: from, to: other, method: "GET") == .followStrippingCredentials)
        #expect(RedirectPolicy.decide(from: from, to: other, method: nil) == .followStrippingCredentials)
        #expect(RedirectPolicy.decide(from: from, to: URL(string: "https://upload.example.com/v2"), method: "POST") == .follow)
        #expect(RedirectPolicy.decide(from: from, to: URL(string: "http://upload.example.com/v2"), method: "GET") == .refuse)
    }

    // U3: an oversized history file is ignored without being read.
    @Test func uploadHistoryIgnoresOversizedFiles() throws {
        let dir = try secTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("uploads.json")
        #expect(UploadHistoryFile.save(["a", "b"], to: url))
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        #expect(UploadHistoryFile.load(String.self, from: url) == ["a", "b"])
        try Data(count: 9 * 1024 * 1024).write(to: url)
        #expect(UploadHistoryFile.load(String.self, from: url).isEmpty)
    }

    // V9: key derivation is unchanged by the password-buffer wiping (known answer from RFC 7914 §11 PBKDF2-SHA256).
    @Test func pbkdf2StillMatchesKnownAnswerAfterWipe() throws {
        let k = try Vault.deriveKey(password: "passwd", salt: Data("salt".utf8), iterations: 1, minimumIterations: 1)
        let hex = k.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        #expect(hex == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    }
}
