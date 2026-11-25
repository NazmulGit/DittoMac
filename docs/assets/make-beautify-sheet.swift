// Renders every BeautifyPresets look on one synthetic screenshot and writes a contact sheet PNG.
// Usage (from the repo root, after `swift build --scratch-path $B`):
//   B=/private/tmp/claude-501/dm-build-beau
//   swiftc -O -I $B/debug -o /tmp/beautify-sheet docs/assets/make-beautify-sheet.swift \
//     Sources/DittoMac/UI/Screenshot/BeautifyRenderer.swift $B/debug/libDittoCore.a -lsqlite3
//   /tmp/beautify-sheet docs/assets/beautify-presets.png
import AppKit
import DittoCore

@main struct BeautifySheet {
  static func main() {
    let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "beautify-presets.png"
    guard let sample = BeautifySample.make(pointSize: CGSize(width: 440, height: 280), scale: 2) else { fatalError("no sample") }
    let presets = BeautifyPresets.all
    let cols = 4, rows = (presets.count + cols - 1) / cols
    let cellW = 400, cellH = 310, gap = 16, labelH = 28
    let sheetW = cols * cellW + (cols + 1) * gap, sheetH = rows * cellH + (rows + 1) * gap
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
    for (i, p) in presets.enumerated() {
        let col = i % cols, row = i / cols
        let x = gap + col * (cellW + gap), yTop = gap + row * (cellH + gap)
        let area = CGRect(x: x, y: sheetH - yTop - (cellH - labelH), width: cellW, height: cellH - labelH)
        // Checkerboard so transparency is visible.
        ctx.saveGState(); ctx.clip(to: area)
        let n = 10
        for cy in 0..<Int(area.height) / n + 1 { for cx in 0..<Int(area.width) / n + 1 {
            ctx.setFillColor((cx + cy) % 2 == 0 ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.9, alpha: 1))
            ctx.fill(CGRect(x: area.minX + CGFloat(cx * n), y: area.minY + CGFloat(cy * n), width: CGFloat(n), height: CGFloat(n)))
        } }
        let out = BeautifyRenderer.render(sample, pixelScale: 2, style: p)
        let scale = min(area.width / CGFloat(out.width), area.height / CGFloat(out.height))
        let dw = CGFloat(out.width) * scale, dh = CGFloat(out.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(out, in: CGRect(x: area.midX - dw / 2, y: area.midY - dh / 2, width: dw, height: dh))
        ctx.restoreGState()
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor(white: 0.15, alpha: 1)]
        NSAttributedString(string: p.name, attributes: attrs).draw(at: NSPoint(x: CGFloat(x) + 4, y: area.minY - 22))
        NSGraphicsContext.restoreGraphicsState()
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath) \(sheetW)x\(sheetH) with \(presets.count) presets")

  }
}
