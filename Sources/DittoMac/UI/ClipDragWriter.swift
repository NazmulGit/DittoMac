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
// folders older than an hour are removed the next time a drag starts.

import AppKit
import DittoCore

@MainActor
enum ClipDragWriter {
    /// Per-clip cap for the temp file; larger clips still drag as formats, just without a file.
    private static let maxFileBytes = 64 * 1024 * 1024

    private static var currentFolder: (url: URL, created: Date)?

    /// Returns nil for groups or clips without data.
    static func make(clip: Clip, index: Int, store: ClipStore) -> NSPasteboardWriting? {
        guard !clip.isGroup, let formats = try? store.formats(clipID: clip.id), !formats.isEmpty else { return nil }

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
        let base = ImportExport.textFileName(for: clip, index: index)
        let stem = base.hasSuffix(".txt") ? String(base.dropLast(4)) : base
        let url = folder.appendingPathComponent("\(stem).\(ext)")
        do {
            if let p = payload { try p.write(to: url, options: .atomic) }
            else if let w = package { try w.write(to: url, options: .atomic, originalContentsURL: nil) }
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            return url
        } catch {
            NSLog("DittoMac: could not stage dragged clip: \(error)")
            return nil
        }
    }

    /// One folder per drag: reused while the rows of the same drag are requested (they arrive within milliseconds).
    private static func dragFolder() -> URL? {
        if let c = currentFolder, Date().timeIntervalSince(c.created) < 5 { return c.url }
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("DittoMacDrag", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            purgeOld(root)
            let f = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: f, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            currentFolder = (f, Date())
            return f
        } catch {
            NSLog("DittoMac: drag staging folder unavailable: \(error)")
            return nil
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
