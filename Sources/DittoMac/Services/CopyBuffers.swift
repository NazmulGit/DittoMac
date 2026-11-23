// CopyBuffers.swift — five "copy buffers": global hotkeys that copy/cut the current selection into a numbered
// slot (stored as a normal clip with sourceApp "copybuffer") and paste a slot, preserving the user's pasteboard.

import AppKit
import DittoCore
import Foundation

@MainActor
final class CopyBuffers: CopyBuffersServicing {
    static let bufferCount = 5
    static let slotsKey = "copyBuffers.slots"
    static let sourceApp = "copybuffer"

    private typealias Snapshot = [[(type: NSPasteboard.PasteboardType, data: Data)]]

    private let state: AppState
    private var busy = false
    private var observer: NSObjectProtocol?

    init(state: AppState) {
        self.state = state
        reloadHotkeys()
        observer = NotificationCenter.default.addObserver(forName: .dittoHotkeysChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadHotkeys() }
        }
    }

    // MARK: hotkeys

    func reloadHotkeys() {
        state.hotkeys.unregisterAll(withPrefix: "buffer")
        for i in 1 ... Self.bufferCount {
            for kind in ["copy", "paste", "cut"] {
                let name = "buffer\(i).\(kind)"
                let v = state.settings.hotkey(name)
                guard v != 0 else { continue }
                state.hotkeys.register(name: name, combo: KeyCombo(encoded: v)) { [weak self] in
                    switch kind {
                    case "copy": self?.copyToBuffer(i, cut: false)
                    case "cut": self?.copyToBuffer(i, cut: true)
                    default: self?.pasteBuffer(i)
                    }
                }
            }
        }
    }

    // MARK: slot mapping

    private func slotClipID(_ i: Int) -> Int64? {
        let d = UserDefaults.standard.dictionary(forKey: Self.slotsKey) ?? [:]
        guard let n = d["\(i)"] as? NSNumber else { return nil }
        return n.int64Value
    }

    private func setSlotClipID(_ i: Int, _ id: Int64) {
        var d = UserDefaults.standard.dictionary(forKey: Self.slotsKey) ?? [:]
        d["\(i)"] = NSNumber(value: id)
        UserDefaults.standard.set(d, forKey: Self.slotsKey)
    }

    // MARK: pasteboard snapshot / restore

    private func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            item.types.filter { $0 != dittoInternalPasteboardType }.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
    }

    private func restore(_ snap: Snapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        var items = [NSPasteboardItem]()
        for entry in snap where !entry.isEmpty {
            let item = NSPasteboardItem()
            for (t, d) in entry { item.setData(d, forType: t) }
            items.append(item)
        }
        if items.isEmpty {
            let marker = NSPasteboardItem()
            marker.setData(Data(), forType: dittoInternalPasteboardType)
            items.append(marker)
        } else {
            items[0].setData(Data(), forType: dittoInternalPasteboardType)
        }
        pb.writeObjects(items)
        state.monitor.ignoreChangeCount(pb.changeCount)
    }

    // MARK: capture

    private func formatsFromPasteboard(_ pb: NSPasteboard) -> [ClipFormat] {
        let maxBytes = 32 * 1024 * 1024
        let items = pb.pasteboardItems ?? []
        var out = [ClipFormat]()
        func first(_ type: String) -> Data? {
            for it in items { if let d = it.data(forType: NSPasteboard.PasteboardType(type)), !d.isEmpty, d.count <= maxBytes { return d } }
            return nil
        }
        for t in [ClipUTI.plainText, ClipUTI.rtf, ClipUTI.html, ClipUTI.png] {
            if let d = first(t) { out.append(ClipFormat(type: t, data: d)) }
        }
        if !out.contains(where: { $0.type == ClipUTI.png }), let tiff = first(ClipUTI.tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            out.append(ClipFormat(type: ClipUTI.png, data: png))
        }
        let urls = items.compactMap { $0.string(forType: NSPasteboard.PasteboardType(ClipUTI.fileURL)) }
        if !urls.isEmpty { out.append(ClipFormat(type: ClipUTI.fileURL, data: Data(urls.joined(separator: "\n").utf8))) }
        return out
    }

    private func description(for formats: [ClipFormat], slot: Int) -> String {
        var preview = ""
        if let t = formats.first(where: { $0.type == ClipUTI.plainText }), let s = String(data: t.data, encoding: .utf8) {
            preview = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        } else if formats.contains(where: { $0.type == ClipUTI.png }) {
            preview = "(image)"
        } else if formats.contains(where: { $0.type == ClipUTI.fileURL }) {
            preview = "(files)"
        }
        return "[Buffer \(slot)] " + String(preview.prefix(500))
    }

    private func copyToBuffer(_ slot: Int, cut: Bool) {
        guard !busy else { return }
        busy = true
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        Task { @MainActor in
            defer { busy = false }
            try? await Task.sleep(nanoseconds: 150_000_000)          // let the user release the hotkey modifiers
            state.paste.postCommandKey(cut ? "x" : "c")
            var waited = 0.0
            while pb.changeCount == before && waited < 1.5 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                waited += 0.01
            }
            guard pb.changeCount != before else { return }          // nothing was copied; pasteboard untouched
            state.monitor.ignoreChangeCount(pb.changeCount)
            try? await Task.sleep(nanoseconds: 60_000_000)          // apps may write several types in a burst
            state.monitor.ignoreChangeCount(pb.changeCount)
            let formats = formatsFromPasteboard(pb)
            if formats.isEmpty {
                state.message("Copy buffer \(slot): nothing to store")
            } else {
                store(formats, slot: slot)
                playSound()
            }
            restore(saved)
        }
    }

    private func store(_ formats: [ClipFormat], slot: Int) {
        let desc = description(for: formats, slot: slot)
        do {
            if let id = slotClipID(slot), (try? state.store.clip(id: id)) != nil {
                try state.store.replaceFormats(clipID: id, formats: formats, description: desc)
                if var c = try state.store.clip(id: id), !c.dontAutoDelete {
                    c.dontAutoDelete = true
                    try state.store.update(c)
                }
            } else {
                var opts = ClipStore.AddOptions()
                opts.allowDuplicates = true
                opts.allowBackToBackDuplicates = true
                switch try state.store.addClip(formats: formats, description: desc, sourceApp: Self.sourceApp, options: opts) {
                case .inserted(let id), .duplicateBumped(let id):
                    setSlotClipID(slot, id)
                    if var c = try state.store.clip(id: id) {
                        c.dontAutoDelete = true
                        try state.store.update(c)
                    }
                case .rejected: state.message("Copy buffer \(slot): clip rejected"); return
                }
            }
            state.clipsChanged()
        } catch {
            state.message("Copy buffer \(slot): could not save")
        }
    }

    private func playSound() {
        let name = state.settings.playSoundOnCopy
        guard !name.isEmpty else { return }
        (NSSound(named: NSSound.Name(name)) ?? NSSound(contentsOfFile: name, byReference: true))?.play()
    }

    // MARK: paste

    private func pasteBuffer(_ slot: Int) {
        guard !busy else { return }
        guard let id = slotClipID(slot), let formats = try? state.store.formats(clipID: id), !formats.isEmpty else {
            state.message("Copy buffer \(slot) is empty"); return
        }
        busy = true
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let written = state.paste.writeToPasteboard(formats)
        state.monitor.ignoreChangeCount(written)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)          // let the user release the hotkey modifiers
            state.paste.postCommandKey("v")
            try? await Task.sleep(nanoseconds: 750_000_000)
            if pb.changeCount == written { restore(saved) }          // don't clobber a copy made in the meantime
            busy = false
        }
    }
}
