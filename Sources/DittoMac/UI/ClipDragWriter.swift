// ClipDragWriter.swift — drag clips (one or many) out of the Quick Paste list into Finder, the desktop, Mail,
// Notes, Messages, other Macs via Universal Control, and so on.
//
// Each dragged clip becomes one pasteboard item that offers BOTH:
//   • a real file (image bytes, or .rtfd/.rtf/.html/.txt) in a private temp folder, so Finder/desktop/Mail
//     attachments receive a file, and
//   • the clip's stored formats, so text editors and rich-text apps paste text/RTF/HTML/images directly.
// Clips that hold real file references (copied in Finder) are dragged as those files instead.
//
// Temp files live in a 0700 folder under the user's temporary directory, one sub-folder per drag, and
// folders older than an hour are removed the next time a drag starts. Locked notes are staged only while the vault
// is unlocked, under a neutral name and mode 0600, and their folders are deleted as soon as the vault locks. The
// whole staging area (and leftover share-panel PNGs) is removed at launch (after a crash) and at quit.

import AppKit
import DittoCore

@MainActor
enum ClipDragWriter {
    /// Per-clip cap for the temp file; larger clips still drag as formats, just without a file.
    private static let maxFileBytes = 64 * 1024 * 1024

    private static var currentFolder: (url: URL, created: Date)?
    /// Drag folders holding a locked note's plaintext; deleted by `purgeLockedStaging()` when the vault locks.
    private static var lockedFolders: Set<URL> = []

    private static var stagingRoot: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("DittoMacDrag", isDirectory: true)
    }

    /// Returns nil for groups or clips without data. Locked notes return nil while the vault is locked.
    static func make(clip: Clip, index: Int, store: ClipStore) -> NSPasteboardWriting? {
        guard !clip.isGroup else { return nil }
        if clip.isLocked && store.vaultKey == nil { return nil }
        guard let formats = try? store.formats(clipID: clip.id), !formats.isEmpty else { return nil }

        // Real files (copied in Finder): drag the files themselves.
        if formats.contains(where: { $0.type == ClipUTI.fileURL }) {
            return PasteContent.pasteboardItems(for: formats).first
        }

        let item = PasteContent.pasteboardItems(for: formats).first ?? NSPasteboardItem()
        if let url = writeTempFile(clip: clip, index: index, formats: formats) {
            item.setString(url.absoluteString, forType: .fileURL)
        }
        return item
    }

    // MARK: Temp files

    private static func writeTempFile(clip: Clip, index: Int, formats: [ClipFormat]) -> URL? {
        func data(_ t: String) -> Data? { formats.first(where: { $0.type == t })?.data }
        let types = formats.map(\.type)

        let ext: String
        var payload: Data?
        var package: FileWrapper?
        if let img = ClipUTI.imageTypes.first(where: types.contains), let d = data(img) {
            switch img {
            case ClipUTI.jpeg: ext = "jpg"
            case ClipUTI.gif: ext = "gif"
            case ClipUTI.heic: ext = "heic"
            case ClipUTI.tiff: ext = "tiff"
            default: ext = "png"
            }
            payload = d
        } else if let d = data(ClipUTI.flatRTFD) ?? data(ClipUTI.rtfd),
                  let a = NSAttributedString(rtfd: d, documentAttributes: nil),
                  let w = a.rtfdFileWrapper(from: NSRange(location: 0, length: a.length), documentAttributes: [:]) {
            ext = "rtfd"; package = w
        } else if let d = data(ClipUTI.rtf) { ext = "rtf"; payload = d }
        else if let d = data(ClipUTI.html) { ext = "html"; payload = d }
        else if let d = data(ClipUTI.plainText) { ext = "txt"; payload = d }
        else { return nil }

        if let p = payload, p.count > maxFileBytes { return nil }

        guard let folder = dragFolder() else { return nil }
        // A locked note's file name never carries its (decrypted) description.
        let stem: String
        if clip.isLocked {
            stem = "Locked note \(index)"
            lockedFolders.insert(folder)
        } else {
            let base = ImportExport.textFileName(for: clip, index: index)
            stem = base.hasSuffix(".txt") ? String(base.dropLast(4)) : base
        }
        let url = folder.appendingPathComponent("\(stem).\(ext)")
        do {
            if let p = payload { try p.write(to: url, options: .atomic) }
            else if let w = package { try w.write(to: url, options: .atomic, originalContentsURL: nil) }
            try? FileManager.default.setAttributes([.posixPermissions: clip.isLocked ? 0o600 : 0o644], ofItemAtPath: url.path)
            return url
        } catch {
            // No path in the log: file names are derived from clip text.
            NSLog("DittoMac: could not stage a dragged clip (error %ld)", (error as NSError).code)
            return nil
        }
    }

    /// One folder per drag: reused while the rows of the same drag are requested (they arrive within milliseconds).
    private static func dragFolder() -> URL? {
        if let c = currentFolder, Date().timeIntervalSince(c.created) < 5 { return c.url }
        let root = stagingRoot
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            purgeOld(root)
            let f = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: f, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            currentFolder = (f, Date())
            return f
        } catch {
            NSLog("DittoMac: drag staging folder unavailable (error %ld)", (error as NSError).code)
            return nil
        }
    }

    /// Deletes every staged copy of a locked note (call whenever the vault locks or is reset).
    static func purgeLockedStaging() {
        let fm = FileManager.default
        for f in lockedFolders { try? fm.removeItem(at: f) }
        if let c = currentFolder, lockedFolders.contains(c.url) { currentFolder = nil }
        lockedFolders.removeAll()
    }

    /// Removes the whole drag staging area and leftover share-panel PNGs (launch, after a crash, and quit).
    static func purgeAllStaging() {
        let fm = FileManager.default
        try? fm.removeItem(at: stagingRoot)
        currentFolder = nil
        lockedFolders.removeAll()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        for u in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
        where u.lastPathComponent.hasPrefix("DittoMac-Share-") {
            try? fm.removeItem(at: u)
        }
    }

    private static func purgeOld(_ root: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for u in items {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if d < cutoff { try? fm.removeItem(at: u) }
        }
    }
}
