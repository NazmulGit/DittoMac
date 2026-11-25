// SyncEngine.swift — folder-based, end-to-end-encrypted clip sync and backup (v1.2). See docs/kb/sync.md.
//
// Pure logic: Foundation, CryptoKit, CommonCrypto and Compression only (no AppKit, no network, no provider APIs).
// The app layer (SyncService) owns timers, the Keychain and UI and calls this API on a background queue.
//
//  .dmsync container : "DMSYNC1" | version u8 | PBKDF2 iterations u32 BE | salt[16] | nonce[12] | AES-256-GCM(ciphertext|tag)
//                      The 40-byte header is the GCM AAD. Plaintext = zlib(JSON(SyncSnapshot)).
//  Key               : PBKDF2-HMAC-SHA256(passphrase NFC/UTF-8, salt, iterations); the READ side only accepts
//                      100_000...2_000_000 iterations (checked before any key derivation).
//  Hostile input     : every field of a snapshot is validated (`SyncValidator`); counts, string lengths, UTI
//                      charset, per-format and total sizes, dates. No path or URL is ever taken from a snapshot.
//  Threading         : `SyncEngine` serialises its operations with a lock; ClipStore is thread-safe. Call from a
//                      background queue (hashing, compression and PBKDF2 are slow).
//  Errors            : never contain the passphrase or key material.

import Foundation
import CryptoKit
import CommonCrypto
import Compression

// MARK: - Limits, errors, options

public enum SyncLimits {
    public static let magic = Data("DMSYNC1".utf8)
    public static let version: UInt8 = 1
    public static let headerLength = 7 + 1 + 4 + 16 + 12            // 40
    public static let tagLength = 16
    public static let minIterations = 100_000
    public static let maxIterations = 2_000_000
    public static let defaultIterations = 600_000
    public static let maxCiphertextBytes = 256 * 1024 * 1024
    public static let maxDecompressedBytes = 256 * 1024 * 1024
    public static let maxClips = 20_000                              // hard read-side cap
    public static let maxGroups = 5_000
    public static let maxFormatsPerClip = 32
    public static let maxFormatBytes = 16 * 1024 * 1024
    public static let maxTextChars = 100_000
    public static let maxNameChars = 256
    public static let maxDeviceNameChars = 64
    public static let maxTypeChars = 128
    public static let maxGroupDepth = 32
    public static let minPassphraseLength = 12
    public static let tombstoneTTL: TimeInterval = 90 * 86_400
    /// Dates before this (1990-01-01) are not plausible clipboard history.
    static let earliestDate: Double = 631_152_000
}

public enum SyncError: Error, LocalizedError, Equatable {
    case notASnapshot
    case unsupportedVersion(Int)
    case badIterations
    case tooLarge
    case wrongPassphraseOrCorrupt
    case malformed(String)
    case passphraseTooShort
    case folderMissing(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notASnapshot: return "Not a DittoMac sync file."
        case .unsupportedVersion(let v): return "Unsupported sync file version \(v)."
        case .badIterations: return "The sync file asks for an unsafe key-derivation setting and was rejected."
        case .tooLarge: return "The sync file is larger than the allowed limit."
        case .wrongPassphraseOrCorrupt: return "Wrong sync passphrase, or the file is damaged."
        case .malformed(let m): return "The sync file is malformed (\(m))."
        case .passphraseTooShort: return "The sync passphrase must be at least \(SyncLimits.minPassphraseLength) characters."
        case .folderMissing(let p): return "The sync folder is not available: \(p)"
        case .io(let m): return m
        }
    }
}

public struct SyncOptions: Sendable, Equatable {
    public var includeImages = true
    public var includeRichFormats = true
    public var maxTotalBytes = 150 * 1024 * 1024
    public var perFormatBytes = 16 * 1024 * 1024
    public var maxClips = 5000
    public init() {}
}

// MARK: - Snapshot model

public struct SyncFormat: Codable, Equatable, Sendable {
    public var type: String
    public var data: Data          // JSON key "base64", base64 text
    enum CodingKeys: String, CodingKey { case type, data = "base64" }
    public init(type: String, data: Data) { self.type = type; self.data = data }
}

public struct SyncGroup: Codable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public var parentUID: String?
    public init(uid: String, name: String, parentUID: String? = nil) { self.uid = uid; self.name = name; self.parentUID = parentUID }
}

public struct SyncClip: Codable, Equatable, Sendable {
    public var contentHash: String
    public var date: Double
    public var lastPasteDate: Double
    public var description: String
    public var quickPasteText: String
    public var neverAutoDelete: Bool
    public var stickyTop: Bool
    public var stickyLast: Bool
    public var groupUID: String?
    public var formats: [SyncFormat]
    public init(contentHash: String, date: Double, lastPasteDate: Double, description: String, quickPasteText: String = "",
                neverAutoDelete: Bool = false, stickyTop: Bool = false, stickyLast: Bool = false,
                groupUID: String? = nil, formats: [SyncFormat]) {
        self.contentHash = contentHash; self.date = date; self.lastPasteDate = lastPasteDate
        self.description = description; self.quickPasteText = quickPasteText; self.neverAutoDelete = neverAutoDelete
        self.stickyTop = stickyTop; self.stickyLast = stickyLast; self.groupUID = groupUID; self.formats = formats
    }
}

public struct SyncSnapshot: Codable, Equatable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var createdAt: Double
    public var groups: [SyncGroup]
    public var clips: [SyncClip]
    public init(deviceID: String, deviceName: String, createdAt: Double, groups: [SyncGroup] = [], clips: [SyncClip] = []) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.createdAt = createdAt
        self.groups = groups; self.clips = clips
    }
}

// MARK: - Small helpers

enum SyncUtil {
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef")
        var s = ""
        for b in bytes { s.append(digits[Int(b >> 4)]); s.append(digits[Int(b & 15)]) }
        return s
    }
    static func random(_ n: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    }
    static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]) }
    static func isHash(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
    /// Removes control characters (incl. NUL) and trims; truncates to `max` characters.
    static func cleanText(_ s: String, max: Int, keepNewlines: Bool = true) -> String {
        var out = String.UnicodeScalarView()
        var n = 0
        for u in s.unicodeScalars {
            if n >= max { break }
            if u.value < 0x20 {
                if keepNewlines, u == "\n" || u == "\t" || u == "\r" { out.append(u); n += 1 }
                continue
            }
            if u.value == 0x7F { continue }
            out.append(u); n += 1
        }
        return String(out)
    }
}

public enum SyncUTI {
    /// `[A-Za-z0-9.+_-]`, 1...128 characters.
    public static func isValid(_ t: String) -> Bool {
        let n = t.utf8.count
        guard n >= 1, n <= SyncLimits.maxTypeChars else { return false }
        return t.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 46 || $0 == 43 || $0 == 95 || $0 == 45
        }
    }
}

public enum SyncHash {
    /// SHA-256 hex over the clip's formats: each format is digested as SHA256(type | 0x00 | data); the digests are
    /// sorted and hashed again, so the result is independent of format order and of the local database ids.
    public static func contentHash(_ formats: [ClipFormat]) -> String {
        contentHash(formats.map { ($0.type, $0.data) })
    }
    public static func contentHash(_ formats: [(String, Data)]) -> String {
        var digests: [String] = []
        digests.reserveCapacity(formats.count)
        for (t, d) in formats {
            var h = SHA256()
            h.update(data: Data(t.utf8)); h.update(data: Data([0])); h.update(data: d)
            digests.append(SyncUtil.hex(h.finalize()))
        }
        digests.sort()
        var h = SHA256()
        for d in digests { h.update(data: Data(d.utf8)) }
        return SyncUtil.hex(h.finalize())
    }
}

// MARK: - zlib (Apple Compression framework, streaming with an output cap)

enum SyncZlib {
    static func compress(_ input: Data) throws -> Data {
        try run(COMPRESSION_STREAM_ENCODE, input, maxOutput: Int.max)
    }
    static func decompress(_ input: Data, maxOutput: Int) throws -> Data {
        try run(COMPRESSION_STREAM_DECODE, input, maxOutput: maxOutput)
    }

    private static func run(_ op: compression_stream_operation, _ input: Data, maxOutput: Int) throws -> Data {
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: chunk, src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, op, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw SyncError.io("Compression is unavailable.")
        }
        defer { compression_stream_destroy(&stream) }
        var out = Data()
        var failure: SyncError?
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            stream.src_ptr = base.map { UnsafePointer($0) } ?? UnsafePointer(dst)
            stream.src_size = input.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                if produced > 0 {
                    if out.count + produced > maxOutput { failure = .tooLarge; return }
                    out.append(dst, count: produced)
                }
                if status == COMPRESSION_STATUS_END { return }
                if status == COMPRESSION_STATUS_ERROR { failure = .malformed("bad compressed data"); return }
                if produced == 0 && stream.src_size == 0 { failure = .malformed("truncated compressed data"); return }
            }
        }
        if let failure { throw failure }
        return out
    }
}

// MARK: - Key derivation (PBKDF2, cached)

enum SyncKDF {
    private static let lock = NSLock()
    private static var cache: [String: SymmetricKey] = [:]

    static func normalise(_ passphrase: String) -> String { passphrase.precomposedStringWithCanonicalMapping }

    /// Derived keys are cached per (passphrase, salt, iterations) so reading the same peer file repeatedly is cheap.
    static func key(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard iterations >= SyncLimits.minIterations, iterations <= SyncLimits.maxIterations else { throw SyncError.badIterations }
        let pw = normalise(passphrase)
        let id = SyncUtil.hex(SHA256.hash(data: Data(pw.utf8))) + ":" + SyncUtil.hex(salt) + ":\(iterations)"
        lock.lock()
        if let k = cache[id] { lock.unlock(); return k }
        lock.unlock()
        let k = derive(pw, salt: salt, iterations: iterations)
        lock.lock()
        if cache.count >= 8 { cache.removeAll() }
        cache[id] = k
        lock.unlock()
        return k
    }

    static func clearCache() { lock.lock(); cache.removeAll(); lock.unlock() }

    private static func derive(_ pw: String, salt: Data, iterations: Int) -> SymmetricKey {
        let pwBytes = pw.utf8.map { Int8(bitPattern: $0) }
        let saltBytes = [UInt8](salt)
        var out = [UInt8](repeating: 0, count: 32)
        let status = pwBytes.withUnsafeBufferPointer { p in
            saltBytes.withUnsafeBufferPointer { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress, pwBytes.count, s.baseAddress, saltBytes.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &out, out.count)
            }
        }
        precondition(status == Int32(kCCSuccess), "PBKDF2 failed")
        let key = SymmetricKey(data: out)
        for i in out.indices { out[i] = 0 }
        return key
    }
}

// MARK: - Codec

public enum SyncCodec {
    public struct Header: Equatable, Sendable {
        public var version: Int
        public var iterations: Int
        public var salt: Data
        public var nonce: Data
    }

    /// Parses and range-checks the header. Rejects before any key derivation.
    public static func parseHeader(_ data: Data) throws -> Header {
        guard data.count >= SyncLimits.headerLength + SyncLimits.tagLength else { throw SyncError.notASnapshot }
        let b = data.startIndex
        guard data.subdata(in: b..<(b + 7)) == SyncLimits.magic else { throw SyncError.notASnapshot }
        let version = Int(data[b + 7])
        guard version == Int(SyncLimits.version) else { throw SyncError.unsupportedVersion(version) }
        let iters = (UInt32(data[b + 8]) << 24) | (UInt32(data[b + 9]) << 16) | (UInt32(data[b + 10]) << 8) | UInt32(data[b + 11])
        guard iters >= UInt32(SyncLimits.minIterations), iters <= UInt32(SyncLimits.maxIterations) else { throw SyncError.badIterations }
        guard data.count - SyncLimits.headerLength <= SyncLimits.maxCiphertextBytes + SyncLimits.tagLength else { throw SyncError.tooLarge }
        return Header(version: version, iterations: Int(iters),
                      salt: data.subdata(in: (b + 12)..<(b + 28)), nonce: data.subdata(in: (b + 28)..<(b + 40)))
    }

    /// Encrypts a snapshot. `salt` may be reused by one device across pushes (fresh random nonce every time).
    public static func seal(_ snapshot: SyncSnapshot, passphrase: String,
                            iterations: Int = SyncLimits.defaultIterations, salt: Data? = nil) throws -> Data {
        guard passphrase.count >= SyncLimits.minPassphraseLength else { throw SyncError.passphraseTooShort }
        guard iterations >= SyncLimits.minIterations, iterations <= SyncLimits.maxIterations else { throw SyncError.badIterations }
        let json: Data
        do { json = try JSONEncoder().encode(snapshot) } catch { throw SyncError.io("Could not encode the snapshot.") }
        let compressed = try SyncZlib.compress(json)
        guard compressed.count <= SyncLimits.maxCiphertextBytes else { throw SyncError.tooLarge }
        let salt = (salt?.count == 16) ? salt! : SyncUtil.random(16)
        let nonceData = SyncUtil.random(12)
        var header = SyncLimits.magic
        header.append(SyncLimits.version)
        header.append(SyncUtil.be32(UInt32(iterations)))
        header.append(salt)
        header.append(nonceData)
        let key = try SyncKDF.key(passphrase: passphrase, salt: salt, iterations: iterations)
        do {
            let box = try AES.GCM.seal(compressed, using: key, nonce: try AES.GCM.Nonce(data: nonceData), authenticating: header)
            return header + box.ciphertext + box.tag
        } catch { throw SyncError.io("Encryption failed.") }
    }

    /// Decrypts, decompresses (capped) and validates a `.dmsync` file. Never traps on hostile input.
    public static func open(_ data: Data, passphrase: String,
                            maxDecompressedBytes: Int = SyncLimits.maxDecompressedBytes,
                            now: Date = Date()) throws -> SyncSnapshot {
        let h = try parseHeader(data)
        guard passphrase.count >= SyncLimits.minPassphraseLength else { throw SyncError.passphraseTooShort }
        let b = data.startIndex
        let header = data.subdata(in: b..<(b + SyncLimits.headerLength))
        let body = data.subdata(in: (b + SyncLimits.headerLength)..<data.endIndex)
        let tagStart = body.endIndex - SyncLimits.tagLength
        let key = try SyncKDF.key(passphrase: passphrase, salt: h.salt, iterations: h.iterations)
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: h.nonce),
                                            ciphertext: body.subdata(in: body.startIndex..<tagStart),
                                            tag: body.subdata(in: tagStart..<body.endIndex))
            plain = try AES.GCM.open(box, using: key, authenticating: header)
        } catch { throw SyncError.wrongPassphraseOrCorrupt }
        let json = try SyncZlib.decompress(plain, maxOutput: maxDecompressedBytes)
        let snap: SyncSnapshot
        do { snap = try JSONDecoder().decode(SyncSnapshot.self, from: json) } catch { throw SyncError.malformed("unreadable contents") }
        return try SyncValidator.sanitize(snap, now: now)
    }
}

// MARK: - Validation

public enum SyncValidator {
    /// Returns a copy that is safe to import: invalid clips/groups are dropped, text is cleaned and truncated,
    /// dates are clamped. Throws only for structural problems (too many items, bad device id).
    public static func sanitize(_ s: SyncSnapshot, now: Date = Date(), perFormatBytes: Int = SyncLimits.maxFormatBytes) throws -> SyncSnapshot {
        guard s.clips.count <= SyncLimits.maxClips else { throw SyncError.malformed("too many clips") }
        guard s.groups.count <= SyncLimits.maxGroups else { throw SyncError.malformed("too many groups") }
        guard let uuid = UUID(uuidString: s.deviceID) else { throw SyncError.malformed("bad device id") }
        let maxDate = now.timeIntervalSince1970 + 2 * 86_400
        func clampDate(_ d: Double, fallback: Double) -> Double {
            guard d.isFinite, d >= SyncLimits.earliestDate else { return fallback }
            return min(d, maxDate)
        }
        var out = SyncSnapshot(deviceID: uuid.uuidString,
                               deviceName: SyncUtil.cleanText(s.deviceName, max: SyncLimits.maxDeviceNameChars, keepNewlines: false),
                               createdAt: clampDate(s.createdAt, fallback: now.timeIntervalSince1970))
        func validUID(_ u: String) -> Bool {
            let n = u.utf8.count
            return n >= 1 && n <= 64 && u.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 || $0 == 46
            }
        }
        // groups
        var byUID: [String: SyncGroup] = [:]
        for g in s.groups where validUID(g.uid) && byUID[g.uid] == nil {
            let name = SyncUtil.cleanText(g.name, max: SyncLimits.maxNameChars, keepNewlines: false)
            guard !name.isEmpty else { continue }
            byUID[g.uid] = SyncGroup(uid: g.uid, name: name, parentUID: g.parentUID)
        }
        for (uid, g) in byUID {
            guard let p = g.parentUID else { continue }
            var cur: String? = p, depth = 0, ok = byUID[p] != nil
            while ok, let c = cur {
                depth += 1
                if c == uid || depth > SyncLimits.maxGroupDepth { ok = false; break }
                cur = byUID[c]?.parentUID
            }
            if !ok { byUID[uid]?.parentUID = nil }
        }
        var added = Set<String>()
        for g in s.groups { if let v = byUID[g.uid], added.insert(g.uid).inserted { out.groups.append(v) } }
        // clips
        var seen = Set<String>()
        for c in s.clips {
            guard SyncUtil.isHash(c.contentHash), seen.insert(c.contentHash).inserted else { continue }
            var formats: [SyncFormat] = []
            for f in c.formats.prefix(SyncLimits.maxFormatsPerClip) {
                guard SyncUTI.isValid(f.type), !f.data.isEmpty, f.data.count <= min(perFormatBytes, SyncLimits.maxFormatBytes) else { continue }
                formats.append(f)
            }
            guard !formats.isEmpty else { seen.remove(c.contentHash); continue }
            let date = clampDate(c.date, fallback: now.timeIntervalSince1970)
            var gid = c.groupUID
            if let g = gid, byUID[g] == nil { gid = nil }
            out.clips.append(SyncClip(
                contentHash: c.contentHash, date: date,
                lastPasteDate: max(date, clampDate(c.lastPasteDate, fallback: date)),
                description: SyncUtil.cleanText(c.description, max: SyncLimits.maxTextChars),
                quickPasteText: SyncUtil.cleanText(c.quickPasteText, max: SyncLimits.maxTextChars),
                neverAutoDelete: c.neverAutoDelete, stickyTop: c.stickyTop, stickyLast: c.stickyLast && !c.stickyTop,
                groupUID: gid, formats: formats))
        }
        return out
    }
}

// MARK: - Persistent state (index, hash cache, tombstones)

struct SyncImportedEntry: Codable, Equatable { var hash: String; var crc: Int }
struct SyncCacheEntry: Codable, Equatable { var crc: Int; var date: Double; var hash: String }

struct SyncIndexFile: Codable {
    var index: [String: Int64] = [:]                 // content hash -> local clip id
    var imported: [String: SyncImportedEntry] = [:]  // local id (as text) -> declared hash + crc at import time
    var cache: [String: SyncCacheEntry] = [:]        // local id (as text) -> content hash cache keyed by crc/date
    var lastPushDigest: String?
    var lastPushCount: Int?
}

struct SyncTombstoneFile: Codable {
    var tombstones: [String: Double] = [:]           // content hash -> unix time the user's clip disappeared
}

enum SyncStateIO {
    static let maxFileBytes = 64 * 1024 * 1024
    static func load<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        guard let url, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size <= maxFileBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }
}

// MARK: - Cloud folder

public struct SyncDeviceFile: Sendable, Equatable {
    public var name: String
    public var deviceID: String
    public var url: URL
    public var size: Int64
    public var modified: Date
}

public struct SyncFolder: Sendable {
    public static let directoryName = "DittoMac Sync"
    public static let fileExtension = "dmsync"
    /// The folder DittoMac reads and writes (`<chosen folder>/DittoMac Sync`).
    public let url: URL

    public init(directory: URL) { url = directory }

    /// `base` is the folder the user picked (it must already exist). The "DittoMac Sync" sub-folder is created (0700).
    public static func open(baseFolder base: URL, create: Bool = true) throws -> SyncFolder {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: base.path, isDirectory: &isDir), isDir.boolValue else {
            throw SyncError.folderMissing(base.path)
        }
        let dir = base.lastPathComponent == directoryName ? base : base.appendingPathComponent(directoryName, isDirectory: true)
        // Never follow a symlink planted as "DittoMac Sync" (it could redirect our writes outside the cloud folder).
        if (try? fm.destinationOfSymbolicLink(atPath: dir.path)) != nil {
            throw SyncError.io("“\(directoryName)” is a symbolic link; DittoMac only uses a real folder.")
        }
        if !fm.fileExists(atPath: dir.path, isDirectory: &isDir) {
            guard create else { throw SyncError.folderMissing(dir.path) }
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { throw SyncError.io("Could not create the DittoMac Sync folder: \(error.localizedDescription)") }
        } else if !isDir.boolValue {
            throw SyncError.io("A file named “\(directoryName)” is in the way.")
        }
        return SyncFolder(directory: dir)
    }

    static let deviceFilePattern = try! NSRegularExpression(
        pattern: "^device-([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\\.dmsync$")

    public static func deviceFileName(_ deviceID: String) -> String { "device-\(deviceID.uppercased()).dmsync" }

    public func deviceFiles() -> [SyncDeviceFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        var out: [SyncDeviceFile] = []
        for u in items {
            let name = u.lastPathComponent
            let r = NSRange(name.startIndex..., in: name)
            guard let m = Self.deviceFilePattern.firstMatch(in: name, range: r), let idr = Range(m.range(at: 1), in: name),
                  let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true
            else { continue }
            out.append(SyncDeviceFile(name: name, deviceID: String(name[idr]).uppercased(), url: u,
                                      size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Atomic write: temp file in the same folder (0600), fsync, then rename over the destination.
    public func write(_ data: Data, named name: String) throws {
        guard !name.contains("/"), !name.hasPrefix("."), name.hasSuffix("." + Self.fileExtension) else { throw SyncError.io("Bad file name.") }
        let dest = url.appendingPathComponent(name)
        let tmp = url.appendingPathComponent(".tmp-" + UUID().uuidString)
        let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SyncError.io("Could not write to the sync folder (errno \(errno)).") }
        var ok = true
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { ok = false; break }
                off += n
            }
        }
        if ok { ok = fsync(fd) == 0 }
        Darwin.close(fd)
        guard ok, Darwin.rename(tmp.path, dest.path) == 0 else {
            let e = errno
            unlink(tmp.path)
            throw SyncError.io("Could not write to the sync folder (errno \(e)).")
        }
        chmod(dest.path, 0o600)
    }

    /// Reads a file with a size cap; refuses symlinks and non-regular files. The checks are made on the opened
    /// descriptor (O_NOFOLLOW + fstat) and the read itself is capped, so swapping the file for a symlink or growing
    /// it after the check can't make us follow a link or read past the limit.
    public static func readLimited(_ fileURL: URL) throws -> Data {
        let cap = SyncLimits.maxCiphertextBytes + SyncLimits.headerLength + SyncLimits.tagLength
        let fd = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SyncError.io(errno == ELOOP ? "Not a regular file." : "Could not read the file.") }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw SyncError.io("Not a regular file.") }
        guard st.st_size >= 0, st.st_size <= off_t(cap) else { throw SyncError.tooLarge }
        var out = Data()
        out.reserveCapacity(Int(st.st_size))
        let chunk = 1 << 20
        var buf = [UInt8](repeating: 0, count: chunk)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, chunk) }
            if n < 0 { if errno == EINTR { continue }; throw SyncError.io("Could not read the file.") }
            if n == 0 { break }
            guard out.count + n <= cap else { throw SyncError.tooLarge }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }
}

// MARK: - Reports

public struct SyncDeviceInfo: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable { case ok, thisDevice, wrongPassphrase, unreadable }
    public var id: String { fileName }
    public var fileName: String
    public var deviceID: String
    public var deviceName: String?
    public var modified: Date
    public var sizeBytes: Int64
    public var clipCount: Int?
    public var status: Status
    public var isThisDevice: Bool { status == .thisDevice }
}

public struct MergeSummary: Sendable, Equatable {
    public var imported = 0
    public var alreadyPresent = 0
    public var tombstoned = 0
    public var limited = 0
    public var groupsCreated = 0
    public init() {}
}

public struct SyncReport: Sendable {
    public var pushed = false
    public var pushSkippedUnchanged = false
    public var merge = MergeSummary()
    public var devices: [SyncDeviceInfo] = []
    public var backupFile: String?
    /// Set when the run could not do its job (folder missing, write failed). Never contains secrets.
    public var hardError: String?
    public var warnings: [String] = []
    public init() {}
}

public enum SyncPullMode: Sendable { case none, changedOnly, all }

public struct SyncRunRequest: Sendable {
    public var pull: SyncPullMode = .changedOnly
    public var push = true
    public var backupKeep: Int?           // nil = backups off
    public var deviceName = "Mac"
    public var options = SyncOptions()
    public var iterations = SyncLimits.defaultIterations
    public var maxNewClips: Int?          // cap on clips imported per run
    public init() {}
}

// MARK: - Engine

public final class SyncEngine: @unchecked Sendable {
    public static let indexFileName = "sync-index.json"
    public static let tombstoneFileName = "sync-tombstones.json"

    public let store: ClipStore
    public let deviceID: String
    private let indexURL: URL?
    private let tombstoneURL: URL?
    private let lock = NSLock()
    private var st: SyncIndexFile
    private var tomb: SyncTombstoneFile
    private var salt = SyncUtil.random(16)
    private struct Seen { var modified: Date; var size: Int64; var passKey: String; var retryAt: Date?; var info: SyncDeviceInfo }
    private var seen: [String: Seen] = [:]

    /// `stateDirectory` nil = keep state in memory only (tests).
    public init(store: ClipStore, stateDirectory: URL?, deviceID: String) {
        self.store = store
        self.deviceID = UUID(uuidString: deviceID)?.uuidString ?? deviceID.uppercased()
        indexURL = stateDirectory?.appendingPathComponent(Self.indexFileName)
        tombstoneURL = stateDirectory?.appendingPathComponent(Self.tombstoneFileName)
        st = SyncStateIO.load(SyncIndexFile.self, from: indexURL) ?? SyncIndexFile()
        tomb = SyncStateIO.load(SyncTombstoneFile.self, from: tombstoneURL) ?? SyncTombstoneFile()
    }

    private func saveState() {
        SyncStateIO.save(st, to: indexURL)
        SyncStateIO.save(tomb, to: tombstoneURL)
    }

    /// Forget which remote files were already read (call when the passphrase or folder changes).
    public func resetSeen() { lock.lock(); seen.removeAll(); lock.unlock() }

    // MARK: local scan

    struct Local { let clip: Clip; let hash: String }

    /// Hashes local clips (cached), maintains the hash→id index and records tombstones for clips that vanished.
    private func scan(now: Date) throws -> [Local] {
        let all = try store.clips(ClipFilter(parentID: nil, showAllClipsInMainList: true, showGroupsInMainList: false,
                                             search: nil, limit: 0))
        let present = Set(all.map(\.id))
        let t = now.timeIntervalSince1970
        for (hash, id) in st.index where !present.contains(id) {
            if try store.clip(id: id) == nil {
                tomb.tombstones[hash] = t
                st.index[hash] = nil
                st.imported[String(id)] = nil
                st.cache[String(id)] = nil
            }
        }
        var locals: [Local] = []
        for c in all where !c.isLocked && c.sourceApp != "copybuffer" {
            locals.append(Local(clip: c, hash: try hashFor(c)))
        }
        let presentKeys = Set(present.map { String($0) })
        if st.cache.count > present.count { st.cache = st.cache.filter { presentKeys.contains($0.key) } }
        if st.imported.count > present.count { st.imported = st.imported.filter { presentKeys.contains($0.key) } }
        for l in locals {
            if let id = st.index[l.hash], present.contains(id) {} else { st.index[l.hash] = l.clip.id }
            tomb.tombstones[l.hash] = nil
        }
        tomb.tombstones = tomb.tombstones.filter { t - $0.value <= SyncLimits.tombstoneTTL }
        saveState()
        locals.sort { $0.clip.date != $1.clip.date ? $0.clip.date > $1.clip.date : $0.clip.id > $1.clip.id }
        var seenHashes = Set<String>()
        return locals.filter { seenHashes.insert($0.hash).inserted }
    }

    private func hashFor(_ c: Clip) throws -> String {
        let key = String(c.id)
        if let imp = st.imported[key], imp.crc == Int(c.crc) { return imp.hash }
        if let e = st.cache[key], e.crc == Int(c.crc), e.date == c.date.timeIntervalSince1970 { return e.hash }
        let h = SyncHash.contentHash(try store.formats(clipID: c.id))
        st.cache[key] = SyncCacheEntry(crc: Int(c.crc), date: c.date.timeIntervalSince1970, hash: h)
        return h
    }

    // MARK: snapshot

    struct Item { let clip: Clip; let hash: String; let types: Set<String> }
    struct Plan { var items: [Item]; var groups: [Clip]; var digest: String }

    /// Pasteboard types that reference files on one Mac (or promise them). Never exported and never imported: a path
    /// means nothing on another Mac, and a hostile snapshot must not plant file references that Finder would act on.
    static let fileReferenceTypes: Set<String> = [
        ClipUTI.fileURL, "NSFilenamesPboardType", "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type", "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-suggested-file-name", "org.dittomac.internal",
    ]

    static func includes(type: String, size: Int, _ o: SyncOptions) -> Bool {
        guard SyncUTI.isValid(type), !fileReferenceTypes.contains(type), size > 0, size <= min(o.perFormatBytes, SyncLimits.maxFormatBytes) else { return false }
        if !o.includeImages, ClipUTI.imageTypes.contains(type) || type == ClipUTI.pdf { return false }
        if !o.includeRichFormats, ClipUTI.richTextTypes.contains(type) || type == ClipUTI.legacyWebArchive { return false }
        return true
    }

    private func plan(_ o: SyncOptions, now: Date) throws -> Plan {
        let locals = try scan(now: now)
        var groups = try store.groups().filter { !$0.isLocked }
        if groups.count > SyncLimits.maxGroups { groups = Array(groups.prefix(SyncLimits.maxGroups)) }
        var items: [Item] = []
        var total = 0
        let maxClips = min(o.maxClips, SyncLimits.maxClips)
        for l in locals {
            if items.count >= maxClips { break }
            let kept = try store.formatTypes(clipID: l.clip.id).filter { Self.includes(type: $0.type, size: $0.size, o) }
            guard !kept.isEmpty else { continue }
            let bytes = kept.reduce(0) { $0 + $1.size }
            guard total + bytes <= o.maxTotalBytes else { continue }
            total += bytes
            items.append(Item(clip: l.clip, hash: l.hash, types: Set(kept.map(\.type))))
        }
        var h = SHA256()
        func add(_ s: String) { h.update(data: Data(s.utf8)); h.update(data: Data([10])) }
        add("v1|\(o.includeImages)|\(o.includeRichFormats)|\(o.maxTotalBytes)|\(o.perFormatBytes)|\(o.maxClips)")
        for g in groups.sorted(by: { $0.id < $1.id }) { add("g|\(g.id)|\(g.text)|\(g.parentID)") }
        for i in items {
            let c = i.clip
            add("c|\(i.hash)|\(Int(c.date.timeIntervalSince1970))|\(Int(c.lastPasteDate.timeIntervalSince1970))|\(c.dontAutoDelete)|\(c.parentID)|\(Self.stickyFlags(c))|\(c.text)|\(c.quickPasteText)")
            add(i.types.sorted().joined(separator: ","))
        }
        return Plan(items: items, groups: groups, digest: SyncUtil.hex(h.finalize()))
    }

    static func stickyFlags(_ c: Clip) -> String {
        let v = c.parentID == Ditto.topLevelParent ? c.stickyClipOrder : c.stickyClipGroupOrder
        if v == Ditto.stickySentinel { return "-" }
        return v > 0 ? "T" : "L"
    }

    /// Digest of what would be pushed (metadata only). Equal digests mean the file need not be rewritten.
    public func currentDigest(options: SyncOptions, now: Date = Date()) throws -> String {
        lock.lock(); defer { lock.unlock() }
        return try plan(options, now: now).digest
    }

    /// Builds this device's snapshot: unlocked clips, newest first, within the size caps.
    public func makeSnapshot(deviceName: String, options: SyncOptions = SyncOptions(), now: Date = Date()) throws -> SyncSnapshot {
        lock.lock(); defer { lock.unlock() }
        return try snapshotLocked(deviceName: deviceName, options: options, now: now).snapshot
    }

    private func snapshotLocked(deviceName: String, options o: SyncOptions, now: Date) throws -> (snapshot: SyncSnapshot, digest: String) {
        let p = try plan(o, now: now)
        var snap = SyncSnapshot(deviceID: deviceID, deviceName: SyncUtil.cleanText(deviceName, max: SyncLimits.maxDeviceNameChars, keepNewlines: false),
                                createdAt: now.timeIntervalSince1970)
        let groupIDs = Set(p.groups.map(\.id))
        snap.groups = p.groups.map { SyncGroup(uid: "g\($0.id)", name: $0.text, parentUID: groupIDs.contains($0.parentID) ? "g\($0.parentID)" : nil) }
        for item in p.items {
            let c = item.clip
            var formats: [SyncFormat] = []
            // Re-checked atomically: a clip locked since `plan` listed it (vault unlocked, sync on a background queue)
            // would otherwise be read back as plaintext.
            guard let stored = try store.unlockedFormats(clipID: c.id) else { continue }
            for f in stored where item.types.contains(f.type) && Self.includes(type: f.type, size: f.data.count, o) {
                formats.append(SyncFormat(type: f.type, data: f.data))
            }
            guard !formats.isEmpty else { continue }
            let flags = Self.stickyFlags(c)
            snap.clips.append(SyncClip(
                contentHash: item.hash, date: c.date.timeIntervalSince1970, lastPasteDate: c.lastPasteDate.timeIntervalSince1970,
                description: c.text, quickPasteText: c.quickPasteText, neverAutoDelete: c.dontAutoDelete,
                stickyTop: flags == "T", stickyLast: flags == "L",
                groupUID: groupIDs.contains(c.parentID) ? "g\(c.parentID)" : nil, formats: formats))
        }
        return (snap, p.digest)
    }

    // MARK: merge

    /// Additively imports clips whose content hash this device doesn't have (and hasn't tombstoned).
    /// Idempotent. Groups are matched by name under the same parent (created only when needed). Never deletes.
    @discardableResult
    public func merge(_ snapshot: SyncSnapshot, honourTombstones: Bool = true, maxNewClips: Int? = nil,
                      now: Date = Date()) throws -> MergeSummary {
        lock.lock(); defer { lock.unlock() }
        let snap = try SyncValidator.sanitize(snapshot, now: now)
        return try mergeLocked(snap, honourTombstones: honourTombstones, maxNewClips: maxNewClips, now: now)
    }

    private func mergeLocked(_ snap: SyncSnapshot, honourTombstones: Bool, maxNewClips: Int?, now: Date) throws -> MergeSummary {
        _ = try scan(now: now)              // index every local clip first (incl. ones added since the last scan)
        var summary = MergeSummary()
        defer { saveState() }

        let groupsByUID = Dictionary(snap.groups.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        var localGroups = try store.groups()
        var resolved: [String: Int64] = [:]
        func resolve(_ uid: String, depth: Int = 0) throws -> Int64 {
            if let r = resolved[uid] { return r }
            guard depth <= SyncLimits.maxGroupDepth, let g = groupsByUID[uid] else { return Ditto.topLevelParent }
            let parent = try g.parentUID.map { try resolve($0, depth: depth + 1) } ?? Ditto.topLevelParent
            let id: Int64
            if let existing = localGroups.first(where: { $0.parentID == parent && $0.text == g.name }) {
                id = existing.id
            } else {
                id = try store.createGroup(name: g.name, parentID: parent)
                if let c = try store.clip(id: id) { localGroups.append(c) }
                summary.groupsCreated += 1
            }
            resolved[uid] = id
            return id
        }

        // chronological placement among existing clips (by clipOrder, descending)
        var order: [(date: Double, order: Double)] = try store.clips(ClipFilter(limit: 0))
            .map { ($0.date.timeIntervalSince1970, $0.clipOrder) }.sorted { $0.order > $1.order }

        let candidates = snap.clips.sorted { $0.date > $1.date }
        var newCount = 0
        for sc in candidates {
            if st.index[sc.contentHash] != nil { summary.alreadyPresent += 1; continue }
            if honourTombstones, tomb.tombstones[sc.contentHash] != nil { summary.tombstoned += 1; continue }
            if let cap = maxNewClips, newCount >= cap { summary.limited += 1; continue }
            let formats = sc.formats.filter { !Self.fileReferenceTypes.contains($0.type) }.map { ClipFormat(type: $0.type, data: $0.data) }
            guard !formats.isEmpty else { continue }
            let parent = try sc.groupUID.map { try resolve($0) } ?? Ditto.topLevelParent
            var opts = ClipStore.AddOptions()
            opts.allowDuplicates = true
            opts.allowBackToBackDuplicates = true
            opts.makeTopSticky = sc.stickyTop
            opts.makeLastSticky = sc.stickyLast
            guard case .inserted(let id) = try store.addClip(formats: formats, description: sc.description, sourceApp: "", parentID: parent, options: opts),
                  var clip = try store.clip(id: id) else { continue }
            clip.date = Date(timeIntervalSince1970: sc.date)
            clip.lastPasteDate = Date(timeIntervalSince1970: sc.lastPasteDate)
            clip.dontAutoDelete = sc.neverAutoDelete
            clip.quickPasteText = sc.quickPasteText
            // slot the clip in by date instead of on top
            var p = order.firstIndex(where: { $0.date <= sc.date }) ?? order.count
            if p > 0 {
                let upper = order[p - 1].order
                if p < order.count {
                    let lower = order[p].order
                    if upper - lower > 1e-6 { clip.clipOrder = (upper + lower) / 2 } else { p = 0 }
                } else {
                    clip.clipOrder = upper - 1
                }
            }
            order.insert((sc.date, clip.clipOrder), at: p)
            if parent == Ditto.topLevelParent { clip.clipGroupOrder = clip.clipOrder }
            try store.update(clip)
            st.index[sc.contentHash] = id
            st.imported[String(id)] = SyncImportedEntry(hash: sc.contentHash, crc: Int(clip.crc))
            summary.imported += 1
            newCount += 1
        }
        return summary
    }

    // MARK: folder runs

    private func passKey(_ p: String) -> String { SyncUtil.hex(SHA256.hash(data: Data(SyncKDF.normalise(p).utf8))) }

    /// True when a remote device file changed (cheap: stat only).
    public func hasRemoteChanges(in folder: SyncFolder, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let files = folder.deviceFiles().filter { $0.deviceID != deviceID }
        for f in files {
            guard let s = seen[f.name] else { return true }
            if s.modified != f.modified || s.size != f.size { return true }
        }
        return false
    }

    /// One sync pass: pull (merge) changed remote files, push this device's snapshot, optional daily backup.
    public func run(folder: SyncFolder, passphrase: String, request r: SyncRunRequest, now: Date = Date()) -> SyncReport {
        lock.lock(); defer { lock.unlock() }
        var rep = SyncReport()
        guard passphrase.count >= SyncLimits.minPassphraseLength else { rep.hardError = SyncError.passphraseTooShort.localizedDescription; return rep }
        let pk = passKey(passphrase)
        let ownName = SyncFolder.deviceFileName(deviceID)

        // pull
        var infos: [SyncDeviceInfo] = []
        if r.pull != .none {
            var budget = r.maxNewClips
            for f in folder.deviceFiles() where f.deviceID != deviceID {
                if r.pull == .changedOnly, let s = seen[f.name], s.modified == f.modified, s.size == f.size, s.passKey == pk,
                   s.retryAt.map({ now < $0 }) ?? true {
                    infos.append(s.info); continue
                }
                var info = SyncDeviceInfo(fileName: f.name, deviceID: f.deviceID, deviceName: nil, modified: f.modified,
                                          sizeBytes: f.size, clipCount: nil, status: .unreadable)
                var retryAt: Date?
                do {
                    let data = try SyncFolder.readLimited(f.url)
                    let snap = try SyncCodec.open(data, passphrase: passphrase, now: now)
                    if snap.deviceID.uppercased() != f.deviceID { throw SyncError.malformed("device mismatch") }
                    info.deviceName = snap.deviceName.isEmpty ? nil : snap.deviceName
                    info.clipCount = snap.clips.count
                    info.status = .ok
                    let m = try mergeLocked(snap, honourTombstones: true, maxNewClips: budget, now: now)
                    if let b = budget { budget = max(0, b - m.imported) }
                    rep.merge.imported += m.imported; rep.merge.alreadyPresent += m.alreadyPresent
                    rep.merge.tombstoned += m.tombstoned; rep.merge.limited += m.limited; rep.merge.groupsCreated += m.groupsCreated
                } catch SyncError.wrongPassphraseOrCorrupt {
                    info.status = .wrongPassphrase
                    retryAt = now.addingTimeInterval(300)
                    rep.warnings.append("\(f.name): wrong passphrase or damaged file")
                } catch {
                    info.status = .unreadable
                    retryAt = now.addingTimeInterval(300)
                    rep.warnings.append("\(f.name): \((error as? SyncError)?.localizedDescription ?? "unreadable")")
                }
                seen[f.name] = Seen(modified: f.modified, size: f.size, passKey: pk, retryAt: retryAt, info: info)
                infos.append(info)
            }
        }

        // push
        var ownInfo: SyncDeviceInfo?
        if r.push {
            do {
                let digest = try plan(r.options, now: now).digest
                let ownFile = folder.deviceFiles().first { $0.name == ownName }
                if digest == st.lastPushDigest, let ownFile {
                    rep.pushSkippedUnchanged = true
                    ownInfo = SyncDeviceInfo(fileName: ownName, deviceID: deviceID, deviceName: r.deviceName, modified: ownFile.modified,
                                             sizeBytes: ownFile.size, clipCount: st.lastPushCount, status: .thisDevice)
                } else {
                    let (snap, d) = try snapshotLocked(deviceName: r.deviceName, options: r.options, now: now)
                    let blob = try SyncCodec.seal(snap, passphrase: passphrase, iterations: r.iterations, salt: salt)
                    try folder.write(blob, named: ownName)
                    st.lastPushDigest = d
                    st.lastPushCount = snap.clips.count
                    saveState()
                    rep.pushed = true
                    ownInfo = SyncDeviceInfo(fileName: ownName, deviceID: deviceID, deviceName: r.deviceName, modified: now,
                                             sizeBytes: Int64(blob.count), clipCount: snap.clips.count, status: .thisDevice)
                }
            } catch {
                rep.hardError = (error as? SyncError)?.localizedDescription ?? "Could not write the snapshot."
            }
        }
        if ownInfo == nil, let f = folder.deviceFiles().first(where: { $0.name == ownName }) {
            ownInfo = SyncDeviceInfo(fileName: ownName, deviceID: deviceID, deviceName: r.deviceName, modified: f.modified,
                                     sizeBytes: f.size, clipCount: st.lastPushCount, status: .thisDevice)
        }

        // backup
        if let keep = r.backupKeep, rep.hardError == nil {
            do { rep.backupFile = try backupLocked(folder: folder, passphrase: passphrase, request: r, keep: keep, now: now) }
            catch { rep.warnings.append("Backup failed: \((error as? SyncError)?.localizedDescription ?? "unknown error")") }
        }

        rep.devices = ((ownInfo.map { [$0] } ?? []) + infos).sorted { $0.isThisDevice != $1.isThisDevice ? $0.isThisDevice : ($0.deviceName ?? $0.fileName) < ($1.deviceName ?? $1.fileName) }
        return rep
    }

    // MARK: backups

    static func backupSafeName(_ n: String) -> String {
        let s = String(n.unicodeScalars.map { c -> Character in
            (c.isASCII && (c.properties.isAlphabetic || (c.value >= 48 && c.value <= 57))) || c == "-" || c == "_" ? Character(c) : "-"
        }.prefix(40))
        return s.isEmpty ? "Mac" : s
    }

    static func backupName(date: Date, deviceName: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "backup-\(f.string(from: date))-\(backupSafeName(deviceName)).dmsync"
    }

    /// Writes today's rolling backup if it doesn't exist yet and prunes this device's old ones. Returns the new file name.
    public func backup(folder: SyncFolder, passphrase: String, request: SyncRunRequest, keep: Int, now: Date = Date()) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return try backupLocked(folder: folder, passphrase: passphrase, request: request, keep: keep, now: now)
    }

    private func backupLocked(folder: SyncFolder, passphrase: String, request r: SyncRunRequest, keep: Int, now: Date) throws -> String? {
        let name = Self.backupName(date: now, deviceName: r.deviceName)
        var written: String?
        if !FileManager.default.fileExists(atPath: folder.url.appendingPathComponent(name).path) {
            let (snap, _) = try snapshotLocked(deviceName: r.deviceName, options: r.options, now: now)
            try folder.write(try SyncCodec.seal(snap, passphrase: passphrase, iterations: r.iterations, salt: salt), named: name)
            written = name
        }
        // prune: this device's backups only, newest `keep` stay
        let suffix = "-" + Self.backupSafeName(r.deviceName) + ".dmsync"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? []).filter {
            $0.hasPrefix("backup-") && $0.hasSuffix(suffix) && $0.count == "backup-yyyy-MM-dd".count + suffix.count
        }.sorted(by: >)
        for old in names.dropFirst(max(1, keep)) { try? FileManager.default.removeItem(at: folder.url.appendingPathComponent(old)) }
        return written
    }

    // MARK: restore

    /// Merges a `.dmsync` file chosen by the user (a backup or another Mac's file). Tombstones are ignored on purpose.
    public func restore(from fileURL: URL, passphrase: String, now: Date = Date()) throws -> MergeSummary {
        let data = try SyncFolder.readLimited(fileURL)
        let snap = try SyncCodec.open(data, passphrase: passphrase, now: now)
        lock.lock(); defer { lock.unlock() }
        return try mergeLocked(snap, honourTombstones: false, maxNewClips: nil, now: now)
    }
}
