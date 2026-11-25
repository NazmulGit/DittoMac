// ScreenshotOutput.swift — what happens to finished pixels: encode, copy (+ history), save, print, sound.
import AppKit
import UniformTypeIdentifiers
import DittoCore

@MainActor
final class ScreenshotOutput {
    unowned let state: AppState
    init(state: AppState) { self.state = state }

    private var settings: DittoCore.Settings { state.settings }

    // MARK: encoding

    static func encode(_ image: CGImage, format: ScreenshotFormat, jpegQuality: Double) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpg:
            return rep.representation(using: .jpeg, properties: [.compressionFactor: ScreenshotGeometry.clampJPEGQuality(jpegQuality)])
        case .bmp: return rep.representation(using: .bmp, properties: [:])
        }
    }

    static func png(_ image: CGImage) -> Data? { encode(image, format: .png, jpegQuality: 1) }

    func encodedForUpload(_ image: CGImage) -> (data: Data, format: ScreenshotFormat)? {
        // BMP is a poor web format: upload PNG instead.
        let f: ScreenshotFormat = settings.screenshotFormat == .jpg ? .jpg : .png
        return Self.encode(image, format: f, jpegQuality: settings.screenshotJPEGQuality).map { ($0, f) }
    }

    // MARK: copy + history

    /// Writes PNG to the pasteboard (tagged internal) and adds it to history once per capture.
    @discardableResult
    func copy(_ image: CGImage, addHistory: Bool = true) -> Bool {
        guard let data = Self.png(image) else { state.message("Couldn't encode the screenshot."); return false }
        state.paste.writeToPasteboard([ClipFormat(type: ClipUTI.png, data: data)])
        if addHistory { addToHistory(png: data, size: CGSize(width: image.width, height: image.height)) }
        return true
    }

    /// Adds the PNG to the clip history (Quick Paste), when enabled.
    func addToHistory(png data: Data, size: CGSize) {
        guard settings.screenshotAddToHistory else { return }
        do {
            switch try state.store.addClip(formats: [ClipFormat(type: ClipUTI.png, data: data)],
                                           description: "Screenshot \(Int(size.width))×\(Int(size.height))",
                                           sourceApp: "screenshot") {
            case .rejected:
                state.message("Screenshot is too large for the clip history — it wasn’t added")
            case .inserted, .duplicateBumped:
                state.clipsChanged()
            }
        } catch {
            NSLog("DittoMac: couldn't add screenshot to history: \(error.localizedDescription)")
        }
    }

    /// `png`: bytes already encoded as PNG (the Save path), so the image isn't encoded a second time.
    func addToHistory(_ image: CGImage, png: Data? = nil) {
        guard settings.screenshotAddToHistory else { return }
        guard let data = png ?? Self.png(image) else { return }
        addToHistory(png: data, size: CGSize(width: image.width, height: image.height))
    }

    // MARK: save

    /// Creates the auto-save folder (0700) if needed.
    static func ensureFolder(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw CocoaError(.fileWriteFileExists) }
            return url
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    func suggestedBaseName(date: Date = Date()) -> String {
        ScreenshotFileName.format(template: settings.screenshotNameTemplate, date: date)
    }

    /// Saves per settings (panel or straight into the folder). completion(url) or nil when cancelled/failed.
    func save(_ image: CGImage, completion: ((URL?) -> Void)? = nil) {
        let format = settings.screenshotFormat
        guard let data = Self.encode(image, format: format, jpegQuality: settings.screenshotJPEGQuality) else {
            state.message("Couldn't encode the screenshot."); completion?(nil); return
        }
        let base = suggestedBaseName()
        let historyPNG: Data? = format == .png ? data : nil      // reuse the encoded bytes for the history entry
        if settings.screenshotAskWhereToSave {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.title = "Save Screenshot"
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            if let t = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [t] }
            panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
            if let dir = try? Self.ensureFolder(settings.screenshotSaveFolder) { panel.directoryURL = dir }
            panel.level = .modalPanel
            guard panel.runModal() == .OK, let url = panel.url else { completion?(nil); return }
            // The panel already confirmed any replacement with the user.
            write(data, to: url, image: image, historyPNG: historyPNG, completion: completion)
        } else {
            do {
                let dir = try Self.ensureFolder(settings.screenshotSaveFolder)
                writeNew(data, in: dir, base: base, ext: format.fileExtension, image: image, historyPNG: historyPNG, completion: completion)
            } catch {
                state.message("Couldn't create the screenshot folder: \(error.localizedDescription)")
                completion?(nil)
            }
        }
    }

    /// Auto-save: never overwrites, even if a file with the chosen name appears between the check and the write.
    private func writeNew(_ data: Data, in dir: URL, base: String, ext: String, image: CGImage, historyPNG: Data?,
                          completion: ((URL?) -> Void)?) {
        for _ in 0..<5 {
            let url = ScreenshotFileName.uniqueURL(in: dir, base: base, ext: ext)
            do {
                try data.write(to: url, options: [.withoutOverwriting])
                state.message("Saved \(url.lastPathComponent)")
                addToHistory(image, png: historyPNG)
                completion?(url)
                return
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                state.message("Couldn't save the screenshot: \(error.localizedDescription)")
                completion?(nil)
                return
            }
        }
        state.message("Couldn't save the screenshot: a file with that name already exists.")
        completion?(nil)
    }

    private func write(_ data: Data, to url: URL, image: CGImage, historyPNG: Data?, completion: ((URL?) -> Void)?) {
        do {
            try data.write(to: url, options: [.atomic])
            state.message("Saved \(url.lastPathComponent)")
            addToHistory(image, png: historyPNG)
            completion?(url)
        } catch {
            state.message("Couldn't save the screenshot: \(error.localizedDescription)")
            completion?(nil)
        }
    }

    // MARK: print

    func print(_ image: CGImage) {
        NSApp.activate(ignoringOtherApps: true)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: image, size: size)
        view.imageScaling = .scaleProportionallyDown
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.orientation = size.width > size.height ? .landscape : .portrait
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = suggestedBaseName()
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        // Only a completed print goes to history; cancelling the print panel returns false.
        if op.run() { addToHistory(image) }
    }

    // MARK: sound

    private static let shutterCandidates = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
        "/System/Library/Sounds/Tink.aiff",
    ]
    private static var shutter: NSSound? = {
        for p in shutterCandidates where FileManager.default.fileExists(atPath: p) {
            if let s = NSSound(contentsOfFile: p, byReference: true) { return s }
        }
        return NSSound(named: "Tink")
    }()

    func playShutter() {
        guard settings.screenshotPlaySound else { return }
        Self.shutter?.stop()
        Self.shutter?.play()
    }
}
