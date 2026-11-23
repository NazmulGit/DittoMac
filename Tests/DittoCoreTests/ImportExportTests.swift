import Foundation
import Testing
@testable import DittoCore

@Suite struct ImportExportTests {

    func utf16le(_ s: String, nul: Bool = true) -> Data {
        var d = Data()
        for u in s.utf16 { d.append(UInt8(u & 0xFF)); d.append(UInt8(u >> 8)) }
        if nul { d.append(contentsOf: [0, 0]) }
        return d
    }

    func cfHTML(_ fragment: String) -> Data {
        let pre = "<html><body><!--StartFragment-->"
        let post = "<!--EndFragment--></body></html>"
        let template = "Version:0.9\r\nStartHTML:%010d\r\nEndHTML:%010d\r\nStartFragment:%010d\r\nEndFragment:%010d\r\n"
        let headerLen = String(format: template, 0, 0, 0, 0).utf8.count
        let startHTML = headerLen
        let startFrag = startHTML + pre.utf8.count
        let endFrag = startFrag + fragment.utf8.count
        let endHTML = endFrag + post.utf8.count
        let header = String(format: template, startHTML, endHTML, startFrag, endFrag)
        return Data((header + pre + fragment + post).utf8) + Data([0])
    }

    /// Builds a minimal Windows-Ditto-like database (no clipOrder / lastPasteDate columns).
    func makeWindowsDB(at path: String) throws {
        let db = try SQLiteDatabase(path: path)
        try db.exec("""
        CREATE TABLE Main(lID INTEGER PRIMARY KEY AUTOINCREMENT, lDate INTEGER, mText TEXT, lShortCut INTEGER,
          lDontAutoDelete INTEGER, CRC INTEGER, bIsGroup INTEGER, lParentID INTEGER, QuickPasteText TEXT);
        CREATE TABLE Data(lID INTEGER PRIMARY KEY AUTOINCREMENT, lParentID INTEGER, strClipBoardFormat TEXT, ooData BLOB);
        """)
        func main(_ id: Int64, _ text: String, group: Bool = false, parent: Int64 = -1, dontDelete: Bool = false, qp: String = "") throws {
            try db.run("INSERT INTO Main(lID, lDate, mText, lShortCut, lDontAutoDelete, CRC, bIsGroup, lParentID, QuickPasteText) VALUES(?,?,?,0,?,0,?,?,?)",
                       [.int(id), .int(1_600_000_000 + id), .text(text), .int(dontDelete ? 1 : 0), .int(group ? 1 : 0), .int(parent), .text(qp)])
        }
        func data(_ parent: Int64, _ fmt: String, _ d: Data) throws {
            try db.run("INSERT INTO Data(lParentID, strClipBoardFormat, ooData) VALUES(?,?,?)", [.int(parent), .text(fmt), .blob(d)])
        }
        try main(10, "Work", group: true)
        try main(11, "Sub", group: true, parent: 10)
        try main(1, "Héllo", dontDelete: true, qp: "hi")
        try data(1, "CF_UNICODETEXT", utf16le("Héllo ✓"))
        try data(1, "CF_TEXT", Data("Hello?".utf8) + Data([0]))
        try main(2, "café", parent: 10)
        try data(2, "CF_TEXT", Data([0x63, 0x61, 0x66, 0xE9, 0x80, 0]))
        try data(2, "HTML Format", cfHTML("<b>café</b>"))
        try data(2, "Rich Text Format", Data("{\\rtf1 x}".utf8) + Data([0]))
        try main(3, "bitmap only")
        try data(3, "CF_DIB", Data(count: 40))
        try main(4, "", parent: 11)
        try data(4, "PNG", Data([0x89, 0x50, 0x4E, 0x47]))
        try main(5, "orphan parent", parent: 999)
        try data(5, "CF_UNICODETEXT", utf16le("orphan", nul: false))
    }

    @Test func importsWindowsDittoDatabase() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("Ditto.db")
        try makeWindowsDB(at: src.path)

        let store = try ClipStore.inMemory()
        let existing = try store.createGroup(name: "Work")   // reused by name
        let summary = try ImportExport.importWindowsDitto(from: src, into: store)
        #expect(summary.clipsImported == 4)
        #expect(summary.skipped == 1)
        #expect(summary.groupsCreated == 1)   // "Sub" only

        let all = try store.clips(ClipFilter(limit: 0))
        let byText = Dictionary(uniqueKeysWithValues: all.map { ($0.text, $0) })

        let hello = try #require(byText["Héllo"])
        #expect(try store.data(clipID: hello.id, type: ClipUTI.plainText) == Data("Héllo ✓".utf8))
        #expect(hello.dontAutoDelete)
        #expect(hello.quickPasteText == "hi")
        #expect(hello.date == Date(timeIntervalSince1970: 1_600_000_001))
        #expect(hello.parentID == -1)

        let cafe = try #require(byText["café"])
        #expect(cafe.parentID == existing)
        #expect(try store.data(clipID: cafe.id, type: ClipUTI.plainText) == Data("café€".utf8))
        #expect(try store.data(clipID: cafe.id, type: ClipUTI.html) == Data("<b>café</b>".utf8))
        #expect(try store.data(clipID: cafe.id, type: ClipUTI.rtf) == Data("{\\rtf1 x}".utf8))

        let sub = try #require(try store.groups().first { $0.text == "Sub" })
        #expect(sub.parentID == existing)
        let png = try #require(try store.children(ofGroup: sub.id).first)
        #expect(try store.formatTypes(clipID: png.id).map(\.type) == [ClipUTI.png])
        #expect(png.text == ClipUTI.png)

        let orphan = try #require(byText["orphan parent"])
        #expect(orphan.parentID == -1)
        #expect(try store.data(clipID: orphan.id, type: ClipUTI.plainText) == Data("orphan".utf8))

        // importing again: top-level duplicates are bumped, not inserted
        let again = try ImportExport.importWindowsDitto(from: src, into: store)
        #expect(again.duplicates == 2)
        #expect(again.groupsCreated == 0)
    }

    @Test func cfHTMLParsing() {
        #expect(ImportExport.cfHTMLFragment(cfHTML("<i>x</i>")) == Data("<i>x</i>".utf8))
        // out-of-range offsets fall back to the whole payload
        let bad = Data("Version:0.9\r\nStartFragment:0000099999\r\nEndFragment:0000100000\r\n<p>x</p>".utf8)
        #expect(ImportExport.cfHTMLFragment(bad) == bad)
        let reversed = Data("Version:0.9\r\nStartFragment:0000000050\r\nEndFragment:0000000010\r\n<p>x</p>".utf8)
        #expect(ImportExport.cfHTMLFragment(reversed) == reversed)
        #expect(ImportExport.cfHTMLFragment(Data("<p>plain</p>".utf8) + Data([0, 0])) == Data("<p>plain</p>".utf8))
        #expect(ImportExport.cfHTMLFragment(Data()) == Data())
    }

    @Test func formatConversionPrefersUnicode() {
        let out = ImportExport.convertWindowsFormats([
            ClipFormat(type: "CF_TEXT", data: Data("ansi".utf8)),
            ClipFormat(type: "CF_UNICODETEXT", data: utf16le("uni")),
            ClipFormat(type: "CF_LOCALE", data: Data([9, 4])),
        ])
        #expect(out == [ClipFormat(type: ClipUTI.plainText, data: Data("uni".utf8))])
        #expect(ImportExport.convertWindowsFormats([ClipFormat(type: "CF_HDROP", data: Data([1]))]).isEmpty)
        #expect(ImportExport.decodeUTF16LE(Data([0x41, 0x00, 0x42])) == "A")   // odd length tolerated
    }

    @Test func exportImportRoundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try ClipStore(path: dir.appendingPathComponent("src.db").path)
        let g = try source.createGroup(name: "Snippets")
        let inGroup = try add(source, "signature", parent: g)
        let png = ClipFormat(type: ClipUTI.png, data: Data([1, 2, 3]))
        let r = try source.addClip(formats: [textFormat("with image"), png], description: "with image", sourceApp: "app")
        guard case .inserted(let withImage) = r else { Issue.record("insert"); return }
        let evil = try add(source, "'; DROP TABLE Data; --")
        try add(source, "not exported")
        var c = try #require(try source.clip(id: withImage)); c.quickPasteText = "img"; try source.update(c)

        let file = dir.appendingPathComponent("out." + ImportExport.fileExtension)
        let n = try ImportExport.exportClips(ids: [g, withImage, evil], from: source, to: file)
        #expect(n == 3)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)

        let dest = try ClipStore.inMemory()
        let summary = try ImportExport.importClips(from: file, into: dest)
        #expect(summary.clipsImported == 3)
        #expect(summary.groupsCreated == 1)
        let group = try #require(try dest.groups().first)
        #expect(group.text == "Snippets")
        let kids = try dest.children(ofGroup: group.id)
        #expect(kids.map(\.text) == ["signature"])
        let all = try dest.clips(ClipFilter(limit: 0))
        #expect(Set(all.map(\.text)) == ["signature", "with image", "'; DROP TABLE Data; --"])
        let img = try #require(all.first { $0.text == "with image" })
        #expect(try dest.formats(clipID: img.id).map(\.type) == [ClipUTI.plainText, ClipUTI.png])
        #expect(try dest.data(clipID: img.id, type: ClipUTI.png) == Data([1, 2, 3]))
        #expect(img.quickPasteText == "img")
        _ = inGroup
    }

    @Test func textFileNames() {
        func name(_ t: String, _ i: Int = 1) -> String { ImportExport.textFileName(for: Clip(text: t), index: i) }
        #expect(name("hello world") == "1 hello world.txt")
        #expect(!name("a/b:c\\d").contains("/") && !name("a/b:c\\d").contains(":"))
        #expect(name("...hidden") == "1 hidden.txt")
        #expect(name("") == "1 Clip.txt")
        #expect(name("first line\nsecond") == "1 first line.txt")
        let long = name(String(repeating: "x", count: 200), 12345)
        #expect(long.count <= 60 && long.hasSuffix(".txt") && long.hasPrefix("12345 "))
        #expect(!name("../../etc/passwd").hasPrefix("."))
        #expect(!name("tab\there\u{0}nul").contains("\u{0}"))
    }
}
