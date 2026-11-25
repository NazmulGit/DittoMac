// BeautifyLayout.swift — pure layout and colour maths for the Beautify renderer (the CoreGraphics drawing lives in
// Sources/DittoMac/UI/Screenshot/BeautifyRenderer.swift). Kept here so it is unit-tested.
import Foundation

public struct HexColor: Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    /// `#RGB`, `#RRGGBB` or `#RRGGBBAA` (leading `#` optional). Nil for anything else.
    public init?(_ s: String) {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { t.removeFirst() }
        guard [3, 6, 8].contains(t.count), t.unicodeScalars.allSatisfy({ $0.isASCII && Character($0).isHexDigit }) else { return nil }
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        guard let v = UInt64(t, radix: 16) else { return nil }
        if t.count == 6 {
            self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
        } else {
            self.init(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                      b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
        }
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    public var hex: String {
        func c(_ x: Double) -> Int { x.isFinite ? Int((min(max(x, 0), 1) * 255).rounded()) : 0 }
        let base = String(format: "#%02X%02X%02X", c(r), c(g), c(b))
        return a < 0.999 ? base + String(format: "%02X", c(a)) : base
    }
}

public enum BeautifyLayout {
    public static let maxSide = 16_384
    /// Extra guard on memory: 128 megapixels ≈ 512 MB of RGBA.
    public static let maxPixels = 128_000_000

    public struct Result: Equatable, Sendable {
        /// Canvas size in points.
        public var canvasWidth: Double, canvasHeight: Double
        /// The framed content (window chrome + screenshot) in points, origin top-left of the canvas.
        public var contentX: Double, contentY: Double, contentWidth: Double, contentHeight: Double
        /// Space taken by window chrome above the screenshot inside the content rect.
        public var chromeHeight: Double
        /// Output bitmap size in pixels (already capped).
        public var pixelWidth: Int, pixelHeight: Int
        /// Pixels per point actually used (≤ requested pixelScale when capped).
        public var renderScale: Double
        public var wasCapped: Bool
    }

    /// - Parameters: `imageWidth/Height` in pixels, `pixelScale` pixels per point, `padding` and `chromeHeight` in points,
    ///   `aspectRatio` width/height of the canvas (nil = fit content), `minCanvas` optional lower bound.
    public static func compute(imageWidth: Int, imageHeight: Int, pixelScale: Double, padding: Double,
                               aspectRatio: Double?, chromeHeight: Double = 0) -> Result {
        let scale = pixelScale.isFinite && pixelScale > 0 ? min(pixelScale, 16) : 1
        let iw = Double(max(imageWidth, 1)) / scale
        let ih = Double(max(imageHeight, 1)) / scale
        let pad = padding.isFinite ? min(max(padding, 0), 2000) : 0
        let chrome = chromeHeight.isFinite ? max(chromeHeight, 0) : 0
        let cw = iw, ch = ih + chrome
        var w = cw + 2 * pad, h = ch + 2 * pad
        if let r = aspectRatio, r.isFinite, r > 0 {
            if w / h < r { w = h * r } else { h = w / r }
        }
        // Cap: longest side, then total pixels.
        var factor = 1.0
        let longest = max(w, h) * scale
        if longest > Double(maxSide) { factor = Double(maxSide) / longest }
        let area = w * h * scale * scale * factor * factor
        if area > Double(maxPixels) { factor *= (Double(maxPixels) / area).squareRoot() }
        let pw = max(1, min(maxSide, Int((w * scale * factor).rounded())))
        let ph = max(1, min(maxSide, Int((h * scale * factor).rounded())))
        return Result(canvasWidth: w, canvasHeight: h, contentX: (w - cw) / 2, contentY: (h - ch) / 2,
                      contentWidth: cw, contentHeight: ch, chromeHeight: chrome,
                      pixelWidth: pw, pixelHeight: ph, renderScale: scale * factor, wasCapped: factor < 1)
    }
}

// MARK: - Preset catalogue (data only; the app maps these to BeautifyStyle so the table can be unit-tested)

public struct BeautifyPresetSpec: Equatable, Sendable {
    public enum Fill: Equatable, Sendable { case gradient(start: String, end: String, angle: Double), solid(String), transparent }
    public var name: String
    public var fill: Fill
    public var padding = 56.0, cornerRadius = 12.0
    public var shadowRadius = 34.0, shadowOpacity = 0.38, shadowOffsetY = 14.0
    public var outlineWidth = 0.0, outlineColor = "#FFFFFF"
    /// "none", "macWindow", "macWindowDark" or "browser".
    public var frame = "none"
    public init(name: String, fill: Fill) { self.name = name; self.fill = fill }
}

public enum BeautifyPresetCatalog {
    public static let frames: Set<String> = ["none", "macWindow", "macWindowDark", "browser"]

    public static let specs: [BeautifyPresetSpec] = {
        func g(_ name: String, _ a: String, _ b: String, angle: Double = 135, opacity: Double = 0.38) -> BeautifyPresetSpec {
            var s = BeautifyPresetSpec(name: name, fill: .gradient(start: a, end: b, angle: angle)); s.shadowOpacity = opacity; return s
        }
        var paper = BeautifyPresetSpec(name: "Paper", fill: .solid("#F5F1E8"))
        paper.padding = 48; paper.cornerRadius = 10; paper.shadowRadius = 24; paper.shadowOpacity = 0.22; paper.shadowOffsetY = 8
        var mono = BeautifyPresetSpec(name: "Mono", fill: .solid("#2B2B2D"))
        mono.padding = 48; mono.cornerRadius = 10; mono.shadowRadius = 30; mono.shadowOpacity = 0.6; mono.shadowOffsetY = 10
        mono.outlineWidth = 1; mono.outlineColor = "#FFFFFF33"
        var white = BeautifyPresetSpec(name: "Clean White shadow", fill: .solid("#FFFFFF"))
        white.padding = 40; white.cornerRadius = 10; white.shadowRadius = 36; white.shadowOpacity = 0.22
        var clear = BeautifyPresetSpec(name: "Transparent shadow", fill: .transparent)
        clear.padding = 40; clear.cornerRadius = 10; clear.shadowRadius = 32; clear.shadowOpacity = 0.4; clear.shadowOffsetY = 12
        var macSunset = g("macOS window — Sunset", "#FFB88C", "#DE6262", angle: 140, opacity: 0.4)
        macSunset.cornerRadius = 10; macSunset.shadowRadius = 40; macSunset.shadowOffsetY = 18; macSunset.frame = "macWindow"
        var macDark = g("macOS window — Dark", "#434343", "#000000", angle: 160, opacity: 0.55)
        macDark.cornerRadius = 10; macDark.shadowRadius = 40; macDark.shadowOffsetY = 18; macDark.frame = "macWindowDark"
        var browser = g("Browser — Ocean", "#2193B0", "#6DD5ED", angle: 150, opacity: 0.35)
        browser.cornerRadius = 10; browser.shadowRadius = 36; browser.shadowOffsetY = 16; browser.frame = "browser"
        return [
            g("Aurora", "#5EFCE8", "#736EFE"),
            g("Sunset", "#FF9A9E", "#F6416C", angle: 140),
            g("Ocean", "#2193B0", "#6DD5ED", angle: 150),
            g("Midnight", "#232526", "#414345", angle: 160, opacity: 0.55),
            g("Peach", "#FFECD2", "#FCB69F", opacity: 0.28),
            g("Mint", "#C1F5D8", "#6FD3B2", opacity: 0.30),
            g("Candy", "#FBC2EB", "#A6C1EE", opacity: 0.30),
            g("Slate", "#667589", "#2F3A48", angle: 160, opacity: 0.5),
            g("Neon", "#7F00FF", "#E100FF", angle: 120, opacity: 0.5),
            g("Forest", "#134E5E", "#71B280", angle: 150, opacity: 0.45),
            g("Lavender", "#E0C3FC", "#8EC5FC", opacity: 0.30),
            paper, mono, white, clear, macSunset, macDark, browser,
        ]
    }()
}
