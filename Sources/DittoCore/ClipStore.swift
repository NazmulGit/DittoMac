// Clip database: schema, migrations, CRUD, dedupe, ordering, groups, stickies, retention, stats.
//
// Security invariant: every value reaches SQLite through a bound parameter. SQL text is assembled only
// from constant fragments defined in this file and in SearchQuery (fixed column names).
//
// Vault (schema v2): locked clips keep their formats AES-GCM encrypted (`Data.encrypted = 1`) and their
// description / quick-paste text in `Main.lockedText`; `Main.mText` holds only a placeholder. Without
// `vaultKey` they read as placeholders with no formats, and no delete path except `deleteLocked` (which
// needs an unlocked session) or `purgeLockedClips` (vault reset) removes them. See docs/kb/vault.md.

import Foundation
import SQLite3
import CryptoKit

public enum ClipStoreError: Error, Equatable, LocalizedError {
    /// The operation needs the vault key (an unlocked vault session).
    case locked
    /// Locked data could not be decrypted with the current vault key (wrong key or damaged data).
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .locked: return "Unlock your locked notes first."
        case .decryptionFailed: return "A locked note couldn’t be decrypted with the current vault key."
        }
    }
}

public final class ClipStore: @unchecked Sendable {
    public struct AddOptions: Sendable {
        public var allowDuplicates = false
        public var allowBackToBackDuplicates = false
        public var makeTopSticky = false
        public var makeLastSticky = false
        public var replaceTopSticky = false
        public init() {}
    }

    /// Schema version stored in PRAGMA user_version.
    static let schemaVersion: Int64 = 2
    /// What a locked clip's description reads as (and what `Main.mText` holds for it).
    public static let lockedPlaceholder = "Locked note"
    /// Gap below which ordering values are renormalised before computing a midpoint.
    static let minOrderGap = 1e-6

    public let path: String
    private let db: SQLiteDatabase
    private let lock = NSLock()
    private let isMemory: Bool
    private var _vaultKey: SymmetricKey?

    /// The vault data key while the vault is unlocked (set by the app), nil while locked. With a key, locked
    /// clips read transparently decrypted; without one they read as placeholders with no formats.
    public var vaultKey: SymmetricKey? {
        get { locked { _vaultKey } }
        set { locked { _vaultKey = newValue } }
    }

    // MARK: - init

    public init(path: String) throws {
        self.path = path
        isMemory = (path == ":memory:" || path.isEmpty)
        if !isMemory {
            let fm = FileManager.default
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty, !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                chmod(dir, 0o700)
            }
            if !fm.fileExists(atPath: path) {
                guard fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw SQLiteError(code: SQLITE_CANTOPEN, message: "cannot create database file")
                }
            }
            chmod(path, 0o600)
        }
        db = try SQLiteDatabase(path: isMemory ? ":memory:" : path)
        try db.registerRegexpFunction()
        try db.exec("PRAGMA foreign_keys = ON")
        // Overwrite freed pages/cells so plaintext replaced by `lock` (or deleted clips) doesn't linger in the file.
        try db.exec("PRAGMA secure_delete = ON")
        if !isMemory { try db.exec("PRAGMA journal_mode = WAL") }
        try migrate()
        if !isMemory {
            for suffix in ["", "-wal", "-shm"] { chmod(path + suffix, 0o600) }
        }
    }

    public static func inMemory() throws -> ClipStore { try ClipStore(path: ":memory:") }

    private func migrate() throws {
        let version = try db.scalarInt("PRAGMA user_version") ?? 0
        if version < 1 {
            try db.transaction {
                try db.exec("""
                CREATE TABLE IF NOT EXISTS Main(
                  lID INTEGER PRIMARY KEY AUTOINCREMENT,
                  lDate INTEGER NOT NULL,
                  mText TEXT NOT NULL DEFAULT '',
                  lShortCut INTEGER NOT NULL DEFAULT 0,
                  lDontAutoDelete INTEGER NOT NULL DEFAULT 0,
                  CRC INTEGER NOT NULL DEFAULT 0,
                  bIsGroup INTEGER NOT NULL DEFAULT 0,
                  lParentID INTEGER NOT NULL DEFAULT -1,
                  QuickPasteText TEXT NOT NULL DEFAULT '',
                  clipOrder REAL NOT NULL DEFAULT 0,
                  clipGroupOrder REAL NOT NULL DEFAULT 0,
                  globalShortCut INTEGER NOT NULL DEFAULT 0,
                  lastPasteDate INTEGER NOT NULL DEFAULT 0,
                  stickyClipOrder REAL NOT NULL DEFAULT -2147483647,
                  stickyClipGroupOrder REAL NOT NULL DEFAULT -2147483647,
                  MoveToGroupShortCut INTEGER NOT NULL DEFAULT 0,
                  GlobalMoveToGroupShortCut INTEGER NOT NULL DEFAULT 0,
                  sourceApp TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE IF NOT EXISTS Data(
                  lID INTEGER PRIMARY KEY AUTOINCREMENT,
                  lParentID INTEGER NOT NULL REFERENCES Main(lID) ON DELETE CASCADE,
                  strClipBoardFormat TEXT NOT NULL,
                  ooData BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS CopyBuffers(lID INTEGER PRIMARY KEY AUTOINCREMENT, lClipID INTEGER, lCopyBuffer INTEGER);
                CREATE INDEX IF NOT EXISTS Main_TopLevel ON Main(stickyClipOrder DESC, bIsGroup, clipOrder DESC);
                CREATE INDEX IF NOT EXISTS Main_InGroup2 ON Main(lParentID, stickyClipGroupOrder DESC, bIsGroup, clipGroupOrder DESC);
                CREATE INDEX IF NOT EXISTS Main_CRC ON Main(CRC);
                CREATE INDEX IF NOT EXISTS Main_ParentId ON Main(lParentID);
                CREATE INDEX IF NOT EXISTS Main_ClipOrder ON Main(clipOrder DESC);
                CREATE INDEX IF NOT EXISTS Data_ParentId_Format ON Data(lParentID, strClipBoardFormat);
                PRAGMA user_version = 1;
                """)
            }
        }
        if version < 2 {
            try db.transaction {
                if try !hasColumn(mainTable: true, "isLocked") {
                    try db.exec("ALTER TABLE Main ADD COLUMN isLocked INTEGER NOT NULL DEFAULT 0")
                }
                if try !hasColumn(mainTable: true, "lockedText") {
                    try db.exec("ALTER TABLE Main ADD COLUMN lockedText BLOB")
                }
                if try !hasColumn(mainTable: false, "encrypted") {
                    try db.exec("ALTER TABLE Data ADD COLUMN encrypted INTEGER NOT NULL DEFAULT 0")
                }
                try db.exec("PRAGMA user_version = 2")
            }
        }
        // Future migrations: `if version < 3 { ... PRAGMA user_version = 3 }`.
    }

    private func hasColumn(mainTable: Bool, _ name: String) throws -> Bool {
        let st = try db.prepare(mainTable ? "PRAGMA table_info(Main)" : "PRAGMA table_info(Data)")
        while try st.step() {
            if st.string(1) == name { return true }
        }
        return false
    }

    @discardableResult
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - SQL fragments (constants only)

    static let mainColumns = """
    Main.lID, Main.lDate, Main.mText, Main.lShortCut, Main.lDontAutoDelete, Main.CRC, Main.bIsGroup, \
    Main.lParentID, Main.QuickPasteText, Main.clipOrder, Main.clipGroupOrder, Main.globalShortCut, \
    Main.lastPasteDate, Main.stickyClipOrder, Main.stickyClipGroupOrder, Main.MoveToGroupShortCut, \
    Main.GlobalMoveToGroupShortCut, Main.sourceApp, Main.isLocked, Main.lockedText
    """
    static let mainColumnCount: Int32 = 20
    static let historyOrder = " ORDER BY Main.stickyClipOrder DESC, Main.bIsGroup ASC, Main.clipOrder DESC"
    static let groupOrder = " ORDER BY Main.stickyClipGroupOrder DESC, Main.bIsGroup ASC, Main.clipGroupOrder DESC"
    /// Upstream auto-delete protection: two binds (sentinel, sentinel).
    static let deletableWhere = """
    bIsGroup = 0 AND lShortCut = 0 AND lParentID <= 0 AND lDontAutoDelete = 0 \
    AND stickyClipOrder = ? AND stickyClipGroupOrder = ? AND isLocked = 0
    """
    static let fullTextJoin = """
     LEFT JOIN Data ft ON ft.lID = (SELECT d.lID FROM Data d WHERE d.lParentID = Main.lID \
    AND d.strClipBoardFormat = ? AND d.encrypted = 0 ORDER BY d.lID LIMIT 1)
    """

    private static func seconds(_ d: Date) -> Int64 {
        let t = d.timeIntervalSince1970
        return t.isFinite ? Int64(t.rounded(.down)) : 0
    }

    private static func date(_ s: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(s)) }

    private func readClip(_ st: SQLiteStatement, _ o: Int32 = 0) -> Clip {
        var c = readPlainClip(st, o)
        if c.isLocked {
            c.text = Self.lockedPlaceholder
            c.quickPasteText = ""
            if let key = _vaultKey, let t = Self.openLockedText(st.data(o + 19), key: key, clipID: c.id) {
                c.text = t.description
                c.quickPasteText = t.quickPasteText
            }
        }
        return c
    }

    private func readPlainClip(_ st: SQLiteStatement, _ o: Int32) -> Clip {
        Clip(id: st.int64(o),
             date: Self.date(st.int64(o + 1)),
             text: st.string(o + 2),
             shortcut: st.int(o + 3),
             globalShortcut: st.int64(o + 11) != 0,
             dontAutoDelete: st.int64(o + 4) != 0,
             crc: Int32(truncatingIfNeeded: st.int64(o + 5)),
             isGroup: st.int64(o + 6) != 0,
             parentID: st.int64(o + 7),
             quickPasteText: st.string(o + 8),
             clipOrder: st.double(o + 9),
             clipGroupOrder: st.double(o + 10),
             lastPasteDate: Self.date(st.int64(o + 12)),
             stickyClipOrder: st.double(o + 13),
             stickyClipGroupOrder: st.double(o + 14),
             moveToGroupShortcut: st.int(o + 15),
             globalMoveToGroupShortcut: st.int64(o + 16) != 0,
             sourceApp: st.string(o + 17),
             isLocked: st.int64(o + 18) != 0)
    }

    // MARK: vault helpers

    private struct LockedText: Codable {
        var description: String
        var quickPasteText: String
    }

    private static func sealLockedText(description: String, quickPasteText: String, key: SymmetricKey, clipID: Int64) throws -> Data {
        let json = try JSONEncoder().encode(LockedText(description: description, quickPasteText: quickPasteText))
        return try Vault.seal(json, key: key, aad: Vault.textAAD(clipID: clipID))
    }

    private static func openLockedText(_ blob: Data, key: SymmetricKey, clipID: Int64) -> LockedText? {
        guard !blob.isEmpty, let json = try? Vault.open(blob, key: key, aad: Vault.textAAD(clipID: clipID)) else { return nil }
        return try? JSONDecoder().decode(LockedText.self, from: json)
    }

    private func rowIsLocked(_ id: Int64) throws -> Bool {
        (try db.scalarInt("SELECT isLocked FROM Main WHERE lID = ?", [.int(id)]) ?? 0) != 0
    }

    private func lockedTextBlob(_ id: Int64) throws -> Data {
        let st = try db.prepare("SELECT lockedText FROM Main WHERE lID = ?")
        try st.bind(1, id)
        return try st.step() ? st.data(0) : Data()
    }

    private static func randomCRC() -> Int64 { Int64(Int32.random(in: Int32.min...Int32.max)) }

    /// Flushes the WAL into the main file and truncates it so old plaintext page images don't linger there.
    private func checkpointQuietly() {
        guard !isMemory else { return }
        try? db.exec("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private func fetchClips(_ sql: String, _ binds: [SQLiteValue]) throws -> [Clip] {
        let st = try db.prepare(sql)
        try st.bind(binds)
        var out: [Clip] = []
        while try st.step() { out.append(readClip(st)) }
        return out
    }

    private func mainValues(_ c: Clip) -> [SQLiteValue] {
        [.int(Self.seconds(c.date)), .text(c.text), .int(Int64(c.shortcut)), .int(c.dontAutoDelete ? 1 : 0),
         .int(Int64(c.crc)), .int(c.isGroup ? 1 : 0), .int(c.parentID), .text(c.quickPasteText),
         .double(c.clipOrder), .double(c.clipGroupOrder), .int(c.globalShortcut ? 1 : 0),
         .int(Self.seconds(c.lastPasteDate)), .double(c.stickyClipOrder), .double(c.stickyClipGroupOrder),
         .int(Int64(c.moveToGroupShortcut)), .int(c.globalMoveToGroupShortcut ? 1 : 0), .text(c.sourceApp)]
    }

    private func insertMain(_ c: Clip) throws -> Int64 {
        try db.run("""
        INSERT INTO Main(lDate, mText, lShortCut, lDontAutoDelete, CRC, bIsGroup, lParentID, QuickPasteText, \
        clipOrder, clipGroupOrder, globalShortCut, lastPasteDate, stickyClipOrder, stickyClipGroupOrder, \
        MoveToGroupShortCut, GlobalMoveToGroupShortCut, sourceApp) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, mainValues(c))
        return db.lastInsertRowID
    }

    /// Inserts formats; with `encryptWith` each blob is sealed (AAD binds clip id + type) and flagged encrypted.
    private func insertFormats(_ clipID: Int64, _ formats: [ClipFormat], encryptWith key: SymmetricKey? = nil) throws {
        let st = try db.prepare("INSERT INTO Data(lParentID, strClipBoardFormat, ooData, encrypted) VALUES(?,?,?,?)")
        for f in formats {
            st.reset()
            try st.bind(1, clipID)
            try st.bind(2, f.type)
            if let key {
                try st.bind(3, try Vault.seal(f.data, key: key, aad: Vault.dataAAD(clipID: clipID, type: f.type)))
                try st.bind(4, 1)
            } else {
                try st.bind(3, f.data)
                try st.bind(4, 0)
            }
            try st.step()
        }
    }

    private func _clip(_ id: Int64) throws -> Clip? {
        try fetchClips("SELECT " + Self.mainColumns + " FROM Main WHERE Main.lID = ?", [.int(id)]).first
    }

    /// Formats of a clip. Encrypted rows are decrypted with the vault key; without a key (or when a row fails
    /// to authenticate) they are left out, so a locked clip reads as having no formats.
    private func _formats(_ clipID: Int64) throws -> [ClipFormat] {
        let st = try db.prepare("SELECT lID, strClipBoardFormat, ooData, encrypted FROM Data WHERE lParentID = ? ORDER BY lID")
        try st.bind(1, clipID)
        var out: [ClipFormat] = []
        while try st.step() {
            let type = st.string(1)
            if st.int64(3) != 0 {
                guard let key = _vaultKey,
                      let plain = try? Vault.open(st.data(2), key: key, aad: Vault.dataAAD(clipID: clipID, type: type)) else { continue }
                out.append(ClipFormat(id: st.int64(0), type: type, data: plain))
            } else {
                out.append(ClipFormat(id: st.int64(0), type: type, data: st.data(2)))
            }
        }
        return out
    }

    private func maxClipOrder() throws -> Double {
        try db.scalarDouble("SELECT MAX(clipOrder) FROM Main") ?? 0
    }

    private func minClipOrder() throws -> Double {
        try db.scalarDouble("SELECT MIN(clipOrder) FROM Main") ?? 0
    }

    private func maxGroupOrder(_ parent: Int64) throws -> Double {
        try db.scalarDouble("SELECT MAX(clipGroupOrder) FROM Main WHERE lParentID = ?", [.int(parent)]) ?? 0
    }

    private func minGroupOrder(_ parent: Int64) throws -> Double {
        try db.scalarDouble("SELECT MIN(clipGroupOrder) FROM Main WHERE lParentID = ?", [.int(parent)]) ?? 0
    }

    private func recomputeCRC(_ clipID: Int64) throws {
        if try rowIsLocked(clipID) {   // never store a CRC that could confirm a locked clip's content
            try db.run("UPDATE Main SET CRC = ? WHERE lID = ?", [.int(Self.randomCRC()), .int(clipID)])
            return
        }
        let crc = CRC32.clipCRC(try _formats(clipID))
        try db.run("UPDATE Main SET CRC = ? WHERE lID = ?", [.int(Int64(crc)), .int(clipID)])
    }

    private func cleanCopyBuffers() throws {
        try db.run("DELETE FROM CopyBuffers WHERE lClipID IS NOT NULL AND lClipID NOT IN (SELECT lID FROM Main)")
    }

    // MARK: - capture

    public func addClip(formats: [ClipFormat], description: String, sourceApp: String,
                        parentID: Int64 = -1, options: AddOptions = .init()) throws -> AddResult {
        guard !formats.isEmpty else { return .rejected }
        return try locked {
            try db.transaction {
                let crc = CRC32.clipCRC(formats)
                let topLevel = parentID == Ditto.topLevelParent
                if topLevel {
                    var dupID: Int64?
                    if !options.allowDuplicates {
                        dupID = try db.scalarInt("""
                        SELECT lID FROM Main WHERE CRC = ? AND bIsGroup = 0 AND lParentID = ? AND isLocked = 0 \
                        ORDER BY clipOrder DESC LIMIT 1
                        """, [.int(Int64(crc)), .int(Ditto.topLevelParent)])
                    } else if !options.allowBackToBackDuplicates {
                        let st = try db.prepare("SELECT lID, CRC, isLocked FROM Main WHERE bIsGroup = 0 ORDER BY lID DESC LIMIT 1")
                        if try st.step(), st.int64(2) == 0, Int32(truncatingIfNeeded: st.int64(1)) == crc { dupID = st.int64(0) }
                    }
                    if let dupID {
                        try db.run("UPDATE Main SET clipOrder = ? WHERE lID = ?", [.double(try maxClipOrder() + 1), .int(dupID)])
                        try applyStickyOptions(dupID, parent: parentID, options)
                        return .duplicateBumped(dupID)
                    }
                }
                let now = Date()
                var clip = Clip(date: now, text: description, crc: crc, parentID: parentID,
                                clipOrder: try maxClipOrder() + 1,
                                clipGroupOrder: topLevel ? 0 : try maxGroupOrder(parentID) + 1,
                                lastPasteDate: now, sourceApp: sourceApp)
                if topLevel { clip.clipGroupOrder = clip.clipOrder }
                let id = try insertMain(clip)
                try insertFormats(id, formats)
                try applyStickyOptions(id, parent: parentID, options)
                return .inserted(id)
            }
        }
    }

    private func applyStickyOptions(_ id: Int64, parent: Int64, _ o: AddOptions) throws {
        let inGroup = parent != Ditto.topLevelParent
        if o.replaceTopSticky {
            let top = try stickyExtreme(max: true, inGroup: inGroup, parent: parent, excluding: id)
            if let top {
                if inGroup {
                    try db.run("UPDATE Main SET stickyClipGroupOrder = ? WHERE lParentID = ? AND stickyClipGroupOrder = ? AND lID <> ?",
                               [.double(Ditto.stickySentinel), .int(parent), .double(top), .int(id)])
                } else {
                    try db.run("UPDATE Main SET stickyClipOrder = ? WHERE stickyClipOrder = ? AND lID <> ?",
                               [.double(Ditto.stickySentinel), .double(top), .int(id)])
                }
            }
            try _makeSticky(id, top: true, inGroup: inGroup)
        } else if o.makeTopSticky {
            try _makeSticky(id, top: true, inGroup: inGroup)
        } else if o.makeLastSticky {
            try _makeSticky(id, top: false, inGroup: inGroup)
        }
    }

    // MARK: - reading

    /// Builds FROM/WHERE for a filter. Returns SQL starting at " FROM" and its binds.
    private func filterSQL(_ f: ClipFilter) -> (sql: String, binds: [SQLiteValue]) {
        var sql = " FROM Main"
        var binds: [SQLiteValue] = []
        let search = (f.search?.isEmpty == false) ? f.search : nil
        if let search, search.usesFullText {
            sql += Self.fullTextJoin
            binds.append(.text(ClipUTI.plainText))
        }
        if let parent = f.parentID {
            sql += " WHERE Main.lParentID = ?"
            binds.append(.int(parent))
        } else {
            var base = f.showAllClipsInMainList ? "(Main.bIsGroup = 0)" : "(Main.bIsGroup = 0 AND Main.lParentID = ?)"
            if !f.showAllClipsInMainList { binds.append(.int(Ditto.topLevelParent)) }
            if f.showGroupsInMainList {
                base += " OR (Main.bIsGroup = 1 AND Main.lParentID = ?)"
                binds.append(.int(Ditto.topLevelParent))
            }
            sql += " WHERE (" + base + ")"
        }
        if let search {
            let w = search.sqlWhere()
            sql += " AND " + w.sql
            binds += w.binds.map { .text($0) }
        }
        return (sql, binds)
    }

    public func clips(_ filter: ClipFilter) throws -> [Clip] {
        try locked {
            var (sql, binds) = filterSQL(filter)
            sql = "SELECT " + Self.mainColumns + sql
            sql += filter.parentID == nil ? Self.historyOrder : Self.groupOrder
            sql += " LIMIT ? OFFSET ?"
            binds.append(.int(filter.limit > 0 ? Int64(filter.limit) : -1))
            binds.append(.int(Int64(max(0, filter.offset))))
            return try fetchClips(sql, binds)
        }
    }

    public func count(_ filter: ClipFilter) throws -> Int {
        try locked {
            let (sql, binds) = filterSQL(filter)
            return Int(try db.scalarInt("SELECT COUNT(*)" + sql, binds) ?? 0)
        }
    }

    public func clip(id: Int64) throws -> Clip? {
        try locked { try _clip(id) }
    }

    public func formats(clipID: Int64) throws -> [ClipFormat] {
        try locked { try _formats(clipID) }
    }

    /// Formats of a clip that is NOT locked, read atomically with the lock check (nil for a locked clip, even while
    /// the vault is unlocked). Background readers (sync) use this so a clip locked after they listed it is never
    /// read as plaintext.
    public func unlockedFormats(clipID: Int64) throws -> [ClipFormat]? {
        try locked {
            if try rowIsLocked(clipID) { return nil }
            return try _formats(clipID)
        }
    }

    /// Stored types and (plaintext) sizes. Encrypted formats are listed only while the vault key is set.
    public func formatTypes(clipID: Int64) throws -> [(type: String, size: Int)] {
        try locked {
            let st = try db.prepare("SELECT strClipBoardFormat, LENGTH(ooData), encrypted FROM Data WHERE lParentID = ? ORDER BY lID")
            try st.bind(1, clipID)
            var out: [(type: String, size: Int)] = []
            while try st.step() {
                if st.int64(2) != 0 {
                    guard _vaultKey != nil else { continue }
                    out.append((st.string(0), max(0, st.int(1) - Vault.sealOverhead)))
                } else {
                    out.append((st.string(0), st.int(1)))
                }
            }
            return out
        }
    }

    public func data(clipID: Int64, type: String) throws -> Data? {
        try locked {
            let st = try db.prepare("SELECT ooData, encrypted FROM Data WHERE lParentID = ? AND strClipBoardFormat = ? ORDER BY lID LIMIT 1")
            try st.bind(1, clipID)
            try st.bind(2, type)
            guard try st.step() else { return nil }
            if st.int64(1) != 0 {
                guard let key = _vaultKey else { return nil }
                return try? Vault.open(st.data(0), key: key, aad: Vault.dataAAD(clipID: clipID, type: type))
            }
            return st.data(0)
        }
    }

    public func groups() throws -> [Clip] {
        try locked {
            try fetchClips("SELECT " + Self.mainColumns + " FROM Main WHERE Main.bIsGroup = 1 ORDER BY Main.mText COLLATE NOCASE, Main.lID", [])
        }
    }

    public func children(ofGroup id: Int64) throws -> [Clip] {
        try locked {
            try fetchClips("SELECT " + Self.mainColumns + " FROM Main WHERE Main.lParentID = ?" + Self.groupOrder, [.int(id)])
        }
    }

    public func clipsWithShortcuts() throws -> [Clip] {
        try locked {
            try fetchClips("SELECT " + Self.mainColumns + " FROM Main WHERE Main.lShortCut <> 0 OR Main.MoveToGroupShortCut <> 0 ORDER BY Main.lID", [])
        }
    }

    /// Finds a group by exact name under `parentID` (used by import to preserve groups by name).
    func findGroup(named name: String, parentID: Int64) throws -> Int64? {
        try locked {
            try db.scalarInt("SELECT lID FROM Main WHERE bIsGroup = 1 AND mText = ? AND lParentID = ? ORDER BY lID LIMIT 1",
                             [.text(name), .int(parentID)])
        }
    }

    /// Inserts a clip row and its formats verbatim (all columns except id). Used by export.
    func insertRaw(_ clip: Clip, formats: [ClipFormat]) throws -> Int64 {
        try locked {
            try db.transaction {
                let id = try insertMain(clip)
                try insertFormats(id, formats)
                return id
            }
        }
    }

    // MARK: - mutation

    static let updateMainSQL = """
    UPDATE Main SET lDate = ?, mText = ?, lShortCut = ?, lDontAutoDelete = ?, CRC = ?, bIsGroup = ?, \
    lParentID = ?, QuickPasteText = ?, clipOrder = ?, clipGroupOrder = ?, globalShortCut = ?, \
    lastPasteDate = ?, stickyClipOrder = ?, stickyClipGroupOrder = ?, MoveToGroupShortCut = ?, \
    GlobalMoveToGroupShortCut = ?, sourceApp = ? WHERE lID = ?
    """

    /// Writes every Main column of `clip` except the lock state (`isLocked` is changed only by `lock` /
    /// `removeLock`). For a locked clip the plaintext never reaches `mText`: with the vault key the new
    /// description / quick-paste text are re-encrypted into `lockedText`; without it text changes are ignored.
    /// A clip still carrying the placeholder text (read while locked) keeps its stored text.
    public func update(_ clip: Clip) throws {
        try locked {
            try db.transaction {
                guard try rowIsLocked(clip.id) else {
                    _ = try db.run(Self.updateMainSQL, mainValues(clip) + [.int(clip.id)])
                    return
                }
                var c = clip
                c.crc = Int32(truncatingIfNeeded: try db.scalarInt("SELECT CRC FROM Main WHERE lID = ?", [.int(clip.id)]) ?? 0)
                c.text = Self.lockedPlaceholder
                c.quickPasteText = ""
                c.isGroup = false
                _ = try db.run(Self.updateMainSQL, mainValues(c) + [.int(clip.id)])
                let unchanged = clip.text == Self.lockedPlaceholder && clip.quickPasteText.isEmpty
                if let key = _vaultKey, !unchanged {
                    let blob = try Self.sealLockedText(description: clip.text, quickPasteText: clip.quickPasteText,
                                                       key: key, clipID: clip.id)
                    try db.run("UPDATE Main SET lockedText = ? WHERE lID = ?", [.blob(blob), .int(clip.id)])
                }
            }
        }
    }

    /// Replaces a clip's formats. For a locked clip this needs the vault key (throws `ClipStoreError.locked`
    /// otherwise); the new formats and description are stored encrypted.
    public func replaceFormats(clipID: Int64, formats: [ClipFormat], description: String?) throws {
        try locked {
            try db.transaction {
                if try rowIsLocked(clipID) {
                    guard let key = _vaultKey else { throw ClipStoreError.locked }
                    try db.run("DELETE FROM Data WHERE lParentID = ?", [.int(clipID)])
                    try insertFormats(clipID, formats, encryptWith: key)
                    try db.run("UPDATE Main SET CRC = ? WHERE lID = ?", [.int(Self.randomCRC()), .int(clipID)])
                    if let description {
                        let old = Self.openLockedText(try lockedTextBlob(clipID), key: key, clipID: clipID)
                        let blob = try Self.sealLockedText(description: description, quickPasteText: old?.quickPasteText ?? "",
                                                           key: key, clipID: clipID)
                        try db.run("UPDATE Main SET lockedText = ? WHERE lID = ?", [.blob(blob), .int(clipID)])
                    }
                    return
                }
                try db.run("DELETE FROM Data WHERE lParentID = ?", [.int(clipID)])
                try insertFormats(clipID, formats)
                try db.run("UPDATE Main SET CRC = ? WHERE lID = ?", [.int(Int64(CRC32.clipCRC(formats))), .int(clipID)])
                if let description {
                    try db.run("UPDATE Main SET mText = ? WHERE lID = ?", [.text(description), .int(clipID)])
                }
            }
        }
    }

    /// Deletes one stored format. Formats of a locked clip are only removed while the vault is unlocked
    /// (silently skipped otherwise).
    public func deleteFormat(formatID: Int64) throws {
        try locked {
            try db.transaction {
                guard let parent = try db.scalarInt("SELECT lParentID FROM Data WHERE lID = ?", [.int(formatID)]) else { return }
                if _vaultKey == nil, try rowIsLocked(parent) { return }
                try db.run("DELETE FROM Data WHERE lID = ?", [.int(formatID)])
                try recomputeCRC(parent)
            }
        }
    }

    /// Deletes clips/groups (group children are re-parented to top level). Locked clips are skipped unless
    /// `includeLocked`. Returns the number of rows deleted.
    @discardableResult
    private func _delete(_ ids: [Int64], includeLocked: Bool = false) throws -> Int {
        let reparent = try db.prepare("UPDATE Main SET lParentID = ?, stickyClipGroupOrder = ? WHERE lParentID = ?")
        let del = try db.prepare("DELETE FROM Main WHERE lID = ?")
        var deleted = 0
        for id in ids {
            if !includeLocked, try rowIsLocked(id) { continue }
            reparent.reset()
            try reparent.bind(1, Ditto.topLevelParent)
            try reparent.bind(2, Ditto.stickySentinel)
            try reparent.bind(3, id)
            try reparent.step()
            del.reset()
            try del.bind(1, id)
            try del.step()
            deleted += db.changes
        }
        try cleanCopyBuffers()
        return deleted
    }

    /// Deletes clips and groups. Locked clips are never deleted here (they are silently skipped; use
    /// `deleteLocked`). Returns the number of rows deleted.
    @discardableResult
    public func delete(ids: [Int64]) throws -> Int {
        try locked { try db.transaction { try _delete(ids) } }
    }

    public func createGroup(name: String, parentID: Int64 = -1) throws -> Int64 {
        try locked {
            try db.transaction {
                let now = Date()
                let g = Clip(date: now, text: name, isGroup: true, parentID: parentID,
                             clipOrder: try maxClipOrder() + 1, clipGroupOrder: try maxGroupOrder(parentID) + 1,
                             lastPasteDate: now)
                return try insertMain(g)
            }
        }
    }

    /// True when `ancestor` is `id` itself or one of its parent groups (cycle guard).
    private func isAncestor(_ ancestor: Int64, of id: Int64) throws -> Bool {
        var cur = id
        var seen = Set<Int64>()
        while cur != Ditto.topLevelParent, cur > 0, !seen.contains(cur) {
            if cur == ancestor { return true }
            seen.insert(cur)
            guard let p = try db.scalarInt("SELECT lParentID FROM Main WHERE lID = ?", [.int(cur)]) else { break }
            cur = p
        }
        return false
    }

    public func move(ids: [Int64], toGroup groupID: Int64) throws {
        try locked {
            try db.transaction {
                for id in ids {
                    guard let c = try _clip(id) else { continue }
                    if c.isGroup, groupID != Ditto.topLevelParent, try isAncestor(id, of: groupID) { continue }
                    let order = groupID == Ditto.topLevelParent ? c.clipOrder : try maxGroupOrder(groupID) + 1
                    try db.run("UPDATE Main SET lParentID = ?, clipGroupOrder = ?, stickyClipGroupOrder = ? WHERE lID = ?",
                               [.int(groupID), .double(order), .double(Ditto.stickySentinel), .int(id)])
                }
            }
        }
    }

    public func copyClips(ids: [Int64], toGroup groupID: Int64) throws -> [Int64] {
        try locked {
            try db.transaction {
                var out: [Int64] = []
                for id in ids {
                    guard var c = try _clip(id), !c.isGroup, !c.isLocked else { continue }
                    let formats = try _formats(id)
                    c.parentID = groupID
                    c.clipOrder = try maxClipOrder() + 1
                    c.clipGroupOrder = groupID == Ditto.topLevelParent ? c.clipOrder : try maxGroupOrder(groupID) + 1
                    c.stickyClipOrder = Ditto.stickySentinel
                    c.stickyClipGroupOrder = Ditto.stickySentinel
                    c.shortcut = 0
                    c.globalShortcut = false
                    let newID = try insertMain(c)
                    try insertFormats(newID, formats)
                    out.append(newID)
                }
                return out
            }
        }
    }

    public func markPasted(id: Int64, moveToTop: Bool) throws {
        try locked {
            try db.transaction {
                try db.run("UPDATE Main SET lastPasteDate = ? WHERE lID = ?", [.int(Self.seconds(Date())), .int(id)])
                if moveToTop { try _moveToTop(id) }
            }
        }
    }

    private func _moveToTop(_ id: Int64) throws {
        guard let c = try _clip(id) else { return }
        try db.run("UPDATE Main SET clipOrder = ? WHERE lID = ?", [.double(try maxClipOrder() + 1), .int(id)])
        if c.parentID != Ditto.topLevelParent {
            try db.run("UPDATE Main SET clipGroupOrder = ? WHERE lID = ?", [.double(try maxGroupOrder(c.parentID) + 1), .int(id)])
        }
    }

    public func moveToTop(id: Int64) throws {
        try locked { try db.transaction { try _moveToTop(id) } }
    }

    public func moveToBottom(id: Int64) throws {
        try locked {
            try db.transaction {
                guard let c = try _clip(id) else { return }
                try db.run("UPDATE Main SET clipOrder = ? WHERE lID = ?", [.double(try minClipOrder() - 1), .int(id)])
                if c.parentID != Ditto.topLevelParent {
                    try db.run("UPDATE Main SET clipGroupOrder = ? WHERE lID = ?", [.double(try minGroupOrder(c.parentID) - 1), .int(id)])
                }
            }
        }
    }

    // MARK: ordering helpers

    /// One of the four ordering columns plus the WHERE that defines the list it orders.
    private struct OrderScope {
        var column: String          // constant column name
        var scopeWhere: String      // constant SQL
        var binds: [SQLiteValue]
    }

    private func orderScope(for c: Clip, inGroup: Int64?) -> OrderScope {
        if let g = inGroup {
            if c.stickyClipGroupOrder != Ditto.stickySentinel {
                return OrderScope(column: "stickyClipGroupOrder", scopeWhere: "lParentID = ? AND stickyClipGroupOrder <> ?",
                                  binds: [.int(g), .double(Ditto.stickySentinel)])
            }
            return OrderScope(column: "clipGroupOrder", scopeWhere: "lParentID = ? AND stickyClipGroupOrder = ?",
                              binds: [.int(g), .double(Ditto.stickySentinel)])
        }
        if c.stickyClipOrder != Ditto.stickySentinel {
            return OrderScope(column: "stickyClipOrder", scopeWhere: "stickyClipOrder <> ?", binds: [.double(Ditto.stickySentinel)])
        }
        return OrderScope(column: "clipOrder", scopeWhere: "bIsGroup = 0 AND stickyClipOrder = ?", binds: [.double(Ditto.stickySentinel)])
    }

    private func orderValue(_ c: Clip, _ column: String) -> Double {
        switch column {
        case "stickyClipGroupOrder": return c.stickyClipGroupOrder
        case "clipGroupOrder": return c.clipGroupOrder
        case "stickyClipOrder": return c.stickyClipOrder
        default: return c.clipOrder
        }
    }

    /// Reassigns 1…n in current order to every row in the scope.
    private func renormalise(_ s: OrderScope) throws {
        let st = try db.prepare("SELECT lID FROM Main WHERE " + s.scopeWhere + " ORDER BY " + s.column + " ASC, lID ASC")
        try st.bind(s.binds)
        var ids: [Int64] = []
        while try st.step() { ids.append(st.int64(0)) }
        let up = try db.prepare("UPDATE Main SET " + s.column + " = ? WHERE lID = ?")
        for (i, id) in ids.enumerated() {
            up.reset()
            try up.bind(1, Double(i + 1))
            try up.bind(2, id)
            try up.step()
        }
    }

    private func shift(id: Int64, inGroup: Int64?, up: Bool) throws {
        for attempt in 0..<2 {
            guard let c = try _clip(id) else { return }
            let s = orderScope(for: c, inGroup: inGroup)
            let cur = orderValue(c, s.column)
            let cmp = up ? " > ?" : " < ?"
            let dir = up ? " ASC" : " DESC"
            let st = try db.prepare("SELECT " + s.column + " FROM Main WHERE " + s.scopeWhere + " AND lID <> ? AND "
                                    + s.column + cmp + " ORDER BY " + s.column + dir + " LIMIT 2")
            try st.bind(s.binds + [.int(id), .double(cur)])
            var n: [Double] = []
            while try st.step() { n.append(st.double(0)) }
            guard let first = n.first else { return }
            let newValue: Double
            if n.count == 1 {
                newValue = up ? first + 1 : first - 1
            } else if abs(n[1] - first) < Self.minOrderGap || abs(first - cur) < Self.minOrderGap {
                if attempt == 0 { try renormalise(s); continue }
                newValue = (first + n[1]) / 2
            } else {
                newValue = (first + n[1]) / 2
            }
            try db.run("UPDATE Main SET " + s.column + " = ? WHERE lID = ?", [.double(newValue), .int(id)])
            return
        }
    }

    public func moveUp(id: Int64, inGroup: Int64?) throws {
        try locked { try db.transaction { try shift(id: id, inGroup: inGroup, up: true) } }
    }

    public func moveDown(id: Int64, inGroup: Int64?) throws {
        try locked { try db.transaction { try shift(id: id, inGroup: inGroup, up: false) } }
    }

    // MARK: stickies

    private func stickyExtreme(max: Bool, inGroup: Bool, parent: Int64, excluding: Int64) throws -> Double? {
        if inGroup {
            return try db.scalarDouble((max ? "SELECT MAX" : "SELECT MIN")
                                       + "(stickyClipGroupOrder) FROM Main WHERE lParentID = ? AND stickyClipGroupOrder <> ? AND lID <> ?",
                                       [.int(parent), .double(Ditto.stickySentinel), .int(excluding)])
        }
        return try db.scalarDouble((max ? "SELECT MAX" : "SELECT MIN")
                                   + "(stickyClipOrder) FROM Main WHERE stickyClipOrder <> ? AND lID <> ?",
                                   [.double(Ditto.stickySentinel), .int(excluding)])
    }

    private func _makeSticky(_ id: Int64, top: Bool, inGroup: Bool) throws {
        guard let c = try _clip(id) else { return }
        let ext = try stickyExtreme(max: top, inGroup: inGroup, parent: c.parentID, excluding: id)
        let value = top ? (ext ?? 0) + 1 : (ext ?? 0) - 1
        if inGroup {
            try db.run("UPDATE Main SET stickyClipGroupOrder = ? WHERE lID = ?", [.double(value), .int(id)])
        } else {
            try db.run("UPDATE Main SET stickyClipOrder = ? WHERE lID = ?", [.double(value), .int(id)])
        }
    }

    public func makeTopSticky(id: Int64, inGroup: Bool) throws {
        try locked { try db.transaction { try _makeSticky(id, top: true, inGroup: inGroup) } }
    }

    public func makeLastSticky(id: Int64, inGroup: Bool) throws {
        try locked { try db.transaction { try _makeSticky(id, top: false, inGroup: inGroup) } }
    }

    /// Upstream "replace top sticky" semantics: the current top sticky at this level (top level, or within the
    /// clip's group) loses its sticky status and this clip becomes the top sticky.
    public func replaceTopSticky(id: Int64, inGroup: Bool) throws {
        try locked {
            try db.transaction {
                guard let c = try _clip(id) else { return }
                if let top = try stickyExtreme(max: true, inGroup: inGroup, parent: c.parentID, excluding: id) {
                    if inGroup {
                        try db.run("UPDATE Main SET stickyClipGroupOrder = ? WHERE lParentID = ? AND stickyClipGroupOrder = ? AND lID <> ?",
                                   [.double(Ditto.stickySentinel), .int(c.parentID), .double(top), .int(id)])
                    } else {
                        try db.run("UPDATE Main SET stickyClipOrder = ? WHERE stickyClipOrder = ? AND lID <> ?",
                                   [.double(Ditto.stickySentinel), .double(top), .int(id)])
                    }
                }
                try _makeSticky(id, top: true, inGroup: inGroup)
            }
        }
    }

    public func removeSticky(id: Int64) throws {
        try locked {
            _ = try db.run("UPDATE Main SET stickyClipOrder = ?, stickyClipGroupOrder = ? WHERE lID = ?",
                           [.double(Ditto.stickySentinel), .double(Ditto.stickySentinel), .int(id)])
        }
    }

    // MARK: - retention / maintenance

    /// Deletes unprotected clips beyond `maxEntries` (ordered by clipOrder DESC) and those whose
    /// lastPasteDate is older than `expireDays`. nil or values <= 0 disable a rule.
    public func applyRetention(maxEntries: Int?, expireDays: Int?, now: Date = Date()) throws -> Int {
        try locked {
            try db.transaction {
                var deleted = 0
                let sentinels: [SQLiteValue] = [.double(Ditto.stickySentinel), .double(Ditto.stickySentinel)]
                if let maxEntries, maxEntries > 0 {
                    deleted += try db.run("DELETE FROM Main WHERE lID IN (SELECT lID FROM Main WHERE " + Self.deletableWhere
                                          + " ORDER BY clipOrder DESC LIMIT -1 OFFSET ?)",
                                          sentinels + [.int(Int64(maxEntries))])
                }
                if let expireDays, expireDays > 0 {
                    let cutoff = Self.seconds(now) - Int64(expireDays) * 86_400
                    deleted += try db.run("DELETE FROM Main WHERE " + Self.deletableWhere + " AND lastPasteDate < ?",
                                          sentinels + [.int(cutoff)])
                }
                if deleted > 0 { try cleanCopyBuffers() }
                return deleted
            }
        }
    }

    /// Removes garbage: Data rows without a parent clip and non-group clips that have no formats left.
    /// Returns the number of rows removed.
    public func deleteNonUsedClips() throws -> Int {
        try locked {
            try db.transaction {
                // Upstream DeleteNonUsedClips (DatabaseUtilities.cpp:963): delete every clip that is not
                // protected (group, shortcut, in a group, never-auto-delete, sticky).
                var n = try db.run("DELETE FROM Main WHERE bIsGroup = 0 AND lShortCut = 0 AND lParentID <= 0 AND lDontAutoDelete = 0 AND stickyClipOrder = -2147483647 AND stickyClipGroupOrder = -2147483647 AND isLocked = 0")
                try db.run("DELETE FROM Data WHERE lParentID NOT IN (SELECT lID FROM Main)")
                n += try db.run("DELETE FROM Main WHERE bIsGroup = 0 AND isLocked = 0 AND NOT EXISTS (SELECT 1 FROM Data WHERE Data.lParentID = Main.lID)")
                try cleanCopyBuffers()
                return n
            }
        }
    }

    /// Deletes every clip and group except locked clips (which move to top level when their group goes).
    /// Returns the number of rows deleted.
    @discardableResult
    public func deleteAll() throws -> Int {
        try locked {
            try db.transaction {
                try db.run("UPDATE Main SET lParentID = ?, stickyClipGroupOrder = ? WHERE isLocked = 1 AND lParentID <> ?",
                           [.int(Ditto.topLevelParent), .double(Ditto.stickySentinel), .int(Ditto.topLevelParent)])
                let n = try db.run("DELETE FROM Main WHERE isLocked = 0")
                try db.run("DELETE FROM Data WHERE lParentID NOT IN (SELECT lID FROM Main)")
                try cleanCopyBuffers()
                return n
            }
        }
    }

    /// Compacts the database. For file databases VACUUM runs on a separate short-lived connection so the main
    /// connection's lock isn't held for the duration (WAL mode lets readers continue meanwhile).
    public func vacuum() throws {
        if isMemory {
            try locked { try db.exec("VACUUM") }
            return
        }
        try locked { try db.exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        let other = try SQLiteDatabase(path: path)
        sqlite3_busy_timeout(other.handle, 30_000)
        try other.exec("VACUUM")
    }

    public func backup(to url: URL) throws {
        try locked {
            let destPath = url.path
            let fm = FileManager.default
            if !fm.fileExists(atPath: destPath) {
                _ = fm.createFile(atPath: destPath, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            chmod(destPath, 0o600)
            let dest = try SQLiteDatabase(path: destPath)
            guard let b = sqlite3_backup_init(dest.handle, "main", db.handle, "main") else {
                throw dest.error(sqlite3_errcode(dest.handle))
            }
            let rc = sqlite3_backup_step(b, -1)
            let frc = sqlite3_backup_finish(b)
            guard rc == SQLITE_DONE else { throw SQLiteError(code: rc, message: dest.lastErrorMessage) }
            guard frc == SQLITE_OK else { throw dest.error(frc) }
            for suffix in ["", "-wal", "-shm"] { chmod(destPath + suffix, 0o600) }
        }
    }

    public func stats() throws -> StoreStats {
        try locked {
            var s = StoreStats()
            s.clips = Int(try db.scalarInt("SELECT COUNT(*) FROM Main WHERE bIsGroup = 0") ?? 0)
            s.groups = Int(try db.scalarInt("SELECT COUNT(*) FROM Main WHERE bIsGroup = 1") ?? 0)
            s.formats = Int(try db.scalarInt("SELECT COUNT(*) FROM Data") ?? 0)
            if !isMemory {
                let fm = FileManager.default
                for p in [path, path + "-wal"] {
                    if let size = (try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber {
                        s.databaseBytes += size.int64Value
                    }
                }
            }
            return s
        }
    }

    public func clipsMatching(dataFilter f: ClipDataFilter) throws -> [(clip: Clip, bytes: Int)] {
        try locked {
            var binds: [SQLiteValue] = []
            var sql = "SELECT " + Self.mainColumns + ", (SELECT COALESCE(SUM(LENGTH(Data.ooData)), 0) FROM Data WHERE Data.lParentID = Main.lID"
            if let t = f.formatType {
                sql += " AND Data.strClipBoardFormat = ?"
                binds.append(.text(t))
            }
            sql += ") FROM Main WHERE Main.bIsGroup = 0 AND Main.isLocked = 0"
            if let t = f.titleContains, !t.isEmpty {
                sql += " AND Main.mText LIKE ? ESCAPE '\\'"
                binds.append(.text("%" + SearchQuery.escapeLike(t) + "%"))
            }
            if let d = f.createdFrom { sql += " AND Main.lDate >= ?"; binds.append(.int(Self.seconds(d))) }
            if let d = f.createdTo { sql += " AND Main.lDate <= ?"; binds.append(.int(Self.seconds(d))) }
            if let d = f.usedFrom { sql += " AND Main.lastPasteDate >= ?"; binds.append(.int(Self.seconds(d))) }
            if let d = f.usedTo { sql += " AND Main.lastPasteDate <= ?"; binds.append(.int(Self.seconds(d))) }
            if let t = f.formatType {
                sql += " AND EXISTS (SELECT 1 FROM Data d WHERE d.lParentID = Main.lID AND d.strClipBoardFormat = ?)"
                binds.append(.text(t))
            }
            sql += " ORDER BY Main.clipOrder DESC"
            let st = try db.prepare(sql)
            try st.bind(binds)
            var out: [(clip: Clip, bytes: Int)] = []
            while try st.step() { out.append((readClip(st), st.int(Self.mainColumnCount))) }
            return out
        }
    }

    /// Deletes the given format types from the clips (clips left without formats are deleted);
    /// `types == nil` deletes the whole clips.
    public func deleteData(clipIDs: [Int64], types: [String]?) throws {
        try locked {
            try db.transaction {
                guard let types else { try _delete(clipIDs); return }
                var empty: [Int64] = []
                for id in clipIDs where try !rowIsLocked(id) {
                    for t in types {
                        try db.run("DELETE FROM Data WHERE lParentID = ? AND strClipBoardFormat = ?", [.int(id), .text(t)])
                    }
                    let remaining = try db.scalarInt("SELECT COUNT(*) FROM Data WHERE lParentID = ?", [.int(id)]) ?? 0
                    let isGroup = (try db.scalarInt("SELECT bIsGroup FROM Main WHERE lID = ?", [.int(id)]) ?? 0) != 0
                    if remaining == 0 && !isGroup { empty.append(id) } else { try recomputeCRC(id) }
                }
                if !empty.isEmpty { try _delete(empty) }
            }
        }
    }

    // MARK: - vault (locked clips)

    /// Locks clips with the session's `vaultKey` (throws `ClipStoreError.locked` when none is set).
    /// Groups and already-locked clips are skipped. Returns the number of clips locked.
    @discardableResult
    public func lock(ids: [Int64]) throws -> Int {
        try locked {
            guard let key = _vaultKey else { throw ClipStoreError.locked }
            return try _lock(ids, key: key)
        }
    }

    /// Locks clips with an explicit data key without unlocking the session (locking reveals nothing, so the
    /// app can lock with the Keychain-held key and no authentication prompt).
    @discardableResult
    public func lock(ids: [Int64], key: SymmetricKey) throws -> Int {
        try locked { try _lock(ids, key: key) }
    }

    private func _lock(_ ids: [Int64], key: SymmetricKey) throws -> Int {
        let n: Int = try db.transaction {
            var n = 0
            for id in ids {
                let st = try db.prepare("SELECT bIsGroup, isLocked, mText, QuickPasteText FROM Main WHERE lID = ?")
                try st.bind(1, id)
                guard try st.step(), st.int64(0) == 0, st.int64(1) == 0 else { continue }
                let description = st.string(2)
                let quickPaste = st.string(3)
                let rows = try db.prepare("SELECT lID, strClipBoardFormat, ooData FROM Data WHERE lParentID = ? AND encrypted = 0")
                try rows.bind(1, id)
                var plain: [(Int64, String, Data)] = []
                while try rows.step() { plain.append((rows.int64(0), rows.string(1), rows.data(2))) }
                for (rowID, type, data) in plain {
                    let sealed = try Vault.seal(data, key: key, aad: Vault.dataAAD(clipID: id, type: type))
                    try db.run("UPDATE Data SET ooData = ?, encrypted = 1 WHERE lID = ?", [.blob(sealed), .int(rowID)])
                }
                let blob = try Self.sealLockedText(description: description, quickPasteText: quickPaste, key: key, clipID: id)
                try db.run("UPDATE Main SET isLocked = 1, lockedText = ?, mText = ?, QuickPasteText = ?, CRC = ? WHERE lID = ?",
                           [.blob(blob), .text(Self.lockedPlaceholder), .text(""), .int(Self.randomCRC()), .int(id)])
                n += 1
            }
            return n
        }
        if n > 0 { checkpointQuietly() }
        return n
    }

    /// Permanently removes the lock: decrypts formats and text back to their original form (CRC recomputed).
    /// Needs `vaultKey`; throws `ClipStoreError.decryptionFailed` (and changes nothing) if any blob fails to open.
    @discardableResult
    public func removeLock(ids: [Int64]) throws -> Int {
        try locked {
            guard let key = _vaultKey else { throw ClipStoreError.locked }
            return try db.transaction {
                var n = 0
                for id in ids where try rowIsLocked(id) {
                    let rows = try db.prepare("SELECT lID, strClipBoardFormat, ooData FROM Data WHERE lParentID = ? AND encrypted = 1")
                    try rows.bind(1, id)
                    var sealed: [(Int64, String, Data)] = []
                    while try rows.step() { sealed.append((rows.int64(0), rows.string(1), rows.data(2))) }
                    for (rowID, type, blob) in sealed {
                        guard let plain = try? Vault.open(blob, key: key, aad: Vault.dataAAD(clipID: id, type: type)) else {
                            throw ClipStoreError.decryptionFailed
                        }
                        try db.run("UPDATE Data SET ooData = ?, encrypted = 0 WHERE lID = ?", [.blob(plain), .int(rowID)])
                    }
                    guard let text = Self.openLockedText(try lockedTextBlob(id), key: key, clipID: id) else {
                        throw ClipStoreError.decryptionFailed
                    }
                    try db.run("UPDATE Main SET isLocked = 0, lockedText = NULL, mText = ?, QuickPasteText = ? WHERE lID = ?",
                               [.text(text.description), .text(text.quickPasteText), .int(id)])
                    try recomputeCRC(id)
                    n += 1
                }
                return n
            }
        }
    }

    public func lockedCount() throws -> Int {
        try locked { Int(try db.scalarInt("SELECT COUNT(*) FROM Main WHERE isLocked = 1") ?? 0) }
    }

    /// Ids of all locked clips.
    public func lockedIDs() throws -> [Int64] {
        try locked {
            let st = try db.prepare("SELECT lID FROM Main WHERE isLocked = 1 ORDER BY lID")
            var out: [Int64] = []
            while try st.step() { out.append(st.int64(0)) }
            return out
        }
    }

    /// Deliberate deletion that may include locked clips. Needs an unlocked session (`vaultKey` set),
    /// otherwise throws `ClipStoreError.locked`. Returns the number of rows deleted.
    @discardableResult
    public func deleteLocked(ids: [Int64]) throws -> Int {
        try locked {
            guard _vaultKey != nil else { throw ClipStoreError.locked }
            return try db.transaction { try _delete(ids, includeLocked: true) }
        }
    }

    /// Vault reset (forgotten password / lost key): permanently deletes every locked clip without needing
    /// the key. The app must confirm with the user first. Returns the number of clips deleted.
    @discardableResult
    public func purgeLockedClips() throws -> Int {
        let n: Int = try locked {
            try db.transaction {
                let n = try db.run("DELETE FROM Main WHERE isLocked = 1")
                try db.run("DELETE FROM Data WHERE lParentID NOT IN (SELECT lID FROM Main)")
                try cleanCopyBuffers()
                return n
            }
        }
        locked { checkpointQuietly() }
        return n
    }
}
