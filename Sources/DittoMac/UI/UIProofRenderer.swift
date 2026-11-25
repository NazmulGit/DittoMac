// UIProofRenderer.swift — developer tool: `DittoMac --render-ui-proofs <dir>` renders the popup list, a sticky note and
// Preferences › Appearance OFFSCREEN (windows are never ordered front, the screen is never captured) with synthetic
// data in an in-memory database and a throw-away defaults suite, writes PNGs to <dir>, and exits. Used for the
// screenshots in docs/assets. It never touches the user's clip database or preferences.

import AppKit
import CryptoKit
import SwiftUI
import DittoCore

/// Vault stand-in for proofs: set up, locked or unlocked on demand, never prompts.
@MainActor
private final class ProofVault: VaultServicing {
    var isSetUp = true
    var method: VaultMethod = .system
    var isUnlocked: Bool { store.vaultKey != nil }
    var autoLockMinutes = 5
    let store: ClipStore
    let key: SymmetricKey
    init(store: ClipStore, key: SymmetricKey) { self.store = store; self.key = key }
    func requestUnlock(reason: String, completion: @escaping (Bool) -> Void) { completion(false) }
    func lockNow() { store.vaultKey = nil }
    func lock(clipIDs: [Int64], completion: @escaping (Bool) -> Void) { completion((try? store.lock(ids: clipIDs, key: key)) ?? 0 > 0) }
    func removeLock(clipIDs: [Int64], completion: @escaping (Bool) -> Void) { completion(false) }
    func configure(method: VaultMethod, newPassword: String?, completion: @escaping (Bool) -> Void) { completion(false) }
}

@MainActor
enum UIProofRenderer {
    static func run(outDir: URL) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let suite = "io.github.dittomac.ui-proofs.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return 1 }
        defer { defaults.removePersistentDomain(forName: suite) }
        let themesDir = FileManager.default.temporaryDirectory.appendingPathComponent("dittomac-proof-themes-\(UUID().uuidString)")
        CustomThemes.shared.directoryOverride = themesDir
        defer { try? FileManager.default.removeItem(at: themesDir) }

        let settings = DittoCore.Settings(defaults: defaults)
        settings.linesPerRow = 2
        settings.popupWidth = 400
        settings.popupHeight = 560
        guard let store = try? ClipStore.inMemory() else { return 1 }
        let key = Vault.newDataKey()
        let state = AppState(store: store, settings: settings)
        let vault = ProofVault(store: store, key: key)
        state.vault = vault
        seed(store: store, settings: settings, vault: vault)

        var outputs: [String: NSImage] = [:]
        for (label, dark, unlocked) in [("popup-light", false, false), ("popup-dark", true, false), ("popup-dark-unlocked", true, true)] {
            store.vaultKey = unlocked ? key : nil
            if let img = renderPopup(state: state, dark: dark) {
                outputs[label] = img
                write(img, outDir.appendingPathComponent("\(label).png"))
            }
        }
        store.vaultKey = nil
        // A themed variant (Nord + custom accent, compact density, keycap numbers).
        settings.rowDensity = .compact
        settings.firstTenStyle = .keycap
        AppTheme.current = AppTheme(spec: ThemeData.named("Nord"), accentHex: "#5E81AC")
        if let img = renderPopup(state: state, dark: true, keepTheme: true) {
            outputs["popup-nord"] = img
            write(img, outDir.appendingPathComponent("popup-nord.png"))
        }
        settings.rowDensity = .comfortable
        settings.firstTenStyle = .badge

        for (label, dark, locked) in [("note-light", false, false), ("note-dark", true, false), ("note-locked", false, true)] {
            store.vaultKey = locked ? nil : key
            let id = locked ? noteLockedID : noteID
            if let img = renderNote(state: state, clipID: id, dark: dark) {
                outputs[label] = img
                write(img, outDir.appendingPathComponent("\(label).png"))
            }
        }
        store.vaultKey = nil
        AppTheme.current = AppTheme(spec: ThemeData.system, accentHex: "")
        if let img = renderAppearanceTab(state: state, dark: false) {
            outputs["prefs-appearance"] = img
            write(img, outDir.appendingPathComponent("prefs-appearance.png"))
        }
        if let comp = composite(outputs) {
            write(comp, outDir.appendingPathComponent("ui-v12.png"))
        }
        print("UI proofs written to \(outDir.path)")
        return 0
    }

    // MARK: Data

    private static var noteID: Int64 = 0
    private static var noteLockedID: Int64 = 0

    private static func add(_ store: ClipStore, _ text: String, rtf: Data? = nil, png: Data? = nil, app: String = "com.apple.Safari",
                            minutesAgo: Double, sticky: Bool = false) -> Int64 {
        var formats: [ClipFormat] = []
        if !text.isEmpty { formats.append(ClipFormat(type: ClipUTI.plainText, data: Data(text.utf8))) }
        if let rtf { formats.append(ClipFormat(type: ClipUTI.rtf, data: rtf)) }
        if let png { formats.append(ClipFormat(type: ClipUTI.png, data: png)) }
        var opts = ClipStore.AddOptions()
        opts.allowDuplicates = true
        opts.makeTopSticky = sticky
        guard case .inserted(let id) = (try? store.addClip(formats: formats, description: text.isEmpty ? "Image 640×400" : String(text.prefix(300)),
                                                           sourceApp: app, options: opts)) ?? .rejected,
              var c = try? store.clip(id: id) else { return 0 }
        c.date = Date().addingTimeInterval(-minutesAgo * 60)
        c.lastPasteDate = c.date
        try? store.update(c)
        return id
    }

    private static func seed(store: ClipStore, settings: DittoCore.Settings, vault: ProofVault) {
        let rich = NSAttributedString(string: "Quarterly report — revenue up 12%, churn down", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13)])
        let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])
        // Oldest first (each add goes on top).
        _ = add(store, "brew install --cask dittomac\nswift build -c release", app: "com.apple.Terminal", minutesAgo: 60 * 30)
        _ = add(store, "#0A84FF", app: "com.figma.Desktop", minutesAgo: 60 * 26)
        _ = add(store, "", png: sampleImage(), app: "com.apple.Preview", minutesAgo: 60 * 5)
        let pasted = add(store, "https://github.com/sabrogden/Ditto", app: "com.apple.Safari", minutesAgo: 95)
        if var p = try? store.clip(id: pasted) { p.lastPasteDate = Date(); try? store.update(p) }
        _ = add(store, rich.string, rtf: rtf, app: "com.apple.iWork.Pages", minutesAgo: 42)
        let secret = add(store, "Wi-Fi: Studio-5G  password: correct horse battery staple", app: "com.apple.Notes", minutesAgo: 20)
        _ = add(store, "Thanks! I’ll send the signed copy tonight.", app: "com.apple.MobileSMS", minutesAgo: 4)
        noteLockedID = add(store, "Bank PIN reminder and recovery codes", app: StickyNoteMarker.sourceApp, minutesAgo: 60 * 50, sticky: true)
        noteID = add(store, "Stand-up 9:30 — ship v1.2 🚀\n• locked notes • sticky notes • themes", app: StickyNoteMarker.sourceApp,
                     minutesAgo: 60 * 3, sticky: true)
        settings.setNoteColor(.yellow, for: noteID)
        settings.setNoteColor(.pink, for: noteLockedID)
        _ = try? store.lock(ids: [secret, noteLockedID], key: vault.key)
    }

    private static func sampleImage() -> Data? {
        let size = NSSize(width: 320, height: 200)
        let img = NSImage(size: size, flipped: false) { r in
            NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.55, blue: 0.35, alpha: 1),
                                NSColor(srgbRed: 0.45, green: 0.35, blue: 0.95, alpha: 1)])?.draw(in: r, angle: 35)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 30, y: 40, width: 90, height: 90)).fill()
            NSBezierPath(roundedRect: NSRect(x: 140, y: 60, width: 150, height: 22), xRadius: 6, yRadius: 6).fill()
            NSBezierPath(roundedRect: NSRect(x: 140, y: 100, width: 110, height: 22), xRadius: 6, yRadius: 6).fill()
            return true
        }
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Rendering

    private static func snapshot(_ view: NSView, appearance: NSAppearance?) -> NSImage? {
        view.layoutSubtreeIfNeeded()
        var out: NSImage?
        let draw = {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let img = NSImage(size: view.bounds.size)
            img.addRepresentation(rep)
            out = img
        }
        if let appearance { appearance.performAsCurrentDrawingAppearance(draw) } else { draw() }
        return out
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func renderPopup(state: AppState, dark: Bool, keepTheme: Bool = false) -> NSImage? {
        if !keepTheme { AppTheme.current = AppTheme(spec: ThemeData.system, accentHex: "") }
        let qp = QuickPasteController(state: state)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        qp.panel.setFrame(NSRect(x: -10_000, y: -10_000, width: 400, height: 560), display: false)
        qp.applySettings()
        qp.splitView.adjustSubviews()
        qp.panel.appearance = keepTheme ? AppTheme.current.appearance : appearance
        qp.reload(keepSelection: false)
        spin(0.4)            // thumbnails are generated off the main thread
        qp.reload(keepSelection: false)
        qp.splitView.adjustSubviews()
        qp.tableView.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        qp.updateStatus()
        guard let content = qp.panel.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        qp.tableView.layoutSubtreeIfNeeded()
        for r in 0..<qp.tableView.numberOfRows {
            if let rv = qp.tableView.rowView(atRow: r, makeIfNecessary: true) { rv.isEmphasized = true }
        }
        let img = snapshot(content, appearance: qp.panel.appearance ?? appearance)
        NotificationCenter.default.removeObserver(qp)
        return img.map { framed($0, title: "DittoMac", dark: keepTheme ? AppTheme.current.spec.isDark : dark) }
    }

    private static func renderNote(state: AppState, clipID: Int64, dark: Bool) -> NSImage? {
        let c = StickyNoteWindowController(state: state, clipID: clipID)
        guard let w = c.window, let content = w.contentView else { return nil }
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.setFrame(NSRect(x: -10_000, y: -10_000, width: 280, height: 230), display: false)
        c.applyColors()
        let img = snapshot(content, appearance: w.appearance)
        return img.map { noteFramed($0) }
    }

    private static func renderAppearanceTab(state: AppState, dark: Bool) -> NSImage? {
        let model = PrefsModel(state: state)
        let host = NSHostingView(rootView: AppearancePrefs(m: model).frame(width: 600, height: 1500))
        let w = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 1500), styleMask: [.borderless],
                         backing: .buffered, defer: true)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 1500)
        spin(0.3)
        return snapshot(host, appearance: w.appearance)
    }

    // MARK: Composition

    /// Adds a macOS-like title bar (traffic lights + title) over the transparent top band of a popup render.
    private static func framed(_ content: NSImage, title: String, dark: Bool) -> NSImage {
        let size = content.size
        return NSImage(size: size, flipped: false) { r in
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
            r.fill()
            content.draw(in: r)
            let barH: CGFloat = 28
            let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
            for (i, c) in colors.enumerated() {
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: 12 + CGFloat(i) * 20, y: r.maxY - barH / 2 - 6, width: 12, height: 12)).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                        .foregroundColor: dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.25, alpha: 1)]
            let ts = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.maxY - barH / 2 - ts.height / 2), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    private static func noteFramed(_ content: NSImage) -> NSImage {
        NSImage(size: content.size, flipped: false) { r in
            let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            content.draw(in: r)
            let colors: [NSColor] = [.systemRed, NSColor(white: 0.75, alpha: 1), NSColor(white: 0.75, alpha: 1)]
            for (i, c) in colors.enumerated() where i == 0 {
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: 10 + CGFloat(i) * 20, y: r.maxY - 14 - 6, width: 12, height: 12)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.2).setStroke()
            path.stroke()
            return true
        }
    }

    private static func composite(_ o: [String: NSImage]) -> NSImage? {
        guard let light = o["popup-light"], let dark = o["popup-dark"] else { return nil }
        let pad: CGFloat = 36
        let prefs = o["prefs-appearance"]
        let prefsW: CGFloat = 430
        let prefsH: CGFloat = prefs.map { min($0.size.height * prefsW / $0.size.width, light.size.height * 1.42) } ?? 0
        let noteW: CGFloat = 280
        let width = pad + light.size.width + pad + dark.size.width + pad + noteW + pad + (prefs == nil ? 0 : prefsW + pad)
        let height = pad * 3.4 + max(light.size.height + 40, prefsH)
        let canvas = NSImage(size: NSSize(width: width, height: height), flipped: true) { r in
            NSGradient(colors: [NSColor(srgbRed: 0.90, green: 0.92, blue: 0.97, alpha: 1),
                                NSColor(srgbRed: 0.80, green: 0.84, blue: 0.93, alpha: 1)])?.draw(in: r, angle: 90)
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .bold),
                                                             .foregroundColor: NSColor(white: 0.12, alpha: 1)]
            ("DittoMac 1.2 — locked notes, sticky notes, appearance" as NSString).draw(at: NSPoint(x: pad, y: 22), withAttributes: titleAttrs)
            let capAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                           .foregroundColor: NSColor(white: 0.3, alpha: 1)]
            func shadowed(_ img: NSImage, _ rect: NSRect, _ caption: String) {
                NSGraphicsContext.saveGraphicsState()
                let sh = NSShadow()
                sh.shadowBlurRadius = 18
                sh.shadowOffset = NSSize(width: 0, height: -6)
                sh.shadowColor = NSColor.black.withAlphaComponent(0.28)
                sh.set()
                img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
                NSGraphicsContext.restoreGraphicsState()
                (caption as NSString).draw(at: NSPoint(x: rect.minX, y: rect.maxY + 10), withAttributes: capAttrs)
            }
            let top = pad * 2
            var x = pad
            shadowed(light, NSRect(x: x, y: top, width: light.size.width, height: light.size.height), "Light · locked note hidden, sticky notes on top")
            x += light.size.width + pad
            shadowed(dark, NSRect(x: x, y: top, width: dark.size.width, height: dark.size.height), "Dark · rounded selection, badges, timestamps")
            x += dark.size.width + pad
            var y = top
            for (key, cap) in [("note-light", "Desktop note"), ("note-locked", "Locked desktop note")] {
                if let n = o[key] {
                    let h = n.size.height * noteW / n.size.width
                    shadowed(n, NSRect(x: x, y: y, width: noteW, height: h), cap)
                    y += h + 46
                }
            }
            if let nord = o["popup-nord"] {
                let h = min(nord.size.height * noteW / nord.size.width, top + light.size.height - y)
                let w = nord.size.width * h / nord.size.height
                if h > 120 { shadowed(nord, NSRect(x: x, y: y, width: w, height: h), "Nord theme · compact · ⌘-keycaps") }
            }
            x += noteW + pad
            if let prefs {
                let src = NSRect(x: 0, y: prefs.size.height - prefsH * prefs.size.width / prefsW, width: prefs.size.width,
                                 height: prefsH * prefs.size.width / prefsW)
                let dst = NSRect(x: x, y: top, width: prefsW, height: prefsH)
                NSGraphicsContext.saveGraphicsState()
                let sh = NSShadow()
                sh.shadowBlurRadius = 18
                sh.shadowColor = NSColor.black.withAlphaComponent(0.25)
                sh.set()
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: dst, xRadius: 10, yRadius: 10).fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: dst, xRadius: 10, yRadius: 10).addClip()
                prefs.draw(in: dst, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
                NSGraphicsContext.restoreGraphicsState()
                ("Preferences › Appearance" as NSString).draw(at: NSPoint(x: dst.minX, y: dst.maxY + 10), withAttributes: capAttrs)
            }
            return true
        }
        return canvas
    }

    private static func write(_ img: NSImage, _ url: URL) {
        let scale: CGFloat = 2
        let px = NSSize(width: img.size.width * scale, height: img.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: img.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
