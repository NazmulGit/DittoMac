// Thin wrapper over the system SQLite3 C API.
//
// Security invariant: values are only ever passed to SQLite through `bind`.
// `exec` is reserved for constant DDL / PRAGMA / transaction-control strings.

import Foundation
import SQLite3

/// SQLITE_TRANSIENT tells SQLite to copy bound buffers before `bind_*` returns.
let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible, Equatable {
    public var code: Int32
    public var message: String
    public init(code: Int32, message: String) { self.code = code; self.message = message }
    public var description: String { "SQLite error \(code): \(message)" }
}

/// One SQLite connection. Opened with SQLITE_OPEN_FULLMUTEX; callers (ClipStore) add their own lock
/// so that multi-statement operations are atomic.
final class SQLiteDatabase {
    private(set) var handle: OpaquePointer?
    private var regexCache: RegexCache?

    init(path: String, readOnly: Bool = false) throws {
        var flags = SQLITE_OPEN_FULLMUTEX
        flags |= readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: rc, message: msg)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 5000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// Settings for a database file that came from outside (imports): schema objects may not call
    /// functions with side effects, nothing can be written, corrupt cells are detected, no mmap.
    func hardenForUntrustedInput() throws {
        try exec("PRAGMA trusted_schema = OFF")
        try exec("PRAGMA query_only = ON")
        try exec("PRAGMA cell_size_check = ON")
        try exec("PRAGMA mmap_size = 0")
    }

    /// The `type` column of sqlite_master for `name` ("table", "view", …), nil when absent.
    func schemaType(of name: String) throws -> String? {
        let st = try prepare("SELECT type FROM sqlite_master WHERE name = ? COLLATE NOCASE LIMIT 1")
        try st.bind(1, name)
        return try st.step() ? st.string(0) : nil
    }

    var lastErrorMessage: String {
        guard let handle else { return "closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    func error(_ code: Int32) -> SQLiteError { SQLiteError(code: code, message: lastErrorMessage) }

    /// Executes constant SQL (DDL, PRAGMA, transaction control). Never pass user data here.
    func exec(_ sql: StaticString) throws {
        let rc = sql.withUTF8Buffer { buf -> Int32 in
            let s = String(decoding: buf, as: UTF8.self)
            return sqlite3_exec(handle, s, nil, nil, nil)
        }
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(db: self, sql: sql)
    }

    /// Prepare, bind, and run a statement that returns no rows. Returns sqlite3_changes.
    @discardableResult
    func run(_ sql: String, _ binds: [SQLiteValue] = []) throws -> Int {
        let st = try prepare(sql)
        try st.bind(binds)
        while try st.step() {}
        return changes
    }

    /// Runs `sql` and returns the first column of the first row as Int64 (nil if no row / NULL).
    func scalarInt(_ sql: String, _ binds: [SQLiteValue] = []) throws -> Int64? {
        let st = try prepare(sql)
        try st.bind(binds)
        guard try st.step(), !st.isNull(0) else { return nil }
        return st.int64(0)
    }

    func scalarDouble(_ sql: String, _ binds: [SQLiteValue] = []) throws -> Double? {
        let st = try prepare(sql)
        try st.bind(binds)
        guard try st.step(), !st.isNull(0) else { return nil }
        return st.double(0)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    /// Runs `body` inside a SAVEPOINT (nests safely). Rolls back on throw.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("SAVEPOINT ditto_tx")
        do {
            let result = try body()
            try exec("RELEASE ditto_tx")
            return result
        } catch {
            try? exec("ROLLBACK TO ditto_tx")
            try? exec("RELEASE ditto_tx")
            throw error
        }
    }

    // MARK: REGEXP

    /// Registers `regexp(pattern, value)` so that `value REGEXP pattern` works.
    /// Patterns are compiled with NSRegularExpression and cached; input is capped at 100k UTF-16 units;
    /// an invalid pattern evaluates to false.
    func registerRegexpFunction() throws {
        let cache = RegexCache()
        regexCache = cache
        let ctxPtr = Unmanaged.passUnretained(cache).toOpaque()
        let rc = sqlite3_create_function_v2(
            handle, "regexp", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, ctxPtr,
            { ctx, argc, argv in
                guard let ctx, argc == 2, let argv,
                      let raw = sqlite3_user_data(ctx) else { sqlite3_result_int(ctx, 0); return }
                let cache = Unmanaged<RegexCache>.fromOpaque(raw).takeUnretainedValue()
                guard let pv = argv[0], let vv = argv[1],
                      sqlite3_value_type(pv) != SQLITE_NULL, sqlite3_value_type(vv) != SQLITE_NULL,
                      let pc = sqlite3_value_text(pv), let vc = sqlite3_value_text(vv) else {
                    sqlite3_result_int(ctx, 0); return
                }
                let pattern = String(decoding: UnsafeBufferPointer(start: pc, count: Int(sqlite3_value_bytes(pv))), as: UTF8.self)
                let value = String(decoding: UnsafeBufferPointer(start: vc, count: Int(sqlite3_value_bytes(vv))), as: UTF8.self)
                sqlite3_result_int(ctx, cache.matches(pattern: pattern, value: value) ? 1 : 0)
            }, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }
}

/// Small bounded cache of compiled regular expressions. Thread-safe.
final class RegexCache: @unchecked Sendable {
    static let maxInputUTF16 = 100_000
    private static let maxEntries = 32
    private let lock = NSLock()
    private var compiled: [String: NSRegularExpression?] = [:]

    func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock(); defer { lock.unlock() }
        if let hit = compiled[pattern] { return hit }
        if compiled.count >= Self.maxEntries { compiled.removeAll(keepingCapacity: true) }
        let re = try? NSRegularExpression(pattern: pattern, options: [])
        compiled[pattern] = .some(re)
        return re
    }

    func matches(pattern: String, value: String) -> Bool {
        guard let re = regex(pattern) else { return false }
        let ns = value as NSString
        let length = min(ns.length, Self.maxInputUTF16)
        return re.firstMatch(in: value, options: [], range: NSRange(location: 0, length: length)) != nil
    }
}

enum SQLiteValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

final class SQLiteStatement {
    private(set) var stmt: OpaquePointer?
    private let db: SQLiteDatabase

    init(db: SQLiteDatabase, sql: String) throws {
        self.db = db
        var s: OpaquePointer?
        let rc = sqlite3_prepare_v2(db.handle, sql, -1, &s, nil)
        guard rc == SQLITE_OK, let s else {
            if let s { sqlite3_finalize(s) }
            throw db.error(rc)
        }
        stmt = s
    }

    deinit { sqlite3_finalize(stmt) }

    private func check(_ rc: Int32) throws {
        guard rc == SQLITE_OK else { throw db.error(rc) }
    }

    // MARK: bind (1-based index)

    func bind(_ index: Int32, _ value: Int64) throws { try check(sqlite3_bind_int64(stmt, index, value)) }
    func bind(_ index: Int32, _ value: Int) throws { try bind(index, Int64(value)) }
    func bind(_ index: Int32, _ value: Double) throws { try check(sqlite3_bind_double(stmt, index, value)) }
    func bindNull(_ index: Int32) throws { try check(sqlite3_bind_null(stmt, index)) }

    func bind(_ index: Int32, _ value: String) throws {
        var s = value
        let rc: Int32 = s.withUTF8 { buf in
            guard let base = buf.baseAddress, buf.count > 0 else {
                return sqlite3_bind_text(stmt, index, "", 0, sqliteTransient)
            }
            return base.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                sqlite3_bind_text(stmt, index, $0, Int32(buf.count), sqliteTransient)
            }
        }
        try check(rc)
    }

    func bind(_ index: Int32, _ value: Data) throws {
        let rc: Int32 = value.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else {
                return sqlite3_bind_zeroblob(stmt, index, 0)
            }
            return sqlite3_bind_blob(stmt, index, base, Int32(raw.count), sqliteTransient)
        }
        try check(rc)
    }

    func bind(_ index: Int32, _ value: SQLiteValue) throws {
        switch value {
        case .int(let v): try bind(index, v)
        case .double(let v): try bind(index, v)
        case .text(let v): try bind(index, v)
        case .blob(let v): try bind(index, v)
        case .null: try bindNull(index)
        }
    }

    func bind(_ values: [SQLiteValue]) throws {
        for (i, v) in values.enumerated() { try bind(Int32(i + 1), v) }
    }

    func reset() {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
    }

    /// Returns true when a row is available, false when done.
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw db.error(rc)
        }
    }

    // MARK: columns (0-based index)

    var columnCount: Int32 { sqlite3_column_count(stmt) }
    func columnName(_ i: Int32) -> String { sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "" }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }

    func string(_ i: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, i) else { return "" }
        let n = Int(sqlite3_column_bytes(stmt, i))
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }

    func data(_ i: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
        let n = Int(sqlite3_column_bytes(stmt, i))
        return Data(bytes: p, count: n)
    }
}
