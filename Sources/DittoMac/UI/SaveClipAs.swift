// SaveClipAs.swift — "Save Clip As…": write a clip to a file as rich text (.rtf/.rtfd), web archive, HTML, Markdown,
// plain text or PNG. Several selected clips → one file per clip in a chosen folder.

import AppKit
import UniformTypeIdentifiers
import DittoCore

enum SaveClipFormat: Int, CaseIterable {
    case richText, webArchive, html, markdown, plainText, image

    var title: String {
        switch self {
        case .richText: return "Rich Text Document"
        case .webArchive: return "Web Archive"
        case .html: return "HTML"
        case .markdown: return "Markdown"
        case .plainText: return "Plain Text"
        case .image: return "Image (PNG)"
        }
    }

    /// Formats a clip with these stored types can be saved in.
    static func available(for formats: [ClipFormat]) -> [SaveClipFormat] {
        let s = ClipFormatSummary(types: formats.map(\.type))
        let hasText = s.hasText || s.hasRichText || PasteContent.text(from: formats) != nil
        var out: [SaveClipFormat] = []
        if hasText { out.append(.richText) }
        if s.hasWebArchive { out.append(.webArchive) }
        if hasText { out += [.html, .markdown, .plainText] }
        if s.hasImage { out.append(.image) }
        return out
    }

    /// The format pre-selected in the panel.
    static func preferred(for formats: [ClipFormat]) -> SaveClipFormat {
        let s = ClipFormatSummary(types: formats.map(\.type))
        if s.hasRichText { return .richText }
        if s.hasImage && !s.hasText { return .image }
        return .plainText
    }
}

/// A file ready to write: plain bytes, or a package (.rtfd).
enum SaveClipPayload {
    case data(Data, ext: String)
    case package(FileWrapper, ext: String)

    var ext: String {
        switch self {
        case .data(_, let e), .package(_, let e): return e
        }
    }

    func write(to url: URL) throws {
        switch self {
        case .data(let d, _):
            try d.write(to: url, options: .atomic)
        case .package(let w, _):
            // The save panel already confirmed replacing an existing item; packages can't be replaced atomically.
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try w.write(to: url, options: .atomic, originalContentsURL: nil)
        }
    }

    static func contentType(forExtension ext: String) -> UTType {
        switch ext {
        case "rtfd": return .rtfd
        case "rtf": return .rtf
        case "webarchive": return .webArchive
        case "html": return .html
        case "png": return .png
        case "md": return UTType(filenameExtension: "md") ?? .plainText
        default: return .plainText
        }
    }

    /// Builds the file for one clip in `format`. nil when the clip has nothing for that format.
    static func make(_ format: SaveClipFormat, from formats: [ClipFormat]) -> SaveClipPayload? {
        switch format {
        case .richText:
            // Keep inline images: a stored RTFD with attachments is saved as an .rtfd package.
            if let a = PasteContent.rtfdAttributed(from: formats), PasteContent.hasAttachments(a),
               let w = try? a.fileWrapper(from: NSRange(location: 0, length: a.length),
                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
                return .package(w, ext: "rtfd")
            }
            if let rtf = PasteContent.data(formats, ClipUTI.rtf) { return .data(rtf, ext: "rtf") }
            if let a = PasteContent.styledTextWithoutImages(from: formats), let rtf = PasteContent.rtfData(a) {
                return .data(rtf, ext: "rtf")
            }
            guard let t = PasteContent.text(from: formats), let rtf = PasteContent.rtfData(NSAttributedString(string: t)) else { return nil }
            return .data(rtf, ext: "rtf")
        case .webArchive:
            return PasteContent.data(formats, ClipUTI.webArchive).map { .data($0, ext: "webarchive") }
        case .html:
            guard let html = PasteContent.htmlMarkup(from: formats) else { return nil }
            return .data(Data(html.utf8), ext: "html")
        case .markdown:
            return PasteContent.markdown(from: formats).map { .data(Data($0.utf8), ext: "md") }
        case .plainText:
            return PasteContent.text(from: formats).map { .data(Data($0.utf8), ext: "txt") }
        case .image:
            guard let d = PasteContent.imageData(from: formats) else { return nil }
            if formats.contains(where: { $0.type == ClipUTI.png && $0.data == d }) { return .data(d, ext: "png") }
            guard ImageProbe.isSafeToDecode(d), let rep = NSBitmapImageRep(data: d),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            return .data(png, ext: "png")
        }
    }

    /// Extension the payload for `format` will use (for the save panel's name field) without building it.
    static func expectedExtension(_ format: SaveClipFormat, formats: [ClipFormat]) -> String {
        switch format {
        case .richText:
            if let a = PasteContent.rtfdAttributed(from: formats), PasteContent.hasAttachments(a) { return "rtfd" }
            return "rtf"
        case .webArchive: return "webarchive"
        case .html: return "html"
        case .markdown: return "md"
        case .plainText: return "txt"
        case .image: return "png"
        }
    }
}

/// "Format:" pop-up shown as the save / open panel's accessory view.
@MainActor
final class SaveFormatAccessory: NSObject {
    let view: NSView
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let options: [SaveClipFormat]
    private weak var panel: NSSavePanel?
    private let extensionFor: (SaveClipFormat) -> String?

    var selected: SaveClipFormat { options[max(0, min(popup.indexOfSelectedItem, options.count - 1))] }

    init(options: [SaveClipFormat], selected: SaveClipFormat, panel: NSSavePanel, extensionFor: @escaping (SaveClipFormat) -> String?) {
        self.options = options
        self.panel = panel
        self.extensionFor = extensionFor
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        view = stack
        super.init()
        for o in options { popup.addItem(withTitle: o.title) }
        popup.selectItem(at: options.firstIndex(of: selected) ?? 0)
        popup.target = self
        popup.action = #selector(changed)
        apply()
    }

    @objc private func changed() { apply() }

    private func apply() {
        guard let panel, let ext = extensionFor(selected) else { return }
        panel.allowedContentTypes = [SaveClipPayload.contentType(forExtension: ext)]
        let stem = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = (stem.isEmpty ? "Clip" : stem) + "." + ext
    }
}

extension QuickPasteController {
    /// Save Clip As… (one clip: save panel with a format pop-up; several: one file per clip into a folder).
    func saveSelectionAs() {
        let clips = selectedClips.filter { !$0.isGroup }
        guard !clips.isEmpty else { return }
        withVaultAccess(clips, reason: "save a locked note") { [weak self] in self?.saveClipsAs(clips) }
    }

    private func saveClipsAs(_ clips: [Clip]) {
        let loaded: [(Clip, [ClipFormat])] = clips.compactMap { c in
            guard let f = try? store.formats(clipID: c.id), !f.isEmpty else { return nil }
            return (c, f)
        }
        guard !loaded.isEmpty else {
            state.message("Selected clips have no data to save")
            return
        }
        if loaded.count == 1 { saveOne(loaded[0].0, loaded[0].1) } else { saveMany(loaded) }
    }

    private func saveOne(_ clip: Clip, _ formats: [ClipFormat]) {
        let options = SaveClipFormat.available(for: formats)
        guard !options.isEmpty else {
            state.message("This clip has nothing that can be saved as a document")
            return
        }
        let p = NSSavePanel()
        p.title = "Save Clip As"
        p.canCreateDirectories = true
        p.isExtensionHidden = false
        let base = ImportExport.textFileName(for: clip, index: 1)
        p.nameFieldStringValue = String(base.dropFirst(2).dropLast(4))       // drop "1 " and ".txt"
        let preferred = SaveClipFormat.preferred(for: formats)
        let accessory = SaveFormatAccessory(options: options, selected: options.contains(preferred) ? preferred : options[0], panel: p) {
            SaveClipPayload.expectedExtension($0, formats: formats)
        }
        p.accessoryView = accessory.view
        guard p.runModal() == .OK, let url = p.url else { return }
        guard let payload = SaveClipPayload.make(accessory.selected, from: formats) else {
            state.message("Clip has no content for “\(accessory.selected.title)”")
            return
        }
        // The extension can differ from the one shown (e.g. RTFD attachments unreadable → .rtf).
        let target = url.pathExtension.lowercased() == payload.ext ? url : url.deletingPathExtension().appendingPathExtension(payload.ext)
        do {
            try payload.write(to: target)
            state.message("Saved \(target.lastPathComponent)")
        } catch {
            state.message("Save failed: \(error.localizedDescription)")
        }
    }

    private func saveMany(_ loaded: [(Clip, [ClipFormat])]) {
        var options: [SaveClipFormat] = []
        for (_, f) in loaded { for o in SaveClipFormat.available(for: f) where !options.contains(o) { options.append(o) } }
        options.sort { $0.rawValue < $1.rawValue }
        guard !options.isEmpty else {
            state.message("Selected clips have nothing that can be saved as documents")
            return
        }
        let p = NSOpenPanel()
        p.title = "Save \(loaded.count) Clips As"
        p.message = "Choose a folder. One file is written per clip; existing files are never overwritten."
        p.prompt = "Save"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        let accessory = SaveFormatAccessory(options: options, selected: options.contains(.richText) ? .richText : options[0], panel: p) { _ in nil }
        p.accessoryView = accessory.view
        p.isAccessoryViewDisclosed = true
        guard p.runModal() == .OK, let dir = p.url else { return }
        let fm = FileManager.default
        var written = 0, skipped = 0
        for (i, pair) in loaded.enumerated() {
            guard let payload = SaveClipPayload.make(accessory.selected, from: pair.1) else { skipped += 1; continue }
            var name = ImportExport.textFileName(for: pair.0, index: i + 1)
            if name.hasSuffix(".txt") { name = String(name.dropLast(4)) }
            var url = dir.appendingPathComponent(name).appendingPathExtension(payload.ext)
            var n = 2
            while fm.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("\(name) (\(n))").appendingPathExtension(payload.ext)
                n += 1
            }
            if (try? payload.write(to: url)) != nil { written += 1 } else { skipped += 1 }
        }
        state.message("Saved \(written) file(s) to \(dir.lastPathComponent)" + (skipped > 0 ? " · \(skipped) skipped" : ""))
    }
}
