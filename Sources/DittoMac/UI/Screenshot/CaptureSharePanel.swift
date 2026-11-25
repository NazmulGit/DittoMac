// CaptureSharePanel.swift — after Upload / Share / Search similar: upload progress, the link (copied automatically),
// macOS share picker, web-intent networks (ShareLinks) and reverse image search. Shown after the overlay closed, as a
// normal floating panel, so menus and pickers are never hidden behind the screen-saver-level overlay.

import AppKit
import SwiftUI
import DittoCore

@MainActor
final class CaptureShareModel: ObservableObject {
    enum Phase: Equatable { case ready, uploading(Double), done(URL), failed(String) }
    enum After: Equatable { case nothing, searchSimilar, network(ShareNetwork) }

    @Published var phase: Phase = .ready
    let image: CGImage
    let thumbnail: NSImage
    let title: String
    var pending: After = .nothing
    var upload: (() -> Void)?
    var shareFileURL: (() -> URL?)?
    var close: (() -> Void)?

    init(image: CGImage) {
        self.image = image
        thumbnail = NSImage(cgImage: image, size: .zero)
        title = "Screenshot \(image.width) × \(image.height)"
    }

    /// Late progress callbacks (they hop to the main actor) must never overwrite `.done`, `.failed` or a cancel.
    func updateProgress(_ p: Double) {
        guard isUploading else { return }
        phase = .uploading(min(max(p, 0), 1))
    }

    var link: URL? { if case .done(let u) = phase { return u } else { return nil } }
    var isUploading: Bool { if case .uploading = phase { return true } else { return false } }

    func open(_ url: URL?) {
        guard let url, url.scheme?.lowercased() == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    /// Runs `after` now if a link exists, otherwise uploads first.
    func perform(_ after: After) {
        if let link {
            switch after {
            case .nothing: break
            case .searchSimilar: open(ShareLinks.similarImageSearch(link: link))
            case .network(let n): open(ShareLinks.url(for: n, link: link, title: title))
            }
        } else if !isUploading {
            pending = after
            upload?()
        }
    }
}

@MainActor
final class CaptureSharePanel: NSObject, NSWindowDelegate {
    private static var open: [CaptureSharePanel] = []
    private let panel: NSPanel
    let model: CaptureShareModel
    private unowned let state: AppState
    private let output: ScreenshotOutput
    private var task: UploadTask?
    private var addedToHistory = false
    private var tempFile: URL?

    /// Shows the panel for `image`. `autoUpload` starts uploading at once, then runs `after`.
    @discardableResult
    static func show(image: CGImage, state: AppState, output: ScreenshotOutput, autoUpload: Bool,
                     after: CaptureShareModel.After = .nothing) -> CaptureSharePanel {
        let p = CaptureSharePanel(image: image, state: state, output: output)
        open.append(p)
        p.present()
        if autoUpload { p.model.perform(after) }
        return p
    }

    private init(image: CGImage, state: AppState, output: ScreenshotOutput) {
        self.state = state
        self.output = output
        model = CaptureShareModel(image: image)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.title = "Share Screenshot"
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        model.upload = { [weak self] in self?.startUpload() }
        model.shareFileURL = { [weak self] in self?.shareFile() }
        model.close = { [weak self] in self?.panel.close() }
        let host = NSHostingView(rootView: CaptureShareView(model: model))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    private func present() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let s = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - s.width - 20, y: vf.maxY - s.height - 20))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        if let tempFile { try? FileManager.default.removeItem(at: tempFile.deletingLastPathComponent()) }
        Self.open.removeAll { $0 === self }
    }

    private func recordHistory() {
        guard !addedToHistory else { return }
        addedToHistory = true
        output.addToHistory(model.image)
    }

    /// Temporary PNG for the macOS share picker (AirDrop, Mail, Messages …), removed when the panel closes.
    private func shareFile() -> URL? {
        if let tempFile { return tempFile }
        guard let data = ScreenshotOutput.png(model.image) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DittoMac-Share-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = dir.appendingPathComponent(output.suggestedBaseName() + ".png")
            try data.write(to: url, options: .atomic)
            tempFile = url
            recordHistory()
            return url
        } catch { return nil }
    }

    private func startUpload() {
        guard !model.isUploading else { return }
        let uploader = ImageUploader.shared
        uploader.ensureReady(state: state) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.model.phase = .failed("Uploading isn't set up yet. Choose a provider in Preferences › Screenshots › Upload & Share.")
                self.model.pending = .nothing
                return
            }
            guard let enc = self.output.encodedForUpload(self.model.image) else {
                self.model.phase = .failed("Couldn't encode the screenshot."); return
            }
            self.model.phase = .uploading(0)
            let name = self.output.suggestedBaseName() + "." + enc.format.fileExtension
            self.task = uploader.upload(data: enc.data, filename: name, mimeType: enc.format.mimeType, progress: { [weak self] p in
                Task { @MainActor in self?.model.updateProgress(p) }
            }, completion: { [weak self] result in
                Task { @MainActor in self?.finishUpload(result) }
            })
        }
    }

    private func finishUpload(_ result: Result<UploadedImage, Error>) {
        task = nil
        switch result {
        case .success(let up):
            model.phase = .done(up.url)
            state.paste.writeToPasteboard([ClipFormat(type: ClipUTI.plainText, data: Data(up.url.absoluteString.utf8))])
            state.message("Link copied: \(up.url.absoluteString)")
            recordHistory()
            let after = model.pending
            model.pending = .nothing
            model.perform(after)
        case .failure(let e):
            model.pending = .nothing
            if case UploadError.cancelled = e { model.phase = .ready; return }
            model.phase = .failed(e.localizedDescription)
        }
    }
}

// MARK: - SwiftUI content

struct CaptureShareView: View {
    @ObservedObject var model: CaptureShareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: model.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 64)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title).font(.headline)
                    status
                }
                Spacer(minLength: 0)
            }

            if let link = model.link {
                HStack(spacing: 6) {
                    Text(link.absoluteString)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    }
                    Button("Open") { model.open(link) }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Share on").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(ShareNetwork.allCases, id: \.self) { n in
                        Button(n.title) { model.perform(.network(n)) }
                            .frame(maxWidth: .infinity)
                            .disabled(model.isUploading)
                    }
                }
            }

            HStack {
                SharePickerButton(title: "Share…") { model.shareFileURL?() }
                Button("Search Similar") { model.perform(.searchSimilar) }.disabled(model.isUploading)
                if model.link == nil {
                    Button("Upload") { model.perform(.nothing) }.disabled(model.isUploading)
                }
                Spacer()
                Button("Done") { model.close?() }.keyboardShortcut(.cancelAction)
            }
            Text("Uploaded images are public to anyone who has the link. Networks and Search Similar upload first.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .padding(.top, 14)
        .frame(width: 400)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .ready:
            Text("Upload to get a link, or share the image directly.").font(.caption).foregroundStyle(.secondary)
        case .uploading(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p).frame(width: 200)
                Text("Uploading…").font(.caption).foregroundStyle(.secondary)
            }
        case .done:
            Label("Link copied to the clipboard", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let m):
            Text(m).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// NSButton that shows NSSharingServicePicker anchored to itself (SwiftUI has no anchor view on macOS 13).
struct SharePickerButton: NSViewRepresentable {
    let title: String
    let item: () -> URL?

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let b = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        context.coordinator.item = item
        return b
    }
    func updateNSView(_ b: NSButton, context: Context) { context.coordinator.item = item }

    @MainActor final class Coordinator: NSObject {
        var item: (() -> URL?)?
        @objc func tap(_ sender: NSButton) {
            guard let url = item?() else { NSSound.beep(); return }
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
