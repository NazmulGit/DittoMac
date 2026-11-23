import Foundation
import Testing
@testable import DittoCore

func textFormat(_ s: String) -> ClipFormat { ClipFormat(type: ClipUTI.plainText, data: Data(s.utf8)) }

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dittocore-tests-" + UUID().uuidString)
    return url
}

@discardableResult
func add(_ store: ClipStore, _ s: String, parent: Int64 = -1, options: ClipStore.AddOptions = .init()) throws -> Int64 {
    switch try store.addClip(formats: [textFormat(s)], description: s, sourceApp: "test", parentID: parent, options: options) {
    case .inserted(let id), .duplicateBumped(let id): return id
    case .rejected: throw SQLiteError(code: -1, message: "rejected")
    }
}

func texts(_ store: ClipStore, _ filter: ClipFilter = ClipFilter()) throws -> [String] {
    try store.clips(filter).map(\.text)
}

@Suite struct ClipStoreTests {

    // MARK: dedupe

    @Test func dedupeBumpsExistingTopLevelClip() throws {
        let s = try ClipStore.inMemory()
        guard case .inserted(let a) = try s.addClip(formats: [textFormat("a")], description: "a", sourceApp: "") else {
            Issue.record("expected insert"); return
        }
        try add(s, "b")
        let r = try s.addClip(formats: [textFormat("a")], description: "a", sourceApp: "")
        #expect(r == .duplicateBumped(a))
        #expect(try texts(s) == ["a", "b"])
        #expect(try s.count(ClipFilter()) == 2)
    }

    @Test func emptyFormatsRejected() throws {
        let s = try ClipStore.inMemory()
        #expect(try s.addClip(formats: [], description: "x", sourceApp: "") == .rejected)
    }

    @Test func backToBackModeComparesOnlyLastInserted() throws {
        let s = try ClipStore.inMemory()
        var o = ClipStore.AddOptions()
        o.allowDuplicates = true
        let a = try add(s, "a", options: o)
        #expect(try s.addClip(formats: [textFormat("a")], description: "a", sourceApp: "", options: o) == .duplicateBumped(a))
        try add(s, "b", options: o)
        let r = try s.addClip(formats: [textFormat("a")], description: "a", sourceApp: "", options: o)
        guard case .inserted = r else { Issue.record("expected insert, got \(r)"); return }
        #expect(try texts(s) == ["a", "b", "a"])

        o.allowBackToBackDuplicates = true
        let r2 = try s.addClip(formats: [textFormat("a")], description: "a", sourceApp: "", options: o)
        guard case .inserted = r2 else { Issue.record("expected insert, got \(r2)"); return }
        #expect(try s.count(ClipFilter()) == 4)
    }

    @Test func clipsCapturedIntoGroupAreNotDeduped() throws {
        let s = try ClipStore.inMemory()
        let g = try s.createGroup(name: "G")
        try add(s, "x", parent: g)
        try add(s, "x", parent: g)
        #expect(try s.children(ofGroup: g).count == 2)
    }

    @Test func crcCoversTypeAndData() {
        let a = CRC32.clipCRC([ClipFormat(type: "t1", data: Data("x".utf8))])
        let b = CRC32.clipCRC([ClipFormat(type: "t2", data: Data("x".utf8))])
        #expect(a != b)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data("6789".utf8), seed: CRC32.checksum(Data("12345".utf8))) == 0xCBF4_3926)
    }

    // MARK: ordering & stickies

    @Test func orderingMoveTopBottomUpDown() throws {
        let s = try ClipStore.inMemory()
        let a = try add(s, "a"); let b = try add(s, "b"); let c = try add(s, "c")
        #expect(try texts(s) == ["c", "b", "a"])
        try s.moveToBottom(id: c)
        #expect(try texts(s) == ["b", "a", "c"])
        try s.moveUp(id: c, inGroup: nil)
        #expect(try texts(s) == ["b", "c", "a"])
        try s.moveDown(id: b, inGroup: nil)
        #expect(try texts(s) == ["c", "b", "a"])
        try s.moveToTop(id: a)
        #expect(try texts(s) == ["a", "c", "b"])
        try s.moveUp(id: a, inGroup: nil)   // already top: no-op
        #expect(try texts(s) == ["a", "c", "b"])
        try s.markPasted(id: b, moveToTop: true)
        #expect(try texts(s) == ["b", "a", "c"])
        _ = c
    }

    @Test func renormalisesWhenGapTooSmall() throws {
        let s = try ClipStore.inMemory()
        let ids = try ["a", "b", "c", "d"].map { try add(s, $0) }
        // squeeze orders together: a < b < c < d with tiny gaps
        for (i, id) in ids.enumerated() {
            var c = try #require(try s.clip(id: id))
            c.clipOrder = 1.0 + Double(i) * 1e-9
            try s.update(c)
        }
        #expect(try texts(s) == ["d", "c", "b", "a"])
        try s.moveUp(id: ids[0], inGroup: nil)
        #expect(try texts(s) == ["d", "c", "a", "b"])
        let orders = try s.clips(ClipFilter()).map(\.clipOrder)
        for i in 1..<orders.count { #expect(orders[i - 1] - orders[i] >= 1e-6) }
    }

    @Test func stickyOrdering() throws {
        let s = try ClipStore.inMemory()
        let a = try add(s, "a"); let b = try add(s, "b"); try add(s, "c")
        try s.makeTopSticky(id: a, inGroup: false)
        #expect(try texts(s) == ["a", "c", "b"])
        try s.makeLastSticky(id: b, inGroup: false)
        #expect(try texts(s) == ["a", "b", "c"])
        #expect(try s.clip(id: b)?.isSticky == true)
        try s.makeTopSticky(id: b, inGroup: false)
        #expect(try texts(s) == ["b", "a", "c"])
        try s.removeSticky(id: b)
        #expect(try s.clip(id: b)?.stickyClipOrder == Ditto.stickySentinel)
        #expect(try texts(s) == ["a", "c", "b"])

        var o = ClipStore.AddOptions()
        o.replaceTopSticky = true
        let d = try add(s, "d", options: o)
        #expect(try s.clip(id: a)?.isSticky == false)
        #expect(try texts(s).first == "d")
        _ = d
    }

    @Test func replaceTopStickyOnExistingClip() throws {
        let s = try ClipStore.inMemory()
        let a = try add(s, "a"); let b = try add(s, "b"); let c = try add(s, "c")
        try s.makeTopSticky(id: a, inGroup: false)
        try s.makeLastSticky(id: b, inGroup: false)
        try s.replaceTopSticky(id: c, inGroup: false)
        #expect(try s.clip(id: a)?.isSticky == false)
        #expect(try s.clip(id: b)?.isSticky == true)   // only the previous top is cleared
        #expect(try s.clip(id: c)?.isSticky == true)
        #expect(try texts(s).first == "c")
        // in a group
        let g = try s.createGroup(name: "G")
        let x = try add(s, "x", parent: g); let y = try add(s, "y", parent: g)
        try s.makeTopSticky(id: x, inGroup: true)
        try s.replaceTopSticky(id: y, inGroup: true)
        #expect(try s.clip(id: x)?.stickyClipGroupOrder == Ditto.stickySentinel)
        #expect(try s.clip(id: y)?.stickyClipGroupOrder != Ditto.stickySentinel)
    }

    @Test func groupOrderingAndListModes() throws {
        let s = try ClipStore.inMemory()
        let g = try s.createGroup(name: "Group")
        let sub = try s.createGroup(name: "Sub", parentID: g)
        try add(s, "top")
        let x = try add(s, "inGroup1", parent: g)
        try add(s, "inGroup2", parent: g)
        // in-group: non-groups first (bIsGroup ASC), newest first
        #expect(try texts(s, ClipFilter(parentID: g)) == ["inGroup2", "inGroup1", "Sub"])
        try s.makeTopSticky(id: x, inGroup: true)
        #expect(try texts(s, ClipFilter(parentID: g)) == ["inGroup1", "inGroup2", "Sub"])
        // history
        #expect(try texts(s, ClipFilter()) == ["inGroup2", "inGroup1", "top"])
        #expect(try texts(s, ClipFilter(showAllClipsInMainList: false)) == ["top"])
        #expect(try texts(s, ClipFilter(showAllClipsInMainList: false, showGroupsInMainList: true)) == ["top", "Group"])
        #expect(try s.groups().map(\.text) == ["Group", "Sub"])
        // cycle guard: moving a group into its own child is ignored
        try s.move(ids: [g], toGroup: sub)
        #expect(try s.clip(id: g)?.parentID == -1)
    }

    // MARK: deletion

    @Test func deletingGroupReparentsChildrenAndCascadesData() throws {
        let s = try ClipStore.inMemory()
        let g = try s.createGroup(name: "G")
        let child = try add(s, "child", parent: g)
        let other = try add(s, "other")
        try s.delete(ids: [g])
        #expect(try s.clip(id: g) == nil)
        #expect(try s.clip(id: child)?.parentID == -1)
        #expect(try s.stats().formats == 2)
        try s.delete(ids: [other])
        #expect(try s.formats(clipID: other).isEmpty)
        #expect(try s.stats().formats == 1)
    }

    @Test func moveAndCopyToGroup() throws {
        let s = try ClipStore.inMemory()
        let g = try s.createGroup(name: "G")
        let a = try add(s, "a")
        try s.move(ids: [a], toGroup: g)
        #expect(try s.clip(id: a)?.parentID == g)
        let copies = try s.copyClips(ids: [a], toGroup: -1)
        #expect(copies.count == 1)
        #expect(try s.formats(clipID: copies[0]).map(\.data) == [Data("a".utf8)])
        try s.move(ids: [a], toGroup: -1)
        #expect(try s.children(ofGroup: g).isEmpty)
    }

    // MARK: retention

    @Test func retentionRespectsProtectionRules() throws {
        let s = try ClipStore.inMemory()
        let old1 = try add(s, "old1")
        let keep = try add(s, "dontAutoDelete")
        let sticky = try add(s, "sticky")
        let shortcut = try add(s, "shortcut")
        let g = try s.createGroup(name: "G")
        let grouped = try add(s, "grouped", parent: g)
        let old2 = try add(s, "old2")
        let newest = try add(s, "newest")

        var c = try #require(try s.clip(id: keep)); c.dontAutoDelete = true; try s.update(c)
        try s.makeTopSticky(id: sticky, inGroup: false)
        c = try #require(try s.clip(id: shortcut)); c.shortcut = 123; try s.update(c)

        let deleted = try s.applyRetention(maxEntries: 1, expireDays: nil)
        #expect(deleted == 2)
        #expect(try s.clip(id: old1) == nil)
        #expect(try s.clip(id: old2) == nil)
        for id in [keep, sticky, shortcut, grouped, newest, g] { #expect(try s.clip(id: id) != nil) }

        // expiry by lastPasteDate
        let future = Date().addingTimeInterval(10 * 86_400)
        #expect(try s.applyRetention(maxEntries: nil, expireDays: 5, now: future) == 1)
        #expect(try s.clip(id: newest) == nil)
        #expect(try s.applyRetention(maxEntries: 0, expireDays: 0) == 0)
    }

    // MARK: security

    @Test func sqlInjectionStoredVerbatim() throws {
        let s = try ClipStore.inMemory()
        let evil = "'); DROP TABLE Main; -- \" OR 1=1 %_\\"
        let id = try add(s, evil)
        try add(s, "harmless")
        #expect(try s.clip(id: id)?.text == evil)
        #expect(try s.data(clipID: id, type: ClipUTI.plainText) == Data(evil.utf8))
        let found = try s.clips(ClipFilter(search: SearchQuery("\"DROP TABLE Main; --\"")))
        #expect(found.map(\.id) == [id])
        let byContains = try s.clips(ClipFilter(search: SearchQuery(evil, mode: .contains)))
        #expect(byContains.map(\.id) == [id])
        let injected = try s.clips(ClipFilter(search: SearchQuery("x' OR '1'='1")))
        #expect(injected.isEmpty)
        #expect(try s.count(ClipFilter()) == 2)
    }

    @Test func sourcesUseBoundParametersOnly() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/DittoCore")
        let keywords = ["SELECT", "INSERT", "UPDATE", "DELETE", "WHERE", "LIKE", "REGEXP", "GLOB", "ORDER BY"]
        for file in ["ClipStore.swift", "SearchQuery.swift", "ImportExport.swift", "SQLite.swift"] {
            let src = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for (n, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where keywords.contains(where: { line.contains($0) }) {
                #expect(!line.contains("\\("), "string interpolation in SQL at \(file):\(n + 1)")
            }
        }
    }

    @Test func filePermissions() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("sub/Ditto.db").path
        let s = try ClipStore(path: path)
        try add(s, "hello")
        let fm = FileManager.default
        let fileMode = (try fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        let dirMode = (try fm.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)[.posixPermissions] as? NSNumber)?.intValue
        #expect(fileMode == 0o600)
        #expect(dirMode == 0o700)
        if fm.fileExists(atPath: path + "-wal") {
            #expect((try fm.attributesOfItem(atPath: path + "-wal")[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        #expect(try s.stats().databaseBytes > 0)

        // backup
        let backup = dir.appendingPathComponent("backup.db")
        try s.backup(to: backup)
        #expect((try fm.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let restored = try ClipStore(path: backup.path)
        #expect(try texts(restored) == ["hello"])

        // reopen keeps data and schema version
        let reopened = try ClipStore(path: path)
        #expect(try texts(reopened) == ["hello"])
    }

    // MARK: search through the store

    @Test func searchScopes() throws {
        let s = try ClipStore.inMemory()
        let a = try s.addClip(formats: [textFormat("the body has needle inside")], description: "first", sourceApp: "")
        guard case .inserted(let aid) = a else { Issue.record("insert"); return }
        let bid = try add(s, "second apple")
        var b = try #require(try s.clip(id: bid)); b.quickPasteText = "qp-key"; try s.update(b)

        #expect(try s.clips(ClipFilter(search: SearchQuery("needle"))).isEmpty)
        var q = SearchQuery("needle"); q.searchFullText = true
        #expect(try s.clips(ClipFilter(search: q)).map(\.id) == [aid])
        #expect(try s.clips(ClipFilter(search: SearchQuery("/f needle"))).map(\.id) == [aid])
        #expect(try s.clips(ClipFilter(search: SearchQuery("/q qp-key"))).map(\.id) == [bid])
        #expect(try s.clips(ClipFilter(search: SearchQuery("NOT apple"))).map(\.id) == [aid])
        #expect(try s.clips(ClipFilter(search: SearchQuery("first OR apple"))).count == 2)
        #expect(try s.clips(ClipFilter(search: SearchQuery("sec*ple"))).map(\.id) == [bid])
        #expect(try s.clips(ClipFilter(search: SearchQuery("^sec.*e$", mode: .regex))).map(\.id) == [bid])
        #expect(try s.clips(ClipFilter(search: SearchQuery("([", mode: .regex))).isEmpty)   // invalid → false
        var cs = SearchQuery("SECOND"); cs.caseInsensitive = false
        #expect(try s.clips(ClipFilter(search: cs)).isEmpty)
        #expect(try s.count(ClipFilter(search: SearchQuery("APPLE"))) == 1)
        var ncs = SearchQuery("NOT needle"); ncs.searchFullText = true; ncs.searchDescription = false
        #expect(try s.clips(ClipFilter(search: ncs)).map(\.id) == [bid])
    }

    // MARK: Delete Clip Data window

    @Test func clipsMatchingAndDeleteData() throws {
        let s = try ClipStore.inMemory()
        let r = try s.addClip(formats: [textFormat("hello"), ClipFormat(type: ClipUTI.png, data: Data(count: 100))],
                              description: "pic 100%", sourceApp: "")
        guard case .inserted(let id) = r else { Issue.record("insert"); return }
        try add(s, "plain")
        let m = try s.clipsMatching(dataFilter: ClipDataFilter(formatType: ClipUTI.png))
        #expect(m.count == 1 && m[0].clip.id == id && m[0].bytes == 100)
        #expect(try s.clipsMatching(dataFilter: ClipDataFilter(titleContains: "100%")).count == 1)
        #expect(try s.clipsMatching(dataFilter: ClipDataFilter(titleContains: "_")).isEmpty)
        let before = try #require(try s.clip(id: id)).crc
        try s.deleteData(clipIDs: [id], types: [ClipUTI.png])
        #expect(try s.formatTypes(clipID: id).map(\.type) == [ClipUTI.plainText])
        #expect(try s.clip(id: id)?.crc != before)
        try s.deleteData(clipIDs: [id], types: [ClipUTI.plainText])
        #expect(try s.clip(id: id) == nil)
        // "plain" is unprotected → deleted, like upstream DeleteNonUsedClips.
        #expect(try s.deleteNonUsedClips() == 1)
        try s.deleteAll()
        #expect(try s.stats().clips == 0)
    }

    @Test func replaceFormatsRecomputesCRC() throws {
        let s = try ClipStore.inMemory()
        let id = try add(s, "one")
        try s.replaceFormats(clipID: id, formats: [textFormat("two")], description: "two")
        let c = try #require(try s.clip(id: id))
        #expect(c.text == "two")
        #expect(c.crc == CRC32.clipCRC([textFormat("two")]))
        let fid = try #require(try s.formats(clipID: id).first?.id)
        try s.deleteFormat(formatID: fid)
        #expect(try s.formats(clipID: id).isEmpty)
    }

    @Test func concurrentAccess() throws {
        let s = try ClipStore.inMemory()
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            _ = try? s.addClip(formats: [textFormat("c\(i)")], description: "c\(i)", sourceApp: "")
            _ = try? s.clips(ClipFilter())
        }
        #expect(try s.count(ClipFilter()) == 50)
    }
}

@Suite struct DeleteNonUsedTests {
    @Test func keepsProtectedClips() throws {
        let s = try ClipStore.inMemory()
        func add(_ t: String) throws -> Int64 {
            guard case .inserted(let id) = try s.addClip(formats: [ClipFormat(type: ClipUTI.plainText, data: Data(t.utf8))],
                                                         description: t, sourceApp: "") else { throw CancellationError() }
            return id
        }
        let plain = try add("plain")
        let keep = try add("keep"); var k = try #require(try s.clip(id: keep)); k.dontAutoDelete = true; try s.update(k)
        let sticky = try add("sticky"); try s.makeTopSticky(id: sticky, inGroup: false)
        let g = try s.createGroup(name: "G")
        let inGroup = try add("grouped"); try s.move(ids: [inGroup], toGroup: g)
        #expect(try s.deleteNonUsedClips() == 1)
        #expect(try s.clip(id: plain) == nil)
        for id in [keep, sticky, g, inGroup] { #expect(try s.clip(id: id) != nil) }
    }
}
