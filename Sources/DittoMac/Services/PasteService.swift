// PasteService.swift — put clips on the pasteboard (with transforms), restore focus, and post ⌘V via CGEvent.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DittoCore

/// Helpers for extracting text / images / file URLs from stored clip formats.
enum PasteContent {
    static func text(from formats: [ClipFormat]) -> String? {
        if let f = formats.first(where: { $0.type == ClipUTI.plainText }) {
            return String(decoding: f.data, as: UTF8.self)
        }
        if let f = formats.first(where: { $0.type == "public.utf16-plain-text" }),
           let s = String(data: f.data, encoding: .utf16) { return s }
        if let f = formats.first(where: { $0.type == ClipUTI.rtf }),
           let a = NSAttributedString(rtf: f.data, documentAttributes: nil) { return a.string }
        if let f = formats.first(where: { $0.type == ClipUTI.html }),
           let a = SafeRichText.html(f.data) { return a.string }   // sanitised: no remote loads
        if let f = formats.first(where: { $0.type == ClipUTI.fileURL }) {
            return fileURLs(from: f.data).map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: "\n")
        }
        return nil
    }

    static func text(clipID: Int64, store: ClipStore) -> String? {
        if let d = try? store.data(clipID: clipID, type: ClipUTI.plainText) { return String(decoding: d, as: UTF8.self) }
        guard let formats = try? store.formats(clipID: clipID) else { return nil }
        return text(from: formats)
    }

    static func imageData(from formats: [ClipFormat]) -> Data? {
        if let f = formats.first(where: { $0.type == ClipUTI.png }) { return f.data }
        if let f = formats.first(where: { $0.type == ClipUTI.tiff }) { return f.data }
        return nil
    }

    static func image(clipID: Int64, store: ClipStore) -> NSImage? {
        if let d = try? store.data(clipID: clipID, type: ClipUTI.png) { return NSImage(data: d) }
        if let d = try? store.data(clipID: clipID, type: ClipUTI.tiff) { return NSImage(data: d) }
        return nil
    }

    static func fileURLs(from data: Data) -> [URL] {
        String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { URL(string: String($0).trimmingCharacters(in: .whitespaces)) }
    }

    static func fileURLs(clipID: Int64, store: ClipStore) -> [URL] {
        guard let d = try? store.data(clipID: clipID, type: ClipUTI.fileURL) else { return [] }
        return fileURLs(from: d)
    }

    /// One pasteboard item per clip (drag-out / share). File URLs get extra items, one per file.
    static func pasteboardItems(for formats: [ClipFormat]) -> [NSPasteboardItem] {
        let item = NSPasteboardItem()
        var extra: [NSPasteboardItem] = []
        for f in formats {
            if f.type == ClipUTI.fileURL {
                let urls = fileURLs(from: f.data)
                for (i, u) in urls.enumerated() {
                    if i == 0 { item.setString(u.absoluteString, forType: .fileURL) } else {
                        let it = NSPasteboardItem()
                        it.setString(u.absoluteString, forType: .fileURL)
                        extra.append(it)
                    }
                }
            } else if f.type == ClipUTI.plainText {
                item.setString(String(decoding: f.data, as: UTF8.self), forType: .string)
            } else {
                item.setData(f.data, forType: NSPasteboard.PasteboardType(f.type))
            }
        }
        return [item] + extra
    }
}

@MainActor
final class PasteService: PasteServicing {
    unowned let state: AppState
    var targetApp: NSRunningApplication?

    /// Max dimension for stitched images (safety cap).
    private let maxStitchDimension = 16_384

    init(state: AppState) {
        self.state = state
    }

    private var store: ClipStore { state.store }
    private var settings: Settings { state.settings }

    // MARK: PasteServicing

    func paste(clipIDs: [Int64], transform: TextTransform?, sendPaste: Bool, moveToTop: Bool) {
        let ids = pastableIDs(clipIDs)
        guard !ids.isEmpty else { return }
        guard loadToPasteboard(ids, transform: transform) else { return }
        finishPaste(ids: ids, sendPaste: sendPaste, moveToTop: moveToTop)
    }

    func pasteImagesStitched(clipIDs: [Int64], vertical: Bool) {
        let ids = pastableIDs(clipIDs)
        var images: [CGImage] = []
        for id in ids {
            // Check the header first so a decompression bomb is never fully decoded.
            guard let formats = try? store.formats(clipID: id), let data = PasteContent.imageData(from: formats),
                  let size = ImageProbe.pixelSize(data), size.width <= maxStitchDimension, size.height <= maxStitchDimension,
                  let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { continue }
            images.append(cg)
        }
        guard !images.isEmpty else {
            state.message("No images selected to stitch")
            return
        }
        guard let png = stitch(images, vertical: vertical) else {
            state.message("Images are too large to stitch")
            return
        }
        writeToPasteboard([ClipFormat(type: ClipUTI.png, data: png)])
        finishPaste(ids: ids, sendPaste: settings.sendPasteAfterSelection, moveToTop: true)
    }

    func copyToPasteboard(clipIDs: [Int64], transform: TextTransform?) {
        let ids = pastableIDs(clipIDs)
        guard !ids.isEmpty else { return }
        _ = loadToPasteboard(ids, transform: transform)
    }

    @discardableResult
    func writeToPasteboard(_ formats: [ClipFormat]) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = PasteContent.pasteboardItems(for: formats)
        for it in items { it.setData(Data(), forType: dittoInternalPasteboardType) }
        pb.writeObjects(items)
        let cc = pb.changeCount
        state.monitor?.ignoreChangeCount(cc)
        return cc
    }

    func postCommandKey(_ char: Character) {
        let fallback: CGKeyCode
        switch char.lowercased() {
        case "c": fallback = CGKeyCode(kVK_ANSI_C)
        case "x": fallback = CGKeyCode(kVK_ANSI_X)
        case "a": fallback = CGKeyCode(kVK_ANSI_A)
        default: fallback = CGKeyCode(kVK_ANSI_V)
        }
        let code = Self.keyCode(for: char) ?? fallback
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Paste helpers

    /// Re-activates the paste target and posts ⌘V (or tells the user to press ⌘V when not trusted).
    func sendPasteToTarget() {
        let target = targetApp
        activate(target)
        guard isAccessibilityTrusted(prompt: false) else {
            state.message("Copied — press ⌘V (enable Accessibility for auto-paste)")
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            await Self.waitForModifiersReleased()
            self?.postCommandKey("v")
        }
    }

    /// A hotkey-triggered paste would otherwise post ⌘V while the user still holds the hotkey's modifiers
    /// (making it e.g. ⌘⇧V). Polls every 20 ms, for at most 1 s.
    static func waitForModifiersReleased() async {
        let mask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        var waited = 0
        while waited < 1000, !CGEventSource.flagsState(.combinedSessionState).intersection(mask).isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
            waited += 20
        }
    }

    /// Paste the current pasteboard contents as plain text (global "text only paste" hotkey).
    func pasteCurrentClipboardAsPlainText() {
        guard let s = NSPasteboard.general.string(forType: .string) else {
            state.message("Clipboard has no text")
            return
        }
        targetApp = frontmostOtherApp()
        let pb = NSPasteboard.general
        let saved = Self.snapshot(pb)
        let written = writeToPasteboard([ClipFormat(type: ClipUTI.plainText, data: Data(s.utf8))])
        settings.recordPaste()
        sendPasteToTarget()
        // Upstream TextOnlyRestoreDelay: put the original (rich) clipboard back unless something else changed it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, pb.changeCount == written else { return }
            self.restore(saved)
        }
    }

    private typealias Snapshot = [[(type: NSPasteboard.PasteboardType, data: Data)]]

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            item.types.filter { $0 != dittoInternalPasteboardType }.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
    }

    private func restore(_ snap: Snapshot) {
        let pb = NSPasteboard.general
        var items = [NSPasteboardItem]()
        for entry in snap where !entry.isEmpty {
            let item = NSPasteboardItem()
            for (t, d) in entry { item.setData(d, forType: t) }
            items.append(item)
        }
        guard !items.isEmpty else { return }
        pb.clearContents()
        items[0].setData(Data(), forType: dittoInternalPasteboardType)
        pb.writeObjects(items)
        state.monitor?.ignoreChangeCount(pb.changeCount)
    }

    func frontmostOtherApp() -> NSRunningApplication? {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? targetApp : app
    }

    private func activate(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier, !app.isTerminated else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func finishPaste(ids: [Int64], sendPaste: Bool, moveToTop: Bool) {
        let move = moveToTop && settings.updateTimeOnPaste
        for id in ids { try? store.markPasted(id: id, moveToTop: move) }
        settings.recordPaste()
        state.clipsChanged()
        if sendPaste { sendPasteToTarget() }
    }

    /// Drops groups (a group itself can't be pasted).
    private func pastableIDs(_ ids: [Int64]) -> [Int64] {
        ids.filter { id in (try? store.clip(id: id))?.isGroup != true }
    }

    /// Writes the given clips to the pasteboard. Returns false (with a HUD message) if nothing could be written.
    private func loadToPasteboard(_ ids: [Int64], transform: TextTransform?) -> Bool {
        if ids.count == 1 {
            guard let formats = try? store.formats(clipID: ids[0]), !formats.isEmpty else {
                state.message("Clip has no data")
                return false
            }
            guard let transform else {
                writeToPasteboard(formats)
                return true
            }
            guard let text = PasteContent.text(from: formats) else {
                state.message("Clip has no text for “\(transform.title)”")
                return false
            }
            var out = [ClipFormat(type: ClipUTI.plainText, data: Data(apply(transform, to: text).utf8))]
            if transform == .removeLineFeeds, let rtf = formats.first(where: { $0.type == ClipUTI.rtf }),
               let rtfString = String(data: rtf.data, encoding: .utf8) ?? String(data: rtf.data, encoding: .ascii) {
                out.append(ClipFormat(type: ClipUTI.rtf, data: Data(RTFTransform.removeLineFeeds(rtfString).utf8)))
            }
            writeToPasteboard(out)
            return true
        }

        // Multi-paste: join texts.
        var texts: [String] = []
        var files: [URL] = []
        var allFileClips = true
        for id in ids {
            guard let formats = try? store.formats(clipID: id) else { continue }
            if !formats.contains(where: { $0.type == ClipUTI.fileURL }) { allFileClips = false }
            if let t = PasteContent.text(from: formats), formats.contains(where: { $0.type != ClipUTI.fileURL }) {
                texts.append(t)
            } else if let f = formats.first(where: { $0.type == ClipUTI.fileURL }) {
                files.append(contentsOf: PasteContent.fileURLs(from: f.data))
            }
        }
        if allFileClips, !files.isEmpty, transform == nil {
            // Every selected clip is a file clip (Finder copies also carry the names as text): paste the files.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(files as [NSURL])
            state.monitor?.ignoreChangeCount(pb.changeCount)
            return true
        }
        guard !texts.isEmpty else {
            state.message("Selected clips have no text to combine")
            return false
        }
        var joined = MultiPaste.join(texts, separator: settings.multiPasteSeparator, reverse: settings.multiPasteReverse)
        if let transform { joined = apply(transform, to: joined) }
        let fmt = ClipFormat(type: ClipUTI.plainText, data: Data(joined.utf8))
        writeToPasteboard([fmt])
        if settings.saveMultiPaste {
            let desc = String(joined.drop(while: { $0.isWhitespace }).prefix(settings.descTextSize))
            var opts = ClipStore.AddOptions()
            opts.allowDuplicates = settings.allowDuplicates
            opts.allowBackToBackDuplicates = settings.allowBackToBackDuplicates
            _ = try? store.addClip(formats: [fmt], description: desc, sourceApp: Bundle.main.bundleIdentifier ?? "DittoMac",
                                   options: opts)
        }
        return true
    }

    private func apply(_ t: TextTransform, to s: String) -> String {
        if t == .plainText { return s }
        var rng = SystemRandomNumberGenerator()
        return t.apply(s, slugSeparator: settings.slugifySeparator, now: Date(), rng: &rng)
    }

    private func stitch(_ images: [CGImage], vertical: Bool) -> Data? {
        let width = vertical ? images.map(\.width).max() ?? 0 : images.reduce(0) { $0 + $1.width }
        let height = vertical ? images.reduce(0) { $0 + $1.height } : images.map(\.height).max() ?? 0
        guard width > 0, height > 0, width <= maxStitchDimension, height <= maxStitchDimension,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var offset = 0
        for img in images {
            let rect: CGRect
            if vertical {
                // CoreGraphics origin is bottom-left: first image goes on top.
                rect = CGRect(x: 0, y: height - offset - img.height, width: img.width, height: img.height)
                offset += img.height
            } else {
                rect = CGRect(x: offset, y: height - img.height, width: img.width, height: img.height)
                offset += img.width
            }
            ctx.draw(img, in: rect)
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    // MARK: Keyboard-layout-aware key code lookup

    /// Finds the virtual key code that produces `char` with ⌘ held in the current keyboard layout
    /// (so ⌘V works on Dvorak, AZERTY, "Dvorak – QWERTY ⌘", …). Falls back to the ANSI code.
    private static func keyCode(for char: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let target = String(char).lowercased()
        let kbdType = UInt32(LMGetKbdType())
        let cmdState = UInt32((cmdKey >> 8) & 0xFF)
        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), cmdState, kbdType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &len, &chars)
                if status == noErr, len > 0, String(utf16CodeUnits: chars, count: len).lowercased() == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
