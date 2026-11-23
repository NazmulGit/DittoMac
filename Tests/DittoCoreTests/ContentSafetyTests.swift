import Foundation
import Testing
@testable import DittoCore

/// Regression tests for docs/kb/security-review-port.md (P1 HTML sanitiser, P2 link schemes, P5 import, P6 images).
@Suite struct ContentSafetyTests {

    // MARK: HTML sanitiser

    /// Anything that could make the WebKit importer fetch a resource or run script.
    private func assertInert(_ out: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let l = out.lowercased()
        for bad in ["http", "//evil", "<script", "<img", "<svg", "<image", "<iframe", "<frame", "<object", "<embed",
                    "<link", "<meta http-equiv", "<base", "<style", "url(", "onerror", "onload", "javascript:",
                    "xlink", "srcset", "src=", "background=", "file:", "@import", "<video", "<input", "<form"] {
            #expect(!l.contains(bad), "sanitised output contains \(bad): \(out)", sourceLocation: sourceLocation)
        }
    }

    @Test func blocksBypassesOfTheOldRegexBlacklist() {
        let vectors = [
            #"<img/src="https://evil.example/a.png">"#,                         // slash instead of whitespace
            #"<img src="&#104;ttps://evil.example/a.png">"#,                     // entity-encoded scheme
            #"<svg><image xlink:href="https://evil.example/b.png"/></svg>"#,     // namespaced href
            #"<p style="background:url(\68ttps://evil.example/c)">x</p>"#,       // CSS escape
            #"<frameset><frame src="https://evil.example/d"></frameset>"#,
            #"<style>@import 'https://evil.example/e.css'; p{color:red}</style><p>t</p>"#,
            #"<table background="https://evil.example/f.png"><tr><td>x</td></tr></table>"#,
            #"<video poster="https://evil.example/g.png"></video>"#,
            #"<input type="image" src="https://evil.example/h.png">"#,
            #"<a href="javascript:alert(1)" onclick="x()">j</a>"#,
            #"<script>fetch('https://evil.example/i')</script><p onmouseover="x()">p</p>"#,
            #"<meta http-equiv="refresh" content="0;url=https://evil.example/j"><base href="https://evil.example/">"#,
            #"<link rel="stylesheet" href="https://evil.example/k.css">"#,
            #"<object data="https://evil.example/l.swf"></object><embed src="https://evil.example/m">"#,
            #"<img srcset="https://evil.example/n.png 2x">"#,
            #"<a href="file:///Applications/Calculator.app">f</a>"#,
            #"<div style="width:10px;behavior:url(x.htc)">b</div>"#,
            #"<IMG SRC=//evil.example/o.png>"#,
        ]
        for v in vectors { assertInert(HTMLSanitizer.sanitize(v)) }
    }

    @Test func keepsHarmlessFormattingAndSafeLinks() {
        let out = HTMLSanitizer.sanitize(#"<p align="center">Hi <b>bold</b> &amp; <i style="color:red">it</i><br><a href="https://ok.example/x?a=1&b=2">ok</a></p><ul><li>one</li></ul>"#)
        #expect(out.contains("<b>bold</b>"))
        #expect(out.contains("&amp;"))
        #expect(out.contains(#"style="color:red""#))
        #expect(out.contains("<br>"))
        #expect(out.contains(#"<a href="https://ok.example/x?a=1&amp;b=2">ok</a>"#))
        #expect(out.contains("<li>one</li>"))
        #expect(out.contains(#"align="center""#))
        #expect(HTMLSanitizer.sanitize("<p>café ✓ 日本 😀</p>").contains("café ✓ 日本 😀"))
    }

    @Test func textAndAttributesAreEscaped() {
        let out = HTMLSanitizer.sanitize(#"<p title="a&quot;onmouseover=&quot;x">1 &lt;script&gt;</p>"#)
        #expect(out.contains("&lt;script&gt;"))
        #expect(out.contains(#"title="a&quot;onmouseover=&quot;x""#))
        #expect(!out.lowercased().contains("<script"))
    }

    @Test func unknownElementsAreUnwrappedAndDeepNestingIsBounded() {
        #expect(HTMLSanitizer.sanitize("<custom-tag>inner</custom-tag>").contains("inner"))
        let deep = String(repeating: "<div>", count: 2000) + "deep" + String(repeating: "</div>", count: 2000)
        let out = HTMLSanitizer.sanitize(deep)
        #expect(out.contains("deep"))
    }

    @Test func oversizedInputBecomesEscapedText() {
        let big = "<img src=https://evil.example/x>" + String(repeating: "a", count: HTMLSanitizer.maxInputBytes)
        let out = HTMLSanitizer.sanitize(big)
        assertInert(out)
        #expect(out.utf8.count < HTMLSanitizer.maxInputBytes + 200)
    }

    // MARK: links

    @Test func linkPolicy() {
        for ok in ["https://example.com/a", "http://example.com", "mailto:a@example.com", " https://example.com "] {
            #expect(LinkPolicy.isSafeToOpen(ok), "\(ok)")
        }
        for bad in ["file:///Applications/Calculator.app", "javascript:alert(1)", "smb://host/share", "x-apple.systempreferences:x",
                    "ssh://host", "vnc://host", "https://", "https:///path", "java\tscript:alert(1)", "data:text/html,x",
                    "/etc/passwd", "", "itms-services://?action=download-manifest"] {
            #expect(!LinkPolicy.isSafeToOpen(bad), "\(bad)")
        }
    }

    // MARK: images

    /// 1-bit greyscale PNG of the given size whose rows are all zero: a few KB on disk, w*h pixels decoded.
    private func zeroPNG(width: UInt32, height: UInt32) throws -> Data {
        func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let tb = Array(type.utf8) + body
            return be(UInt32(body.count)) + tb + be(CRC32.checksum(Data(tb)))
        }
        let raw = Data(count: Int(height) * (1 + (Int(width) + 7) / 8))
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data      // raw DEFLATE
        let ihdr = be(width) + be(height) + [1, 0, 0, 0, 0]
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", ihdr)
                    + chunk("IDAT", [0x78, 0x9C] + [UInt8](deflated)) + chunk("IEND", []))
    }

    @Test func imageProbeRefusesDecompressionBombs() throws {
        let bomb = try zeroPNG(width: 12_000, height: 12_000)      // 144 MP from ~18 KB
        #expect(bomb.count < 100_000)
        #expect(ImageProbe.pixelSize(bomb)?.width == 12_000)
        #expect(!ImageProbe.isSafeToDecode(bomb))
        #expect(ImageProbe.isSafeToDecode(try zeroPNG(width: 640, height: 480)))
        #expect(ImageProbe.pixelSize(Data("not an image".utf8)) == nil)
        #expect(!ImageProbe.isSafeToDecode(Data()))
        #expect(ImageProbe.thumbnail(bomb, maxPixelSize: 256).map { max($0.width, $0.height) <= 256 } ?? true)
    }

    // MARK: imports

    @Test func importRejectsViewsInsteadOfTables() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("evil.db").path
        do {
            let db = try SQLiteDatabase(path: path)
            // An endless recursive CTE behind a view named like the expected table.
            try db.exec("""
            CREATE TABLE Data(lID INTEGER PRIMARY KEY, lParentID INTEGER, strClipBoardFormat TEXT, ooData BLOB);
            CREATE VIEW Main AS WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r)
              SELECT n AS lID, 0 AS lDate, '' AS mText, 0 AS bIsGroup, -1 AS lParentID FROM r;
            """)
        }
        let store = try ClipStore.inMemory()
        #expect(throws: SQLiteError.self) { try ImportExport.importWindowsDitto(from: URL(fileURLWithPath: path), into: store) }
        #expect(throws: SQLiteError.self) { try ImportExport.importClips(from: URL(fileURLWithPath: path), into: store) }
    }

    @Test func importSkipsOversizedFormatsAndTruncatesText() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("Ditto.db").path
        do {
            let db = try SQLiteDatabase(path: path)
            try db.exec("""
            CREATE TABLE Main(lID INTEGER PRIMARY KEY, lDate INTEGER, mText TEXT, bIsGroup INTEGER, lParentID INTEGER);
            CREATE TABLE Data(lID INTEGER PRIMARY KEY, lParentID INTEGER, strClipBoardFormat TEXT, ooData BLOB);
            """)
            try db.run("INSERT INTO Main VALUES(1, 1, ?, 0, -1)", [.text(String(repeating: "x", count: 200_000))])
            try db.run("INSERT INTO Data(lParentID, strClipBoardFormat, ooData) VALUES(1, 'PNG', ?)", [.blob(Data(count: 5000))])
            try db.run("INSERT INTO Data(lParentID, strClipBoardFormat, ooData) VALUES(1, 'CF_TEXT', ?)", [.blob(Data("small".utf8))])
        }
        let store = try ClipStore.inMemory()
        let s = try ImportExport.importWindowsDitto(from: URL(fileURLWithPath: path), into: store, maxFormatBytes: 1000)
        #expect(s.clipsImported == 1)
        let clip = try #require(try store.clips(ClipFilter(limit: 0)).first)
        #expect(try store.formatTypes(clipID: clip.id).map(\.type) == [ClipUTI.plainText])   // 5000-byte PNG skipped
        #expect(clip.text.count == ImportExport.maxImportTextChars)
    }
}
