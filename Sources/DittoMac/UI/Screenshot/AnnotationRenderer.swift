// AnnotationRenderer.swift — draws annotations into a CGContext (flipped point space) and computes pixelate/blur from base pixels.
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import DittoCore

/// Pixelate/blur results computed from the base pixels, cached per region.
final class AnnotationRegionEffects {
    let base: CGImage
    let pixelScale: CGFloat
    private var cache: [String: CGImage] = [:]
    // No colour management: pixels in = pixels out, so pixelate is exact and nothing shifts hue.
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    init(base: CGImage, pixelScale: CGFloat) { self.base = base; self.pixelScale = pixelScale }

    /// Pixel rect (top-left origin) a point rect covers in the base, nil if outside.
    func pixelRect(for r: CGRect) -> CGRect? {
        AnnotationMath.pixelRect(for: r, scale: pixelScale, imageWidth: base.width, imageHeight: base.height)
    }

    /// The processed pixels for `rect` (points). `strength` is in points (block size / blur radius).
    func image(for rect: CGRect, mode: AnnotationRegionMode, strength: CGFloat) -> (image: CGImage, pixelRect: CGRect)? {
        guard let px = pixelRect(for: rect) else { return nil }
        let amount = max(2, strength * pixelScale)
        let key = "\(mode)|\(px.minX),\(px.minY),\(px.width),\(px.height)|\(amount)"
        if let c = cache[key] { return (c, px) }
        guard let crop = base.cropping(to: px) else { return nil }
        let input = CIImage(cgImage: crop)
        let extent = input.extent
        let output: CIImage
        switch mode {
        case .pixelate:
            let f = CIFilter.pixellate()
            f.inputImage = input
            f.scale = Float(amount)
            f.center = CGPoint(x: extent.minX, y: extent.minY)   // align blocks to the region's origin
            output = (f.outputImage ?? input).cropped(to: extent)
        case .blur:
            let f = CIFilter.gaussianBlur()
            f.inputImage = input.clampedToExtent()               // avoid transparent/dark edges
            f.radius = Float(amount)
            output = (f.outputImage ?? input).cropped(to: extent)
        }
        let cs = base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let out = Self.ciContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: cs) else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = out
        return (out, px)
    }
}

enum AnnotationRenderer {
    /// Draws `items` into `ctx`, which must already be in point space with the origin at the top-left (y down).
    /// `preview` draws the view version (marker as plain translucent colour, since the base is underneath the view).
    static func draw(_ items: [Annotation], in ctx: CGContext, effects: AnnotationRegionEffects?, preview: Bool, skipping: Set<UUID> = []) {
        let numbers = AnnotationMath.stepNumbers(isStep: items.map { $0.isStep })
        ctx.saveGState()
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (i, a) in items.enumerated() where !skipping.contains(a.id) {
            ctx.saveGState()
            draw(a, number: numbers[i], in: ctx, effects: effects, preview: preview)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    static func draw(_ a: Annotation, number: Int?, in ctx: CGContext, effects: AnnotationRegionEffects?, preview: Bool) {
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.width)
        switch a.kind {
        case .pen(let pts):
            if pts.count == 1 {
                let r = a.width / 2
                ctx.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: a.width, height: a.width))
            } else {
                strokePolyline(AnnotationMath.smooth(AnnotationMath.decimate(pts, minDistance: 1.5), segments: 6), in: ctx)
            }
        case .marker(let pts):
            let mw = Annotation.markerWidth(for: a.width)
            let smoothed = AnnotationMath.smooth(AnnotationMath.decimate(pts, minDistance: 1.5), segments: 6)
            ctx.setLineWidth(mw)
            ctx.setLineCap(.butt)
            if preview {
                ctx.setAlpha(0.4)
            } else {
                ctx.setBlendMode(.multiply)
                ctx.setAlpha(0.8)
            }
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // overlapping passes of one stroke must not darken
            if smoothed.count == 1 {
                ctx.fill(CGRect(x: smoothed[0].x - mw / 2, y: smoothed[0].y - mw / 2, width: mw, height: mw))
            } else { strokePolyline(smoothed, in: ctx) }
            ctx.endTransparencyLayer()
        case .line(let p, let q):
            ctx.move(to: p); ctx.addLine(to: q); ctx.strokePath()
        case .arrow(let p, let q):
            let h = AnnotationMath.arrowHead(from: p, to: q, width: a.width)
            if h.length > 0 {
                ctx.move(to: p); ctx.addLine(to: h.shaftEnd); ctx.strokePath()
                ctx.move(to: h.tip); ctx.addLine(to: h.left); ctx.addLine(to: h.right); ctx.closePath()
                ctx.setLineWidth(max(1, a.width * 0.4))
                ctx.drawPath(using: .fillStroke)
            }
        case .rectangle(let r, let filled):
            if filled { ctx.fill(r) } else { ctx.setLineJoin(.miter); ctx.stroke(r) }
        case .ellipse(let r, let filled):
            if filled { ctx.fillEllipse(in: r) } else { ctx.strokeEllipse(in: r) }
        case .text(let o, let s, let chip):
            drawText(s, origin: o, fontSize: a.fontSize, color: a.color, chip: chip, in: ctx)
        case .step(let c):
            drawStep(number ?? 1, center: c, fontSize: a.fontSize, color: a.color, in: ctx)
        case .region(let r, let mode):
            drawRegion(r, mode: mode, strength: AnnotationMath.regionStrength(forLineWidth: a.width), in: ctx, effects: effects)
        }
    }

    private static func strokePolyline(_ pts: [CGPoint], in ctx: CGContext) {
        guard let f = pts.first else { return }
        ctx.move(to: f)
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }

    static func rgba(_ c: NSColor) -> AnnotationMath.RGBA {
        let s = c.usingColorSpace(.sRGB) ?? c.usingColorSpace(.deviceRGB) ?? .black
        return .init(r: Double(s.redComponent), g: Double(s.greenComponent), b: Double(s.blueComponent), a: Double(s.alphaComponent))
    }
    static func isLight(_ c: NSColor) -> Bool { AnnotationMath.luminance(rgba(c)) > 0.45 }

    static func drawText(_ s: String, origin o: CGPoint, fontSize: CGFloat, color: NSColor, chip: Bool, in ctx: CGContext) {
        let pad = Annotation.textPadding
        let size = Annotation.textContentSize(s, fontSize: fontSize)
        if chip {
            let box = CGRect(x: o.x, y: o.y, width: size.width + 2 * pad, height: size.height + 2 * pad)
            ctx.setFillColor((isLight(color) ? NSColor(white: 0, alpha: 0.7) : NSColor(white: 1, alpha: 0.88)).cgColor)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
        }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        (s as NSString).draw(with: CGRect(x: o.x + pad, y: o.y + pad, width: size.width + 1, height: size.height),
                             options: [.usesLineFragmentOrigin, .usesFontLeading],
                             attributes: [.font: Annotation.font(size: fontSize), .foregroundColor: color])
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawStep(_ n: Int, center c: CGPoint, fontSize: CGFloat, color: NSColor, in ctx: CGContext) {
        let d = Annotation.stepDiameter(for: fontSize)
        let r = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(NSColor(white: isLight(color) ? 0 : 1, alpha: 0.9).cgColor)
        ctx.setLineWidth(max(1, d / 16))
        ctx.strokeEllipse(in: r.insetBy(dx: d / 14, dy: d / 14))
        let str = "\(n)"
        let f = NSFont.systemFont(ofSize: d * (str.count > 2 ? 0.42 : str.count == 2 ? 0.5 : 0.6), weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: isLight(color) ? NSColor.black : NSColor.white]
        let sz = (str as NSString).size(withAttributes: attrs)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        (str as NSString).draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawRegion(_ r: CGRect, mode: AnnotationRegionMode, strength: CGFloat, in ctx: CGContext, effects: AnnotationRegionEffects?) {
        guard let fx = effects, let res = fx.image(for: r, mode: mode, strength: strength) else {
            ctx.setFillColor(NSColor(white: 0.5, alpha: 0.35).cgColor)   // no base yet: neutral placeholder
            ctx.fill(r)
            return
        }
        let s = fx.pixelScale
        let dest = CGRect(x: res.pixelRect.minX / s, y: res.pixelRect.minY / s, width: res.pixelRect.width / s, height: res.pixelRect.height / s)
        ctx.interpolationQuality = .none
        ctx.translateBy(x: dest.minX, y: dest.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(res.image, in: CGRect(x: 0, y: 0, width: dest.width, height: dest.height))
    }

    /// Base + annotations rasterised at the base's pixel size. `sx/sy` convert canvas points to pixels.
    static func flatten(base: CGImage, items: [Annotation], sx: CGFloat, sy: CGFloat, effects: AnnotationRegionEffects?) -> CGImage? {
        let w = base.width, h = base.height
        var cs = base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if cs.model != .rgb { cs = CGColorSpace(name: CGColorSpace.sRGB)! }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: sx, y: -sy)
        ctx.interpolationQuality = .high
        draw(items, in: ctx, effects: effects, preview: false)
        return ctx.makeImage()
    }
}
