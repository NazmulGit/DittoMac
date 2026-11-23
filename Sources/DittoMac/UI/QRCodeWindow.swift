import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import DittoCore

/// Local-only QR code generator window (CoreImage; nothing leaves the machine).
@MainActor
final class QRCodeWindowController: NSWindowController, NSWindowDelegate {
    static let maxBytes = 2953
    private let imageView = NSImageView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var qrImage: NSImage?
    var onClose: (() -> Void)?

    init(text: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "QR Code"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 280, height: 340)
        super.init(window: w)
        w.delegate = self
        buildUI()
        setText(text)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setAccessibilityLabel("QR code")
        errorLabel.textColor = .systemRed
        errorLabel.alignment = .center
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        let copy = NSButton(title: "Copy Image", target: self, action: #selector(copyImage))
        let save = NSButton(title: "Save PNG…", target: self, action: #selector(savePNG))
        let row = NSStackView(views: [copy, save]); row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        copyButton = copy; saveButton = save
        content.addSubview(imageView); content.addSubview(errorLabel); content.addSubview(row)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            imageView.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -12),
            errorLabel.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: imageView.widthAnchor),
            row.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }
    private var copyButton: NSButton?
    private var saveButton: NSButton?

    func setText(_ text: String) {
        let data = Data(text.utf8)
        qrImage = nil
        if data.isEmpty { return showError("Nothing to encode.") }
        if data.count > Self.maxBytes { return showError("Text is too long for a QR code (\(data.count) bytes; maximum \(Self.maxBytes)).") }
        guard let img = Self.makeImage(data: data, border: Settings.shared.qrBorderPixels) else {
            return showError("Could not generate a QR code.")
        }
        qrImage = img
        imageView.image = img
        imageView.isHidden = false
        errorLabel.isHidden = true
        copyButton?.isEnabled = true; saveButton?.isEnabled = true
    }

    private func showError(_ s: String) {
        imageView.image = nil
        imageView.isHidden = true
        errorLabel.stringValue = s
        errorLabel.isHidden = false
        copyButton?.isEnabled = false; saveButton?.isEnabled = false
    }

    /// Renders crisp (nearest-neighbour) QR with a white quiet-zone border of `border` pixels.
    static func makeImage(data: Data, border: Int) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = data
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let modules = Int(out.extent.width)
        guard modules > 0 else { return nil }
        let scale = max(1, 512 / modules)
        let side = modules * scale
        let border = max(0, min(border, 500))
        let total = side + border * 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: total, pixelsHigh: total, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let ctx = CIContext(options: [.useSoftwareRenderer: true])
        guard let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        gc.cgContext.setFillColor(NSColor.white.cgColor)
        gc.cgContext.fill(CGRect(x: 0, y: 0, width: total, height: total))
        gc.cgContext.interpolationQuality = .none
        gc.cgContext.draw(cg, in: CGRect(x: border, y: border, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: total, height: total))
        img.addRepresentation(rep)
        return img
    }

    @objc private func copyImage() {
        guard let img = qrImage else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
        AppState.shared?.message("QR code copied")
    }

    @objc private func savePNG() {
        guard let img = qrImage, let w = window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "qrcode.png"
        panel.beginSheetModal(for: w) { resp in
            guard resp == .OK, let url = panel.url,
                  let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            do { try png.write(to: url, options: .atomic) } catch {
                let a = NSAlert(error: error); a.beginSheetModal(for: w)
            }
        }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
