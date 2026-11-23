import Foundation
import Testing
@testable import DittoCore

@Suite struct HTMLToMarkdownTests {
    private func md(_ html: String) -> String { HTMLToMarkdown.convert(html) }

    // MARK: Headings and paragraphs

    @Test func headings() {
        for level in 1...6 {
            #expect(md("<h\(level)>Title  here</h\(level)>") == String(repeating: "#", count: level) + " Title here")
        }
        #expect(md("<h2>Intro</h2><p>Body text.</p><h3>Sub</h3><p>More.</p>") == "## Intro\n\nBody text.\n\n### Sub\n\nMore.")
        #expect(md("<h1>\n  Multi\n  line <em>title</em>\n</h1>") == "# Multi line *title*")
        #expect(md("<h2></h2><p>x</p>") == "x")
    }

    @Test func paragraphsDivsAndBreaks() {
        #expect(md("<p>one</p><p>two</p>") == "one\n\ntwo")
        #expect(md("<div>a</div><div>b</div>") == "a\n\nb")
        #expect(md("<p>line one<br>line two</p>") == "line one  \nline two")
        #expect(md("<p>trailing break<br></p>") == "trailing break")
        #expect(md("plain   text\n\n  with   spaces") == "plain text with spaces")
    }

    @Test func whitespaceCollapsesLikeABrowser() {
        #expect(md("<p>  a \n\t b  </p>") == "a b")
        #expect(md("<p>x <b> y </b> z</p>") == "x **y** z")
        #expect(md("<p>a&nbsp;b</p>") == "a b")
    }

    // MARK: Inline

    @Test func inlineStyles() {
        #expect(md("<p><strong>bold</strong> and <b>b</b></p>") == "**bold** and **b**")
        #expect(md("<p><em>em</em> <i>i</i></p>") == "*em* *i*")
        #expect(md("<p><b><b>nested</b></b></p>") == "**nested**")
        #expect(md("<p><del>gone</del></p>") == "~~gone~~")
        #expect(md("<p>use <code>let x = 1</code> here</p>") == "use `let x = 1` here")
        #expect(md("<p><code>a`b</code></p>") == "``a`b``")
        #expect(md("<p><b> </b>x</p>") == "x")
    }

    @Test func preformattedBlocks() {
        let out = md("<pre><code class=\"language-swift\">let a = 1\n    indented   kept\n</code></pre>")
        #expect(out == "```swift\nlet a = 1\n    indented   kept\n```")
        #expect(md("<pre>has ``` fence</pre>") == "````\nhas ``` fence\n````")
        #expect(md("<pre>a &lt;b&gt;</pre>") == "```\na <b>\n```")
    }

    @Test func escapesMarkdownInText() {
        #expect(md("<p>2 * 3 = 6 and snake_case [x]</p>") == "2 \\* 3 = 6 and snake\\_case \\[x\\]")
        #expect(md("<p># not a heading</p>") == "\\# not a heading")
        #expect(md("<p>1. not a list</p>") == "1\\. not a list")
        #expect(md("<p>- not a bullet</p>") == "\\- not a bullet")
        #expect(md("<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>") == "\\<script>alert(1)\\</script>")
    }

    // MARK: Links and images

    @Test func links() {
        #expect(md("<a href=\"https://example.com/a\">Example</a>") == "[Example](https://example.com/a)")
        #expect(md("<a href=\"http://x.org\">x</a> <a href=\"mailto:me@x.org\">mail</a>") == "[x](http://x.org) [mail](mailto:me@x.org)")
        #expect(md("<a href=\"https://e.com/p(1)\">p</a>") == "[p](https://e.com/p%281%29)")
        #expect(md("<p>see <a href=\"https://e.com\"> here </a>!</p>") == "see [here](https://e.com) !")
        #expect(md("<a href=\"https://e.com\"></a>") == "")
    }

    @Test func disallowedLinkSchemesKeepTextOnly() {
        for href in ["javascript:alert(1)", "JAVASCRIPT:alert(1)", "java\tscript:alert(1)", "file:///etc/passwd",
                     "data:text/html,<b>x</b>", "vbscript:x", "/relative/path", "#anchor", "x-apple.systempreferences:foo",
                     "smb://server/share", "https://", "  "] {
            let out = md("<a href=\"\(href)\">click</a>")
            #expect(out == "click", "href \(href) → \(out)")
        }
    }

    @Test func images() {
        #expect(md("<img src=\"https://e.com/a.png\" alt=\"Logo\">") == "![Logo](https://e.com/a.png)")
        #expect(md("<img src=\"http://e.com/a b.png\">") == "")       // whitespace in URL: refused
        #expect(md("<img src=\"data:image/png;base64,AAAA\" alt=\"inline\">") == "inline")
        #expect(md("<img src=\"file:///x.png\" alt=\"f\">") == "f")
        #expect(md("<img src=\"/rel.png\">") == "")
        #expect(md("<a href=\"https://e.com\"><img src=\"https://e.com/i.png\" alt=\"i\"></a>") == "[![i](https://e.com/i.png)](https://e.com)")
    }

    // MARK: Lists

    @Test func unorderedAndOrderedLists() {
        #expect(md("<ul><li>a</li><li>b</li></ul>") == "- a\n- b")
        #expect(md("<ol><li>one</li><li>two</li><li>three</li></ol>") == "1. one\n2. two\n3. three")
        #expect(md("<ol start=\"7\"><li>x</li><li>y</li></ol>") == "7. x\n8. y")
        #expect(md("<ul><li>unclosed<li>items</ul>") == "- unclosed\n- items")
        #expect(md("<p>before</p><ul><li>a</li></ul><p>after</p>") == "before\n\n- a\n\nafter")
    }

    @Test func nestedLists() {
        let html = "<ul><li>Fruit<ul><li>Apple</li><li>Pear<ol><li>Green</li><li>Red</li></ol></li></ul></li><li>Veg</li></ul>"
        let expected = """
        - Fruit
          - Apple
          - Pear
            1. Green
            2. Red
        - Veg
        """
        #expect(md(html) == expected)
        // A list directly inside a list (invalid but common) attaches to the previous item.
        #expect(md("<ol><li>a</li><ul><li>b</li></ul><li>c</li></ol>") == "1. a\n   - b\n2. c")
    }

    @Test func listItemWithParagraphsAndCode() {
        let out = md("<ol><li><p>Step</p><pre>run it</pre></li></ol>")
        #expect(out == "1. Step\n\n   ```\n   run it\n   ```")
    }

    // MARK: Blocks

    @Test func blockquotesAndRules() {
        #expect(md("<blockquote><p>quoted</p><p>two</p></blockquote>") == "> quoted\n>\n> two")
        #expect(md("<p>a</p><hr><p>b</p>") == "a\n\n---\n\nb")
        #expect(md("<blockquote>outer<blockquote>inner</blockquote></blockquote>") == "> outer\n>\n> > inner")
    }

    @Test func tables() {
        let html = """
        <table><thead><tr><th>Name</th><th>Qty</th></tr></thead>
        <tbody><tr><td>Apple</td><td>3</td></tr><tr><td>Pear | half</td><td><b>1</b></td></tr></tbody></table>
        """
        #expect(md(html) == "| Name | Qty |\n| --- | --- |\n| Apple | 3 |\n| Pear \\| half | **1** |")
        // Ragged rows are padded; no header row → first row is the header.
        #expect(md("<table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table>") == "| a | b |\n| --- | --- |\n| c | |")
        #expect(md("<table><tr><td>multi<br>line <p>para</p></td></tr></table>") == "| multi line para |\n| --- |")
        #expect(md("<table></table>") == "")
    }

    // MARK: Entities

    @Test func entities() {
        #expect(HTMLToMarkdown.decodeEntities("&amp; &lt; &gt; &quot; &#39; &#x27; &copy; &eacute; &hellip;") == "& < > \" ' ' © é …")
        #expect(HTMLToMarkdown.decodeEntities("&#128512; &#x1F600;") == "😀 😀")
        #expect(HTMLToMarkdown.decodeEntities("&#0; &#xD800; &#x110000; &#99999999999;") == "\u{FFFD} \u{FFFD} \u{FFFD} \u{FFFD}")
        #expect(HTMLToMarkdown.decodeEntities("&unknown; &amp &#; &") == "&unknown; & &#; &")
        #expect(HTMLToMarkdown.decodeEntities("&#150;") == "–")    // Windows-1252 mapping
        #expect(md("<p>Fish &amp; Chips &mdash; &pound;5</p>") == "Fish & Chips — £5")
    }

    // MARK: Stripping

    @Test func stripsScriptStyleHead() {
        let html = """
        <!DOCTYPE html><html><head><title>T</title><style>p{color:red}</style>
        <script>var x = "<p>not text</p>";</script></head>
        <body><!-- comment --><p>visible</p><script type="x">alert(1)</script><noscript>ns</noscript></body></html>
        """
        #expect(md(html) == "visible")
        #expect(md("<p>a</p><SCRIPT>bad()</SCRIPT ><p>b</p>") == "a\n\nb")
        #expect(md("<svg><text>svg text</text></svg><p>ok</p>") == "ok")
        #expect(md("<head><meta charset=utf-8>Body text without body tag") == "Body text without body tag")
    }

    @Test func realisticWebCopy() {
        let html = """
        <meta charset='utf-8'><h2 style="font-family: Georgia">Getting started</h2>
        <p style="margin: 0">Install with <code>brew install ditto</code>, then read
        <a href="https://example.com/docs" target="_blank">the docs</a>.</p>
        <h3>Features</h3><ul><li><strong>Fast</strong> search</li><li>Rich <em>formatting</em></li></ul>
        <img src="https://example.com/shot.png" alt="Screenshot">
        """
        let expected = """
        ## Getting started

        Install with `brew install ditto`, then read [the docs](https://example.com/docs).

        ### Features

        - **Fast** search
        - Rich *formatting*

        ![Screenshot](https://example.com/shot.png)
        """
        #expect(md(html) == expected)
    }

    // MARK: Plain text

    @Test func plainTextMode() {
        let html = "<h1>Title</h1><p>Para with <b>bold</b> &amp; <a href='https://x.y'>link</a>.</p><ul><li>a</li><li>b</li></ul>" +
            "<table><tr><td>c1</td><td>c2</td></tr></table><p>x<br>y</p>"
        #expect(HTMLToMarkdown.plainText(html) == "Title\n\nPara with bold & link.\n\n• a\n• b\n\nc1\tc2\n\nx\ny")
        #expect(HTMLToMarkdown.plainText("<p>2 * 3 _x_</p>") == "2 * 3 _x_")
        #expect(HTMLToMarkdown.plainText(data: Data("<p>caf\u{e9}</p>".utf8)) == "café")
    }

    @Test func decodesBytes() {
        #expect(HTMLToMarkdown.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8)) == "hi")
        #expect(HTMLToMarkdown.decode(Data([0x63, 0x61, 0x66, 0xE9])) == "café")          // not UTF-8 → CP1252
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("ok".data(using: .utf16LittleEndian)!)
        #expect(HTMLToMarkdown.decode(utf16) == "ok")
    }

    // MARK: Hostile input

    @Test func malformedMarkupNeverCrashes() {
        let cases = [
            "", "<", ">", "<<<>>>", "</", "</>", "<!--", "<!-- unterminated", "<!", "<?", "<a", "<a href=", "<a href=\"",
            "<p", "<p>unclosed <b>bold <i>both", "</p></div></b>stray closers", "<ul><li><ul><li>", "<table><td>x",
            "<tr><td>orphan cells</td></tr>", "<li>orphan</li>", "<pre>", "<code>", "&", "&#", "&#x", "&#xZZ;",
            "<a href='javascript:x'><a href='https://ok.com'>nested</a></a>", "<img>", "<img src>", "<br/><hr/>",
            "<script>never closed", "<style>", "<p attr=\"\u{E001}\u{E002}\">sentinels \u{E003}\u{E004}</p>",
            "<\u{0000}p>", "<p>\u{0000}nul</p>", String(repeating: "<", count: 1000),
        ]
        for c in cases {
            _ = HTMLToMarkdown.convert(c)
            _ = HTMLToMarkdown.plainText(c)
        }
        #expect(md("<p attr=\"\u{E001}\">a\u{E003}b</p>") == "ab")
        #expect(md("<p>bold <b>unclosed") == "bold **unclosed**")
    }

    @Test func deepNestingIsBounded() {
        let depth = 5000
        let html = String(repeating: "<div><b>", count: depth) + "deep" + String(repeating: "</b></div>", count: depth)
        #expect(md(html).contains("deep"))
        let lists = String(repeating: "<ul><li>x", count: 2000)
        #expect(!md(lists).isEmpty)
    }

    @Test func fuzzRandomMarkup() {
        var rng = SplitMix64(seed: 0xD1770)
        let alphabet: [String] = Array("<>/=\"' &;#xabcdefghijklmnopqrstuvwxyz0123456789\n\t-*_[]()`!?|").map(String.init) +
            ["<p>", "</p>", "<li>", "<ul>", "</ul>", "<ol>", "<table>", "<tr>", "<td>", "<pre>", "<a href=\"https://e.com\">",
             "</a>", "<b>", "</b>", "<h2>", "<br>", "<!--", "-->", "<script>", "</script>", "&amp;", "&#x1F600;", "é", "\u{E002}"]
        for _ in 0..<300 {
            let len = Int(rng.next() % 400)
            var s = ""
            for _ in 0..<len { s += alphabet[Int(rng.next() % UInt64(alphabet.count))] }
            let out = HTMLToMarkdown.convert(s)
            #expect(!out.unicodeScalars.contains(where: { (0xE000...0xE00F).contains($0.value) }), "input: \(s.debugDescription) → \(out.debugDescription)")
            _ = HTMLToMarkdown.plainText(s)
        }
    }

    @Test func oversizedInputIsTruncated() {
        let big = String(repeating: "<p>word</p>", count: (HTMLToMarkdown.maxInputBytes / 11) + 5000)
        let out = HTMLToMarkdown.plainText(big)
        #expect(out.hasPrefix("word"))
        #expect(out.utf8.count < HTMLToMarkdown.maxInputBytes)
    }

    // MARK: Web archives

    @Test func webArchiveMainHTML() throws {
        let archive: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data("<h2>Saved</h2><p>page</p>".utf8),
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8",
                "WebResourceURL": "https://example.com/",
            ] as [String: Any],
            "WebSubresources": [["WebResourceData": Data([1, 2, 3]), "WebResourceMIMEType": "image/png",
                                 "WebResourceURL": "https://example.com/a.png"] as [String: Any]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
        let html = try #require(WebArchive.mainHTML(data))
        #expect(HTMLToMarkdown.convert(html) == "## Saved\n\npage")
        #expect(WebArchive.subresourceCount(data) == 1)
        #expect(WebArchive.mainHTML(Data("not a plist".utf8)) == nil)
        #expect(WebArchive.mainHTML(Data()) == nil)
        let image: [String: Any] = ["WebMainResource": ["WebResourceData": Data([0]), "WebResourceMIMEType": "image/png"] as [String: Any]]
        #expect(WebArchive.mainHTML(try PropertyListSerialization.data(fromPropertyList: image, format: .binary, options: 0)) == nil)
    }
}

@Suite struct PasteFormatTests {
    @Test func titlesAndCodable() throws {
        #expect(PasteFormat.allCases.count == 5)
        #expect(PasteFormat.original.title == "Original (keep all formatting)")
        #expect(PasteFormat.richText.title == "Rich Text (no images)")
        let data = try JSONEncoder().encode([PasteFormat.markdown])
        #expect(try JSONDecoder().decode([PasteFormat].self, from: data) == [.markdown])
    }

    @Test func plainTextAppMatching() {
        #expect(!PasteFormat.appMatches("", bundleID: "com.apple.Terminal", appName: "Terminal"))
        #expect(!PasteFormat.appMatches(" ; ", bundleID: "com.apple.Terminal", appName: "Terminal"))
        #expect(PasteFormat.appMatches("com.apple.Terminal", bundleID: "com.apple.Terminal", appName: "Terminal"))
        #expect(PasteFormat.appMatches("com.microsoft.*;*Code*", bundleID: "com.microsoft.VSCode", appName: "Code"))
        #expect(PasteFormat.appMatches("*code*", bundleID: "x", appName: "Visual Studio Code"))
        #expect(!PasteFormat.appMatches("com.apple.Notes", bundleID: "com.apple.TextEdit", appName: "TextEdit"))
        #expect(!PasteFormat.appMatches("*", bundleID: "", appName: ""))
    }

    @Test func settingsDefaultsAndPerAppOverride() {
        let s = Settings(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        #expect(s.keepFullFormatting)
        #expect(s.defaultPasteFormat == .original)
        #expect(s.plainTextApps.isEmpty)
        s.defaultPasteFormat = .markdown
        #expect(s.defaultPasteFormat == .markdown)
        s.plainTextApps = "com.apple.Terminal;*iTerm*"
        #expect(s.defaultPasteFormat(bundleID: "com.apple.Terminal", appName: "Terminal") == .plainText)
        #expect(s.defaultPasteFormat(bundleID: "com.googlecode.iterm2", appName: "iTerm2") == .plainText)
        #expect(s.defaultPasteFormat(bundleID: "com.apple.Notes", appName: "Notes") == .markdown)
        s.defaults.set("bogus", forKey: "defaultPasteFormat")
        #expect(s.defaultPasteFormat == .original)
        s.keepFullFormatting = false
        s.resetToDefaults()
        #expect(s.keepFullFormatting && s.plainTextApps.isEmpty)
    }

    @Test func formatSummaryAndNames() {
        let rich = ClipFormatSummary(types: [ClipUTI.plainText, ClipUTI.webArchive, ClipUTI.jpeg])
        #expect(rich.hasText && rich.hasRichText && rich.hasImage && rich.hasWebArchive && !rich.hasRTFD)
        let plain = ClipFormatSummary(types: [ClipUTI.plainText])
        #expect(plain.hasText && !plain.hasRichText && !plain.hasImage)
        #expect(ClipUTI.displayNames([ClipUTI.flatRTFD, ClipUTI.rtfd, ClipUTI.html, "x.custom"]) ==
                ["Rich Text with Attachments (RTFD)", "HTML", "x.custom"])
        #expect(ClipKind.classify(types: [ClipUTI.plainText, ClipUTI.flatRTFD]) == .richText)
        #expect(ClipKind.classify(types: [ClipUTI.plainText, ClipUTI.webArchive]) == .html)
        #expect(ClipKind.classify(types: [ClipUTI.gif]) == .image)
    }
}

/// Deterministic RNG so fuzz failures are reproducible.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
