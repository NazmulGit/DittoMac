// BeautifyRenderer.swift — "Beautify" a screenshot: padding, gradient/solid/transparent background, rounded corners,
// soft shadow, outline and optional window chrome. Pure CoreGraphics, offscreen and deterministic (no AppKit state,
// no randomness, no time). Layout and colour maths live in DittoCore/BeautifyLayout.swift (unit-tested).
// See docs/kb/beautify.md.
import AppKit
import DittoCore

struct BeautifyStyle: Codable, Equatable {
    enum Background: Codable, Equatable {
        case gradient(start: String, end: String, angle: Double)   // hex "#RRGGBB"; angle in CSS degrees (0 = up, 90 = right, 135 = down-right)
        case solid(String)
        case transparent
    }
    enum WindowFrame: String, Codable, CaseIterable { case none, macWindow, macWindowDark, browser }
    enum Aspect: String, Codable, CaseIterable { case auto, wide16x9, standard4x3, square, photo3x2 }

    var name = "Custom"
    var enabled = false
    var background: Background = .gradient(start: "#7F7FD5", end: "#86A8E7", angle: 135)
    var padding: Double = 48            // points around the image
    var cornerRadius: Double = 12
    var shadowRadius: Double = 30
    var shadowOpacity: Double = 0.35
    var shadowOffsetY: Double = 12
    var outlineWidth: Double = 0
    var outlineColor = "#FFFFFF"
    var windowFrame: WindowFrame = .none
    var aspect: Aspect = .auto
}

extension BeautifyStyle.WindowFrame {
    var title: String {
        switch self {
        case .none: return "None"
        case .macWindow: return "macOS window"
        case .macWindowDark: return "macOS window (dark)"
        case .browser: return "Browser"
        }
    }
    /// Height in points of the chrome drawn above the screenshot.
    var chromeHeight: Double {
        switch self {
        case .none: return 0
        case .macWindow, .macWindowDark: return 28
        case .browser: return 64
        }
    }
}

extension BeautifyStyle.Aspect {
    var title: String {
        switch self {
        case .auto: return "Fit"
        case .wide16x9: return "16:9"
        case .standard4x3: return "4:3"
        case .square: return "1:1"
        case .photo3x2: return "3:2"
        }
    }
    /// width / height of the canvas; nil = fit the content.
    var ratio: Double? {
        switch self {
        case .auto: return nil
        case .wide16x9: return 16.0 / 9
        case .standard4x3: return 4.0 / 3
        case .square: return 1
        case .photo3x2: return 3.0 / 2
        }
    }
}

enum BeautifyPresets {
    /// Professional ready-made looks (distinct names, all `enabled`). The table itself is DittoCore.BeautifyPresetCatalog.
    static let all: [BeautifyStyle] = BeautifyPresetCatalog.specs.map { spec in
        var s = BeautifyStyle()
        s.name = spec.name; s.enabled = true
        switch spec.fill {
        case .gradient(let a, let b, let angle): s.background = .gradient(start: a, end: b, angle: angle)
        case .solid(let h): s.background = .solid(h)
        case .transparent: s.background = .transparent
        }
        s.padding = spec.padding; s.cornerRadius = spec.cornerRadius
        s.shadowRadius = spec.shadowRadius; s.shadowOpacity = spec.shadowOpacity; s.shadowOffsetY = spec.shadowOffsetY
        s.outlineWidth = spec.outlineWidth; s.outlineColor = spec.outlineColor
        s.windowFrame = BeautifyStyle.WindowFrame(rawValue: spec.frame) ?? .none
        return s
    }

    /// Used by "Reset" and when nothing has been saved.
    static var defaultStyle: BeautifyStyle { all[0] }
}

enum BeautifyRenderer {
    static func layout(for image: CGImage, pixelScale: CGFloat, style: BeautifyStyle) -> BeautifyLayout.Result {
        BeautifyLayout.compute(imageWidth: image.width, imageHeight: image.height, pixelScale: Double(pixelScale),
                               padding: style.padding, aspectRatio: style.aspect.ratio, chromeHeight: style.windowFrame.chromeHeight)
    }

    /// `pixelScale` = pixels per point of the source (2 on Retina) so padding/radius are in points.
    /// Output size = canvas points × pixelScale, capped at 16,384 px on the longest side. Returns the input unchanged for
    /// empty images, invalid scales or if no bitmap context can be created.
    static func render(_ image: CGImage, pixelScale: CGFloat, style: BeautifyStyle) -> CGImage {
        guard image.width > 0, image.height > 0, pixelScale.isFinite, pixelScale > 0 else { return image }
        let L = layout(for: image, pixelScale: pixelScale, style: style)
        let W = L.pixelWidth, H = L.pixelHeight
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let s = CGFloat(L.renderScale)
        ctx.interpolationQuality = .high
        ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
        ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))

        drawBackground(style.background, in: ctx, size: CGSize(width: W, height: H), space: space)

        // Device-space content rectangle (y-up), snapped to whole pixels so the screenshot stays crisp.
        let top = (CGFloat(L.contentY) * s).rounded()
        let cw = (CGFloat(L.contentWidth) * s).rounded()
        let ch = (CGFloat(L.contentHeight) * s).rounded()
        let cx = (CGFloat(L.contentX) * s).rounded()
        let content = CGRect(x: cx, y: CGFloat(H) - top - ch, width: cw, height: ch)
        let chrome = (CGFloat(L.chromeHeight) * s).rounded()
        let imageRect = CGRect(x: content.minX, y: content.minY, width: content.width, height: content.height - chrome)
        let radius = max(0, min(CGFloat(style.cornerRadius) * s, min(content.width, content.height) / 2))
        let shape = CGPath(roundedRect: content, cornerWidth: radius, cornerHeight: radius, transform: nil)

        drawShadows(style, shape: shape, in: ctx, scale: s)

        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))   // under any transparent screenshot pixels
        ctx.fill(content)
        ctx.draw(image, in: imageRect)
        if chrome > 0 {
            let bar = CGRect(x: content.minX, y: content.maxY - chrome, width: content.width, height: chrome)
            drawChrome(style.windowFrame, in: ctx, rect: bar, scale: s)
        }
        ctx.restoreGState()

        if style.outlineWidth > 0, style.outlineWidth.isFinite {
            let w = min(CGFloat(style.outlineWidth) * s, min(content.width, content.height) / 2)
            let inset = content.insetBy(dx: w / 2, dy: w / 2)
            let r = max(0, radius - w / 2)
            ctx.addPath(CGPath(roundedRect: inset, cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.setStrokeColor(cgColor(style.outlineColor, fallback: HexColor(r: 1, g: 1, b: 1)))
            ctx.setLineWidth(w)
            ctx.strokePath()
        }
        return ctx.makeImage() ?? image
    }

    // MARK: colour

    static func cgColor(_ hex: String, fallback: HexColor = HexColor(r: 0.5, g: 0.5, b: 0.5)) -> CGColor {
        let c = HexColor(hex) ?? fallback
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    // MARK: background

    private static func drawBackground(_ bg: BeautifyStyle.Background, in ctx: CGContext, size: CGSize, space: CGColorSpace) {
        let rect = CGRect(origin: .zero, size: size)
        switch bg {
        case .transparent:
            return
        case .solid(let hex):
            ctx.setFillColor(cgColor(hex, fallback: HexColor(r: 0.93, g: 0.93, b: 0.95)))
            ctx.fill(rect)
        case .gradient(let a, let b, let angle):
            let colors = [cgColor(a), cgColor(b)] as CFArray
            guard let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
            let rad = (angle.isFinite ? angle : 135) * .pi / 180
            let dx = CGFloat(sin(rad)), dy = CGFloat(cos(rad))      // CSS angle, in y-up device space
            let len = abs(size.width * dx) + abs(size.height * dy)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            // CSS "to bottom right" starts top-left: start = c - dir * len/2 (dir y flipped for y-up).
            let start = CGPoint(x: c.x - dx * len / 2, y: c.y - dy * len / 2)
            let end = CGPoint(x: c.x + dx * len / 2, y: c.y + dy * len / 2)
            ctx.drawLinearGradient(g, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }

    // MARK: shadow

    private static func drawShadows(_ style: BeautifyStyle, shape: CGPath, in ctx: CGContext, scale s: CGFloat) {
        let opacity = CGFloat(min(max(style.shadowOpacity.isFinite ? style.shadowOpacity : 0, 0), 1))
        let blur = CGFloat(max(style.shadowRadius.isFinite ? style.shadowRadius : 0, 0))
        guard opacity > 0, blur > 0 else { return }
        let off = CGFloat(style.shadowOffsetY.isFinite ? style.shadowOffsetY : 0)
        // A wide ambient shadow plus a tight contact shadow reads as more natural than one big blur.
        let passes: [(blur: CGFloat, dy: CGFloat, alpha: CGFloat)] = [(blur, off, opacity * 0.75), (max(blur * 0.22, 2), off * 0.3, opacity * 0.5)]
        for p in passes {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -p.dy * s), blur: p.blur * s,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: p.alpha))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.addPath(shape); ctx.fillPath()
            ctx.restoreGState()
        }
    }

    // MARK: window chrome

    private static func drawChrome(_ frame: BeautifyStyle.WindowFrame, in ctx: CGContext, rect: CGRect, scale s: CGFloat) {
        func rgb(_ hex: String) -> CGColor { cgColor(hex) }
        func fill(_ r: CGRect, _ hex: String) { ctx.setFillColor(rgb(hex)); ctx.fill(r) }
        func circle(cx: CGFloat, cy: CGFloat, r: CGFloat, fill f: CGColor, stroke: CGColor? = nil) {
            let rr = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor(f); ctx.fillEllipse(in: rr)
            if let stroke { ctx.setStrokeColor(stroke); ctx.setLineWidth(max(0.5, s * 0.5)); ctx.strokeEllipse(in: rr.insetBy(dx: s * 0.25, dy: s * 0.25)) }
        }
        func pill(_ r: CGRect, _ hex: String) {
            ctx.setFillColor(rgb(hex))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); ctx.fillPath()
        }
        func gradient(_ r: CGRect, top: String, bottom: String) {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let g = CGGradient(colorsSpace: space, colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1]) else { return }
            ctx.saveGState(); ctx.clip(to: r)
            ctx.drawLinearGradient(g, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
            ctx.restoreGState()
        }
        func trafficLights(y: CGFloat, left: CGFloat) {
            let cols: [(String, String)] = [("#FF5F57", "#E0443E"), ("#FEBC2E", "#DEA123"), ("#28C840", "#1AAB29")]
            for (i, c) in cols.enumerated() {
                circle(cx: left + (14 + CGFloat(i) * 20) * s, cy: y, r: 6 * s, fill: rgb(c.0), stroke: rgb(c.1))
            }
        }

        switch frame {
        case .none:
            return
        case .macWindow, .macWindowDark:
            let dark = frame == .macWindowDark
            gradient(rect, top: dark ? "#3C3C3F" : "#F2F2F2", bottom: dark ? "#2E2E31" : "#E6E6E6")
            fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, s * 0.5)), dark ? "#161617" : "#C9C9C9")   // separator
            trafficLights(y: rect.midY, left: rect.minX)
        case .browser:
            let strip = rect.height * (30.0 / 64.0)
            let toolbar = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - strip)
            let tabStrip = CGRect(x: rect.minX, y: toolbar.maxY, width: rect.width, height: strip)
            fill(tabStrip, "#DEE1E6")
            fill(toolbar, "#FFFFFF")
            fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, s * 0.5)), "#DADCE0")      // separator
            trafficLights(y: tabStrip.midY, left: rect.minX)
            // Selected tab: rounded top corners, same colour as the toolbar.
            let tab = CGRect(x: rect.minX + 84 * s, y: tabStrip.minY, width: min(150 * s, max(0, rect.width - 100 * s)), height: strip - 4 * s)
            if tab.width > 24 * s {
                let r = 8 * s
                let p = CGMutablePath()
                p.move(to: CGPoint(x: tab.minX, y: tab.minY))
                p.addLine(to: CGPoint(x: tab.minX, y: tab.maxY - r))
                p.addArc(tangent1End: CGPoint(x: tab.minX, y: tab.maxY), tangent2End: CGPoint(x: tab.minX + r, y: tab.maxY), radius: r)
                p.addLine(to: CGPoint(x: tab.maxX - r, y: tab.maxY))
                p.addArc(tangent1End: CGPoint(x: tab.maxX, y: tab.maxY), tangent2End: CGPoint(x: tab.maxX, y: tab.maxY - r), radius: r)
                p.addLine(to: CGPoint(x: tab.maxX, y: tab.minY))
                p.closeSubpath()
                ctx.setFillColor(rgb("#FFFFFF")); ctx.addPath(p); ctx.fillPath()
                circle(cx: tab.minX + 16 * s, cy: tab.midY, r: 4.5 * s, fill: rgb("#9AA0A6"))
                pill(CGRect(x: tab.minX + 30 * s, y: tab.midY - 3 * s, width: min(64 * s, max(0, tab.width - 50 * s)), height: 6 * s), "#C4C7CC")
            }
            // Toolbar: nav dots + URL pill with lock dot and a placeholder bar (no text).
            let cy = toolbar.midY
            for i in 0..<3 { circle(cx: rect.minX + (22 + CGFloat(i) * 24) * s, cy: cy, r: 5 * s, fill: rgb("#BDC1C6")) }
            let pillRect = CGRect(x: rect.minX + 100 * s, y: cy - 12 * s, width: max(0, rect.width - 124 * s), height: 24 * s)
            if pillRect.width > 40 * s {
                pill(pillRect, "#F1F3F4")
                circle(cx: pillRect.minX + 14 * s, cy: cy, r: 4 * s, fill: rgb("#9AA0A6"))
                pill(CGRect(x: pillRect.minX + 28 * s, y: cy - 3 * s, width: min(140 * s, max(0, pillRect.width - 50 * s)), height: 6 * s), "#D0D3D8")
            }
        }
    }
}

// MARK: - Synthetic sample (previews, thumbnails, the docs contact sheet)

enum BeautifySample {
    /// A screenshot-like image: sidebar, toolbar, heading, text lines, a button and a few chart bars.
    /// The artwork is laid out on a fixed 440 × 280 pt canvas; `pointSize.width` and `scale` only choose the resolution
    /// (the height follows the 440:280 aspect).
    static func make(pointSize: CGSize = CGSize(width: 440, height: 280), scale: CGFloat = 2) -> CGImage? {
        let lw: CGFloat = 440, lh: CGFloat = 280
        let k = max(0.1, pointSize.width / lw) * scale
        let W = max(1, Int(lw * k)), H = max(1, Int(lh * k))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: k, y: k)
        let w = lw, h = lh
        func rect(_ x: CGFloat, _ yTop: CGFloat, _ rw: CGFloat, _ rh: CGFloat) -> CGRect { CGRect(x: x, y: h - yTop - rh, width: rw, height: rh) }
        func bar(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat, _ hex: String, r: CGFloat? = nil) {
            ctx.setFillColor(BeautifyRenderer.cgColor(hex))
            let rr = rect(x, y, rw, rh), rad = r ?? rh / 2
            ctx.addPath(CGPath(roundedRect: rr, cornerWidth: min(rad, rr.height / 2), cornerHeight: min(rad, rr.height / 2), transform: nil)); ctx.fillPath()
        }
        ctx.setFillColor(BeautifyRenderer.cgColor("#FFFFFF")); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(BeautifyRenderer.cgColor("#F4F5F7")); ctx.fill(rect(0, 0, 104, h))
        ctx.setFillColor(BeautifyRenderer.cgColor("#EDEEF1")); ctx.fill(rect(104, 0, 1, h))
        for (i, hex) in ["#3B82F6", "#9CA3AF", "#9CA3AF", "#9CA3AF", "#9CA3AF"].enumerated() {
            bar(14, 22 + CGFloat(i) * 24, CGFloat(52 + (i * 13) % 30), 8, hex)
        }
        ctx.setFillColor(BeautifyRenderer.cgColor("#FAFAFB")); ctx.fill(rect(105, 0, w - 105, 36))
        ctx.setFillColor(BeautifyRenderer.cgColor("#EDEEF1")); ctx.fill(rect(105, 36, w - 105, 1))
        for i in 0..<3 { bar(122 + CGFloat(i) * 52, 13, 40, 10, "#E5E7EB") }
        bar(124, 60, 170, 14, "#1F2937")
        let lines: [CGFloat] = [250, 270, 210, 260, 150]
        for (i, lw) in lines.enumerated() { bar(124, 92 + CGFloat(i) * 16, min(lw, w - 150), 7, "#9CA3AF") }
        bar(124, 190, 70, 26, "#3B82F6", r: 6)
        bar(202, 190, 70, 26, "#E5E7EB", r: 6)
        let bars: [(CGFloat, String)] = [(34, "#93C5FD"), (52, "#60A5FA"), (26, "#93C5FD"), (60, "#3B82F6"), (44, "#60A5FA")]
        for (i, b) in bars.enumerated() { bar(w - 130 + CGFloat(i) * 22, 236 - b.0, 14, b.0, b.1, r: 3) }
        ctx.setStrokeColor(BeautifyRenderer.cgColor("#E5E7EB")); ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1))
        return ctx.makeImage()
    }
}
