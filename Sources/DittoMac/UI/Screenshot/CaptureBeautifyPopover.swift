// CaptureBeautifyPopover.swift — per-capture Beautify toggle + BeautifyControls + live preview (BeautifyRenderer).
import AppKit
import SwiftUI
import DittoCore

@MainActor
final class CaptureBeautifyModel: ObservableObject {
    @Published var enabled: Bool { didSet { onChange?() } }
    @Published var style: BeautifyStyle { didSet { schedulePreview(); onChange?() } }
    @Published private(set) var preview: NSImage?
    /// Called on any change (the session refreshes the action bar's toggle state).
    var onChange: (() -> Void)?
    /// Supplies the current (annotated) selection and its pixel scale for the preview.
    var source: (() -> (CGImage, CGFloat)?)?
    private var work: DispatchWorkItem?

    init(enabled: Bool, style: BeautifyStyle) {
        self.enabled = enabled
        self.style = style
    }

    /// The same default as Preferences (`settings.beautifyDefaultStyle`: the saved style, else the first preset).
    static func defaultStyle(_ settings: DittoCore.Settings) -> BeautifyStyle { settings.beautifyDefaultStyle }

    func schedulePreview() {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.renderPreview() } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: w)
    }

    func renderPreview() {
        guard let (img, scale) = source?() else { preview = nil; return }
        let (thumb, thumbScale) = Self.downscale(img, maxSide: 360)
        let out = BeautifyRenderer.render(thumb, pixelScale: max(scale * thumbScale, 0.1), style: style)
        preview = NSImage(cgImage: out, size: .zero)
    }

    static func downscale(_ img: CGImage, maxSide: CGFloat) -> (CGImage, CGFloat) {
        let s = min(1, maxSide / CGFloat(max(img.width, img.height)))
        guard s < 1 else { return (img, 1) }
        let w = max(1, Int(CGFloat(img.width) * s)), h = max(1, Int(CGFloat(img.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (img, 1) }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (ctx.makeImage() ?? img, s)
    }
}

struct CaptureBeautifyView: View {
    @ObservedObject var model: CaptureBeautifyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Beautify this screenshot", isOn: $model.enabled)
                .toggleStyle(.switch)
                .font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
                if let p = model.preview {
                    Image(nsImage: p).resizable().aspectRatio(contentMode: .fit).padding(6)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 170)
            .opacity(model.enabled ? 1 : 0.45)
            BeautifyControls(style: $model.style)
                .disabled(!model.enabled)
            Text("The default style and “apply to every screenshot” are in Preferences › Screenshots › Beautify.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.renderPreview() }
    }
}

@MainActor
enum CaptureBeautifyPopover {
    static func show(model: CaptureBeautifyModel, relativeTo view: NSView) -> NSPopover {
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = NSHostingController(rootView: CaptureBeautifyView(model: model))
        pop.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        return pop
    }
}
