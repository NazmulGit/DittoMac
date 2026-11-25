// Export / import of clips:
//  - `.dittoclips` = a standalone SQLite file with the ClipStore Main/Data schema;
//  - import of a Windows Ditto `Ditto.db` (opened read-only, fixed SELECTs only);
//  - helpers for text export file names.

import Foundation

public struct ImportSummary: Sendable, Equatable {
    public var clipsImported = 0
    public var groupsCreated = 0
    public var duplicates = 0       // already present at top level (bumped instead of inserted)
    public var skipped = 0          // no importable formats
    public init() {}
}

public enum ImportExport {
    public static let fileExtension = "dittoclips"
    /// Formats larger than this in an imported file are skipped (bounded memory per clip).
    public static let maxImportFormatBytes = 64 * 1024 * 1024
    /// Text columns (description, quick-paste text, format name) are truncated to this many characters.
    static let maxImportTextChars = 100_000

    // MARK: - export

    /// Writes the given clips (selected groups include their descendants; ancestor groups of exported
    /// clips are exported too so grouping survives) to a fresh `.dittoclips` SQLite file at `url`,
    /// replacing any existing file. Returns the number of non-group clips written.
    /// Locked clips (vault) are never exported, even when selected or inside a selected group.
    @discardableResult
    public static func exportClips(ids: [Int64], from store: ClipStore, to url: URL) throws -> Int {
        var items: [Int64: Clip] = [:]
        var queue = ids
        while let id = queue.popLast() {
            guard items[id] == nil, let c = try store.clip(id: id), !c.isLocked else { continue }
            items[id] = c
            if c.isGroup { queue += try store.children(ofGroup: id).map(\.id) }
        }
        // ancestors
        for c in Array(items.values) {
            var p = c.parentID
            var guardCount = 0
            while p != Ditto.topLevelParent, items[p] == nil, guardCount < 1000, let g = try store.clip(id: p) {
                items[p] = g
                p = g.parentID
                guardCount += 1
            }
        }

        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: url.path + suffix) {
            try fm.removeItem(atPath: url.path + suffix)
        }
        var written = 0
        do {
            let out = try ClipStore(path: url.path)
            var map: [Int64: Int64] = [:]
            // groups parents-first
            var pending = items.values.filter(\.isGroup).sorted { $0.id < $1.id }
            while !pending.isEmpty {
                var next: [Clip] = []
                for g in pending {
                    let parentReady = g.parentID == Ditto.topLevelParent || items[g.parentID] == nil || map[g.parentID] != nil
                    guard parentReady else { next.append(g); continue }
                    var copy = g
                    copy.parentID = map[g.parentID] ?? Ditto.topLevelParent
                    map[g.id] = try out.insertRaw(copy, formats: [])
                }
                if next.count == pending.count {   // cycle: flatten the rest to top level
                    for g in next {
                        var copy = g
                        copy.parentID = Ditto.topLevelParent
                        map[g.id] = try out.insertRaw(copy, formats: [])
                    }
                    next.removeAll()
                }
                pending = next
            }
            for c in items.values.filter({ !$0.isGroup }).sorted(by: { $0.clipOrder < $1.clipOrder }) {
                var copy = c
                copy.parentID = map[c.parentID] ?? Ditto.topLevelParent
                copy.shortcut = 0
                copy.globalShortcut = false
                _ = try out.insertRaw(copy, formats: try store.formats(clipID: c.id))
                written += 1
            }
        }
        for suffix in ["", "-wal", "-shm"] { chmod(url.path + suffix, 0o600) }
        return written
    }

    // MARK: - import

    /// Imports a `.dittoclips` file produced by `exportClips`.
    public static func importClips(from url: URL, into store: ClipStore) throws -> ImportSummary {
        let src = try openUntrusted(url)
        return try ingest(src, into: store, maxFormatBytes: maxImportFormatBytes) { formats in formats }
    }

    /// Imports a Windows Ditto database (`Ditto.db`). Text, RTF, HTML and PNG formats are converted;
    /// everything else is skipped. Groups are recreated (reused when one with the same name exists).
    public static func importWindowsDitto(from url: URL, into store: ClipStore) throws -> ImportSummary {
        try importWindowsDitto(from: url, into: store, maxFormatBytes: maxImportFormatBytes)
    }

    static func importWindowsDitto(from url: URL, into store: ClipStore, maxFormatBytes: Int) throws -> ImportSummary {
        let src = try openUntrusted(url)
        return try ingest(src, into: store, maxFormatBytes: maxFormatBytes, convert: convertWindowsFormats)
    }

    /// Imported files are attacker-controlled: open read-only and hardened, and only read real tables
    /// (a `Main`/`Data` VIEW could run an endless recursive query or hide expensive expressions).
    static func openUntrusted(_ url: URL) throws -> SQLiteDatabase {
        let src = try SQLiteDatabase(path: url.path, readOnly: true)
        try src.hardenForUntrustedInput()
        for t in ["Main", "Data"] {
            if let type = try src.schemaType(of: t), type.lowercased() != "table" {
                throw SQLiteError(code: 1, message: "source \(t) is not a table")
            }
        }
        return src
    }

    struct SourceRow {
        var id: Int64
        var date: Int64
        var text: String
        var isGroup: Bool
        var parentID: Int64
        var dontAutoDelete: Bool
        var quickPasteText: String
        var clipOrder: Double
        var lastPasteDate: Int64
        var isLocked = false
    }

    /// Fixed whitelist of Main columns read from a source database, with the literal used when absent.
    private static let sourceColumns: [(name: String, fallback: String)] = [
        ("lID", "0"), ("lDate", "0"), ("mText", "''"), ("bIsGroup", "0"), ("lParentID", "-1"),
        ("lDontAutoDelete", "0"), ("QuickPasteText", "''"), ("clipOrder", "0"), ("lastPasteDate", "0"),
        ("isLocked", "0"),
    ]

    private static func tableColumns(_ db: SQLiteDatabase, mainTable: Bool) throws -> Set<String> {
        let st = try db.prepare(mainTable ? "PRAGMA table_info(Main)" : "PRAGMA table_info(Data)")
        var cols = Set<String>()
        while try st.step() { cols.insert(st.string(1)) }
        return cols
    }

    static func readSourceRows(_ db: SQLiteDatabase) throws -> [SourceRow] {
        let cols = try tableColumns(db, mainTable: true)
        guard cols.contains("lID") else { throw SQLiteError(code: 1, message: "source has no Main table") }
        // Identifiers come only from the constant whitelist above.
        // Text columns are truncated in SQL so one oversized value cannot dominate memory.
        let select = sourceColumns.map { c -> String in
            guard cols.contains(c.name) else { return c.fallback }
            return (c.name == "mText" || c.name == "QuickPasteText") ? "substr(\(c.name), 1, \(maxImportTextChars))" : c.name
        }.joined(separator: ", ")
        let st = try db.prepare("SELECT " + select + " FROM Main ORDER BY " + (cols.contains("clipOrder") ? "clipOrder" : "lID") + " ASC, lID ASC")
        var rows: [SourceRow] = []
        while try st.step() {
            rows.append(SourceRow(id: st.int64(0), date: st.int64(1), text: st.string(2), isGroup: st.int64(3) != 0,
                                  parentID: st.int64(4), dontAutoDelete: st.int64(5) != 0, quickPasteText: st.string(6),
                                  clipOrder: st.double(7), lastPasteDate: st.int64(8), isLocked: st.int64(9) != 0))
        }
        return rows
    }

    private static func ingest(_ src: SQLiteDatabase, into store: ClipStore, maxFormatBytes: Int,
                               convert: ([ClipFormat]) -> [ClipFormat]) throws -> ImportSummary {
        var summary = ImportSummary()
        let rows = try readSourceRows(src)
        let dataCols = try tableColumns(src, mainTable: false)
        let hasData = dataCols.contains("lParentID") && dataCols.contains("strClipBoardFormat") && dataCols.contains("ooData")
        // Encrypted (vault) blobs of a DittoMac v2 database are never imported: they are unreadable here.
        let dataSQL = dataCols.contains("encrypted")
            ? "SELECT substr(strClipBoardFormat, 1, 256), ooData FROM Data WHERE lParentID = ? AND length(ooData) <= ? AND encrypted = 0 ORDER BY lID"
            : "SELECT substr(strClipBoardFormat, 1, 256), ooData FROM Data WHERE lParentID = ? AND length(ooData) <= ? ORDER BY lID"
        let dataStmt = hasData ? try src.prepare(dataSQL) : nil

        // Groups, parents first; reuse existing groups with the same name under the same parent.
        let groupRows = rows.filter(\.isGroup)
        let groupIDs = Set(groupRows.map(\.id))
        var map: [Int64: Int64] = [:]
        var pending = groupRows
        func place(_ g: SourceRow, parent: Int64) throws {
            if let existing = try store.findGroup(named: g.text, parentID: parent) {
                map[g.id] = existing
            } else {
                map[g.id] = try store.createGroup(name: g.text, parentID: parent)
                summary.groupsCreated += 1
            }
        }
        while !pending.isEmpty {
            var next: [SourceRow] = []
            for g in pending {
                if !groupIDs.contains(g.parentID) || g.parentID == g.id {
                    try place(g, parent: Ditto.topLevelParent)
                } else if let p = map[g.parentID] {
                    try place(g, parent: p)
                } else {
                    next.append(g)
                }
            }
            if next.count == pending.count {   // cycle in source data: flatten
                for g in next { try place(g, parent: Ditto.topLevelParent) }
                next.removeAll()
            }
            pending = next
        }

        for row in rows where !row.isGroup {
            if row.isLocked { summary.skipped += 1; continue }
            var formats: [ClipFormat] = []
            if let dataStmt {
                dataStmt.reset()
                try dataStmt.bind(1, row.id)
                try dataStmt.bind(2, maxFormatBytes)
                while try dataStmt.step() { formats.append(ClipFormat(type: dataStmt.string(0), data: dataStmt.data(1))) }
            }
            formats = convert(formats)
            guard !formats.isEmpty else { summary.skipped += 1; continue }
            let parent = map[row.parentID] ?? Ditto.topLevelParent
            var description = row.text
            if description.isEmpty {
                if let t = formats.first(where: { $0.type == ClipUTI.plainText }) {
                    description = String(String(decoding: t.data, as: UTF8.self).prefix(500))
                } else {
                    description = formats[0].type
                }
            }
            switch try store.addClip(formats: formats, description: description, sourceApp: "", parentID: parent) {
            case .inserted(let id):
                summary.clipsImported += 1
                if var c = try store.clip(id: id) {
                    if row.date > 0 { c.date = Date(timeIntervalSince1970: TimeInterval(row.date)) }
                    c.lastPasteDate = Date(timeIntervalSince1970: TimeInterval(max(row.date, row.lastPasteDate)))
                    if row.date <= 0 && row.lastPasteDate <= 0 { c.lastPasteDate = c.date }
                    c.dontAutoDelete = row.dontAutoDelete
                    c.quickPasteText = row.quickPasteText
                    try store.update(c)
                }
            case .duplicateBumped:
                summary.duplicates += 1
            case .rejected:
                summary.skipped += 1
            }
        }
        return summary
    }

    // MARK: - Windows format conversion

    /// Maps Windows clipboard formats to macOS UTIs. CF_TEXT is used only when CF_UNICODETEXT is absent.
    public static func convertWindowsFormats(_ formats: [ClipFormat]) -> [ClipFormat] {
        var text: String?
        var ansi: String?
        var rtf: Data?
        var html: Data?
        var png: Data?
        for f in formats {
            switch f.type {
            case "CF_UNICODETEXT": if text == nil { text = decodeUTF16LE(f.data) }
            case "CF_TEXT": if ansi == nil { ansi = decodeWindows1252(f.data) }
            case "Rich Text Format": if rtf == nil { rtf = stripTrailingNULs(f.data) }
            case "HTML Format": if html == nil { html = cfHTMLFragment(f.data) }
            case "PNG": if png == nil { png = f.data }
            default: continue
            }
        }
        var out: [ClipFormat] = []
        if let t = text ?? ansi { out.append(ClipFormat(type: ClipUTI.plainText, data: Data(t.utf8))) }
        if let rtf, !rtf.isEmpty { out.append(ClipFormat(type: ClipUTI.rtf, data: rtf)) }
        if let html, !html.isEmpty { out.append(ClipFormat(type: ClipUTI.html, data: html)) }
        if let png, !png.isEmpty { out.append(ClipFormat(type: ClipUTI.png, data: png)) }
        return out
    }

    /// UTF-16LE → String, cut at the first NUL.
    static func decodeUTF16LE(_ data: Data) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var i = 0
            while i + 1 < raw.count {
                let u = UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8)
                if u == 0 { break }
                units.append(u)
                i += 2
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Windows-1252 → String, cut at the first NUL.
    static func decodeWindows1252(_ data: Data) -> String {
        let bytes = data.prefix { $0 != 0 }
        return String(data: Data(bytes), encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    static func stripTrailingNULs(_ data: Data) -> Data {
        var d = data
        while d.last == 0 { d.removeLast() }
        return d
    }

    /// Extracts the fragment from CF_HTML ("Version:…StartFragment:…EndFragment:…" header with byte offsets).
    /// Offsets are bounds-checked; falls back to StartHTML/EndHTML, then to the whole payload.
    public static func cfHTMLFragment(_ data: Data) -> Data {
        let d = stripTrailingNULs(data)
        let header = String(decoding: d.prefix(4096), as: UTF8.self)
        func offset(_ key: String) -> Int? {
            guard let r = header.range(of: key + ":") else { return nil }
            let digits = header[r.upperBound...].prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, digits.count <= 10 else { return nil }
            return Int(digits)
        }
        func slice(_ s: Int?, _ e: Int?) -> Data? {
            guard let s, let e, s >= 0, s <= e, e <= d.count else { return nil }
            return Data(d[(d.startIndex + s)..<(d.startIndex + e)])
        }
        if let frag = slice(offset("StartFragment"), offset("EndFragment")), !frag.isEmpty { return frag }
        if let whole = slice(offset("StartHTML"), offset("EndHTML")), !whole.isEmpty { return whole }
        return d
    }

    // MARK: - text export helpers

    /// File name for exporting a clip as text: "<index> <first line>.txt", with `/`, `:`, `\` and control
    /// characters replaced, no leading dots/spaces, at most 60 characters in total.
    public static func textFileName(for clip: Clip, index: Int) -> String {
        let firstLine = clip.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var stem = String(firstLine.map { c -> Character in
            if c == "/" || c == ":" || c == "\\" { return "-" }
            if c.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return " " }
            return c
        })
        stem = stem.trimmingCharacters(in: .whitespaces)
        while let f = stem.first, f == "." || f == " " { stem.removeFirst() }
        if stem.isEmpty { stem = "Clip" }
        let prefix = "\(index) "
        let ext = ".txt"
        let room = max(1, 60 - prefix.count - ext.count)
        stem = String(stem.prefix(room)).trimmingCharacters(in: .whitespaces)
        while let l = stem.last, l == "." || l == " " { stem.removeLast() }
        if stem.isEmpty { stem = "Clip" }
        var name = prefix + stem + ext
        while let f = name.first, f == "." { name.removeFirst() }
        return String(name.prefix(60))
    }
}
