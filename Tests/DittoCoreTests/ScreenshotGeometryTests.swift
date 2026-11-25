import Testing
import Foundation
import CoreGraphics
@testable import DittoCore

@Suite struct ScreenshotGeometryTests {
    typealias G = ScreenshotGeometry
    let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: selection

    @Test func normalizeAnyDragDirection() {
        let r = G.normalizedRect(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 100, y: 50))
        #expect(r == CGRect(x: 100, y: 50, width: 200, height: 150))
        #expect(G.normalizedRect(from: .zero, to: .zero).isEmpty)
    }

    @Test func clampToBounds() {
        #expect(G.clamp(CGRect(x: -50, y: -10, width: 200, height: 100), to: bounds) == CGRect(x: 0, y: 0, width: 150, height: 90))
        #expect(G.clamp(CGRect(x: 1400, y: 880, width: 100, height: 100), to: bounds) == CGRect(x: 1400, y: 880, width: 40, height: 20))
        let disjoint = G.clamp(CGRect(x: 2000, y: 100, width: 10, height: 10), to: bounds)
        #expect(disjoint.width == 0 && disjoint.minX == 1440)
    }

    @Test func keepInsideKeepsSize() {
        let r = G.keepInside(CGRect(x: 1400, y: -20, width: 100, height: 60), bounds: bounds)
        #expect(r == CGRect(x: 1340, y: 0, width: 100, height: 60))
        let big = G.keepInside(CGRect(x: -10, y: -10, width: 5000, height: 5000), bounds: bounds)
        #expect(big == bounds)
    }

    @Test func nudgeStaysOnScreen() {
        let r = CGRect(x: 10, y: 10, width: 100, height: 100)
        #expect(G.nudge(r, dx: 1, dy: 0, bounds: bounds).minX == 11)
        #expect(G.nudge(r, dx: -10, dy: -10, bounds: bounds).origin == CGPoint(x: 0, y: 0))
        #expect(G.nudge(r, dx: -30, dy: 0, bounds: bounds).minX == 0)
        #expect(G.nudge(CGRect(x: 1330, y: 0, width: 100, height: 10), dx: 50, dy: 0, bounds: bounds).maxX == 1440)
    }

    @Test func wholeDisplay() {
        #expect(G.wholeDisplay(CGRect(x: 0, y: 0, width: 1512, height: 982)) == CGRect(x: 0, y: 0, width: 1512, height: 982))
    }

    // MARK: handles

    @Test func handleHitTesting() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(G.hitHandle(at: CGPoint(x: 101, y: 99), in: r, tolerance: 6) == .topLeft)
        #expect(G.hitHandle(at: CGPoint(x: 300, y: 200), in: r, tolerance: 6) == .bottomRight)
        #expect(G.hitHandle(at: CGPoint(x: 200, y: 103), in: r, tolerance: 6) == .top)
        #expect(G.hitHandle(at: CGPoint(x: 296, y: 150), in: r, tolerance: 6) == .right)
        #expect(G.hitHandle(at: CGPoint(x: 100, y: 150), in: r, tolerance: 6) == .left)
        #expect(G.hitHandle(at: CGPoint(x: 200, y: 200), in: r, tolerance: 6) == .bottom)
        #expect(G.hitHandle(at: CGPoint(x: 200, y: 150), in: r, tolerance: 6) == nil)
        // Tiny selection: corners only.
        let tiny = CGRect(x: 10, y: 10, width: 8, height: 8)
        #expect(G.hitHandle(at: CGPoint(x: 14, y: 10), in: tiny, tolerance: 6) == .topLeft || G.hitHandle(at: CGPoint(x: 14, y: 10), in: tiny, tolerance: 6) == .topRight)
    }

    @Test func handleRects() {
        let r = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(G.handleRect(.bottomRight, of: r, size: 8) == CGRect(x: 96, y: 46, width: 8, height: 8))
        #expect(ResizeHandle.allCases.count == 8)
    }

    @Test func borderBand() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(G.isOnBorder(CGPoint(x: 102, y: 150), of: r, band: 4))
        #expect(!G.isOnBorder(CGPoint(x: 150, y: 150), of: r, band: 4))
        #expect(!G.isOnBorder(CGPoint(x: 50, y: 150), of: r, band: 4))
    }

    @Test func resizeEdgesAndCorners() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(G.resize(r, handle: .right, to: CGPoint(x: 400, y: 0), bounds: bounds) == CGRect(x: 100, y: 100, width: 300, height: 100))
        #expect(G.resize(r, handle: .top, to: CGPoint(x: 0, y: 50), bounds: bounds) == CGRect(x: 100, y: 50, width: 200, height: 150))
        #expect(G.resize(r, handle: .topLeft, to: CGPoint(x: 50, y: 60), bounds: bounds) == CGRect(x: 50, y: 60, width: 250, height: 140))
        // Clamped to bounds.
        #expect(G.resize(r, handle: .bottomRight, to: CGPoint(x: 5000, y: 5000), bounds: bounds) == CGRect(x: 100, y: 100, width: 1340, height: 800))
    }

    @Test func resizeRespectsMinimumSize() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)
        let out = G.resize(r, handle: .left, to: CGPoint(x: 500, y: 0), minSize: CGSize(width: 10, height: 10), bounds: bounds)
        #expect(out == CGRect(x: 290, y: 100, width: 10, height: 100))
        let up = G.resize(r, handle: .bottom, to: CGPoint(x: 0, y: 0), minSize: CGSize(width: 10, height: 10), bounds: bounds)
        #expect(up.height == 10 && up.minY == 100)
    }

    @Test func resizeAspectLock() {
        let r = CGRect(x: 100, y: 100, width: 200, height: 100)        // 2:1
        let out = G.resize(r, handle: .bottomRight, to: CGPoint(x: 500, y: 150), bounds: bounds, aspect: 2)
        #expect(abs(out.width / out.height - 2) < 0.001)
        #expect(out.minX == 100 && out.minY == 100)                      // anchored at the opposite corner
        let tl = G.resize(r, handle: .topLeft, to: CGPoint(x: 0, y: 90), bounds: bounds, aspect: 2)
        #expect(abs(tl.width / tl.height - 2) < 0.001 && tl.maxX == 300 && tl.maxY == 200)
        // Fits inside the bounds even when the pointer leaves them.
        let edge = G.resize(r, handle: .bottomRight, to: CGPoint(x: 5000, y: 5000), bounds: bounds, aspect: 2)
        #expect(edge.maxX <= 1440 && edge.maxY <= 900 && abs(edge.width / edge.height - 2) < 0.001)
        let side = G.resize(r, handle: .right, to: CGPoint(x: 400, y: 0), bounds: bounds, aspect: 2)
        #expect(side.width == 300 && side.height == 150)
    }

    // MARK: coordinate spaces

    @Test func globalViewRoundTrip() {
        let f = CGRect(x: -1920, y: 200, width: 1920, height: 1080)      // display left of and above primary
        let g = CGPoint(x: -1000, y: 900)
        let v = G.globalToView(g, displayFrame: f)
        #expect(v == CGPoint(x: 920, y: 380))
        #expect(G.viewToGlobal(v, displayFrame: f) == g)
        #expect(G.globalRectToView(CGRect(x: -1920, y: 1180, width: 100, height: 100), displayFrame: f) == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func quartzAppKitFlip() {
        let q = CGRect(x: 10, y: 20, width: 300, height: 200)
        let a = G.flipQuartzAppKit(q, primaryHeight: 900)
        #expect(a == CGRect(x: 10, y: 680, width: 300, height: 200))
        #expect(G.flipQuartzAppKit(a, primaryHeight: 900) == q)
    }

    @Test func mixedScaleDisplaysToPixels() {
        // Retina primary (2x) and a 1x external to the right.
        let retina = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let frames = [retina, external]
        let p = CGPoint(x: 1600, y: 1000)
        #expect(G.displayIndex(containing: p, frames: frames) == 1)
        #expect(G.globalToPixel(p, displayFrame: external, scale: 1) == CGPoint(x: 88, y: 80))
        let q = CGPoint(x: 100, y: 900)
        #expect(G.globalToPixel(q, displayFrame: retina, scale: 2) == CGPoint(x: 200, y: 164))
        #expect(G.pixelToGlobal(CGPoint(x: 200, y: 164), displayFrame: retina, scale: 2) == q)
        // Gap → nearest display.
        #expect(G.displayIndex(containing: CGPoint(x: 1600, y: 1070), frames: frames) == 1)
        #expect(G.displayIndex(containing: .zero, frames: []) == nil)
    }

    @Test func viewRectToPixelsIsIntegralAndClipped() {
        let px = G.viewRectToPixels(CGRect(x: 10.25, y: 5.5, width: 100.5, height: 50), scale: 2, imageSize: CGSize(width: 3024, height: 1964))
        #expect(px == CGRect(x: 20, y: 11, width: 202, height: 100))
        let clipped = G.viewRectToPixels(CGRect(x: 1500, y: 970, width: 50, height: 50), scale: 2, imageSize: CGSize(width: 3024, height: 1964))
        #expect(clipped.maxX == 3024 && clipped.maxY == 1964)
        let oneX = G.viewRectToPixels(CGRect(x: 0, y: 0, width: 10, height: 10), scale: 1, imageSize: CGSize(width: 100, height: 100))
        #expect(oneX == CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    // MARK: panel placement

    @Test func panelPrefersBelowThenFlips() {
        let size = CGSize(width: 300, height: 40)
        let a = CGRect(x: 400, y: 100, width: 400, height: 300)
        let below = G.placePanel(size: size, anchor: a, bounds: bounds, sides: [.below, .above, .insideBottom])
        #expect(below.side == .below && below.frame == CGRect(x: 500, y: 408, width: 300, height: 40))
        let low = CGRect(x: 400, y: 500, width: 400, height: 380)
        let above = G.placePanel(size: size, anchor: low, bounds: bounds, sides: [.below, .above, .insideBottom])
        #expect(above.side == .above && above.frame.maxY == 492)
        let full = G.placePanel(size: size, anchor: bounds, bounds: bounds, sides: [.below, .above, .insideBottom])
        #expect(full.side == .insideBottom && bounds.contains(full.frame))
    }

    @Test func panelSlidesAlongEdge() {
        let size = CGSize(width: 300, height: 40)
        let a = CGRect(x: 0, y: 100, width: 100, height: 100)            // trailing alignment would go off the left edge
        let r = G.placePanel(size: size, anchor: a, bounds: bounds, sides: [.below])
        #expect(r.frame.minX == 0 && r.frame.minY == 208)
        let side = G.placePanel(size: CGSize(width: 40, height: 300), anchor: CGRect(x: 1300, y: 0, width: 140, height: 100),
                                bounds: bounds, sides: [.right, .left, .insideRight], alignment: .trailing)
        #expect(side.side == .left && side.frame.minY == 0 && side.frame.maxX == 1292)
    }

    // MARK: export / names

    @Test func jpegQualityClamp() {
        #expect(G.clampJPEGQuality(0.2) == 0.6)
        #expect(G.clampJPEGQuality(1.7) == 1.0)
        #expect(G.clampJPEGQuality(0.85) == 0.85)
        #expect(G.clampJPEGQuality(.nan) == 0.9)
    }

    @Test func templateFormatting() {
        let date = Date(timeIntervalSince1970: 1_764_000_000)        // 2025-11-24 16:00:00 UTC
        let utc = TimeZone(identifier: "UTC")!
        #expect(ScreenshotFileName.format(template: ScreenshotFileName.defaultTemplate, date: date, timeZone: utc) == "Screenshot 2025-11-24 at 16.00.00")
        #expect(ScreenshotFileName.format(template: "", date: date, timeZone: utc) == "Screenshot 2025-11-24 at 16.00.00")
        #expect(ScreenshotFileName.format(template: "'shot' HH:mm", date: date, timeZone: utc) == "shot 16-00")
        #expect(ScreenshotFileName.format(template: "'../../etc/passwd'", date: date, timeZone: utc) == "-..-etc-passwd")
        #expect(ScreenshotFileName.format(template: "Shot yy.MM.dd EEE a", date: date, timeZone: utc) == "Shot 25.11.24 Mon PM")
        #expect(ScreenshotFileName.format(template: "It''s 'dd' dd", date: date, timeZone: utc) == "It's dd 24")
        #expect(ScreenshotFileName.format(template: "'unterminated", date: date, timeZone: utc) == "unterminated")
    }

    @Test func sanitization() {
        #expect(ScreenshotFileName.sanitize("a/b:c") == "a-b-c")
        #expect(ScreenshotFileName.sanitize("  .hidden ") == "hidden")
        #expect(ScreenshotFileName.sanitize("..") == "Screenshot")
        #expect(ScreenshotFileName.sanitize("") == "Screenshot")
        #expect(ScreenshotFileName.sanitize("x\u{0}y\ny") == "x-y-y")
        #expect(ScreenshotFileName.sanitize("~root") == "root")
        #expect(ScreenshotFileName.sanitize(String(repeating: "a", count: 500)).count == 180)
        #expect(ScreenshotFileName.sanitize("Café 📸") == "Café 📸")
    }

    @Test func uniqueNamesNeverOverwrite() {
        let dir = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
        var taken: Set<String> = ["/tmp/shots/Shot.png", "/tmp/shots/Shot 2.png"]
        let u = ScreenshotFileName.uniqueURL(in: dir, base: "Shot", ext: "png") { taken.contains($0.path) }
        #expect(u.lastPathComponent == "Shot 3.png")
        taken = []
        #expect(ScreenshotFileName.uniqueURL(in: dir, base: "Shot", ext: ".jpg") { taken.contains($0.path) }.lastPathComponent == "Shot.jpg")
        #expect(ScreenshotFileName.uniqueURL(in: dir, base: "a/b", ext: "png") { _ in false }.lastPathComponent == "a-b.png")
    }

    // MARK: settings

    @Test func screenshotSettingsDefaultsAndClamps() {
        let s = Settings(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        #expect(s.screenshotDefaultAction == .copy && s.screenshotFullScreenAction == .copy && s.screenshotWindowAction == .editor)
        #expect(s.screenshotFormat == .png && s.screenshotJPEGQuality == 0.9)
        #expect(s.screenshotSaveFolder.hasSuffix("DittoMac Screenshots"))
        #expect(s.screenshotNameTemplate == ScreenshotFileName.defaultTemplate)
        #expect(s.screenshotAskWhereToSave && !s.screenshotIncludeCursor && s.screenshotDelaySeconds == 0)
        #expect(s.screenshotDimOpacity == 0.45 && s.screenshotShowMagnifier && s.screenshotAddToHistory && s.screenshotRememberTool)
        s.screenshotJPEGQuality = 0.1; #expect(s.screenshotJPEGQuality == 0.6)
        s.screenshotDelaySeconds = 7; #expect(s.screenshotDelaySeconds == 0)
        s.screenshotDelaySeconds = 5; #expect(s.screenshotDelaySeconds == 5)
        s.screenshotDimOpacity = 3; #expect(s.screenshotDimOpacity == 0.85)
        s.screenshotSaveFolder = "~/Desktop"; #expect(!s.screenshotSaveFolder.hasPrefix("~"))
        s.screenshotFormat = .jpg; #expect(s.screenshotFormat.uti == "public.jpeg")
        s.resetScreenshotSettings(); #expect(s.screenshotFormat == .png)
        #expect(Settings.screenshotKeys.count == 19)
    }

    @Test func screenshotHotkeysFallBackToDefaults() {
        let s = Settings(defaults: UserDefaults(suiteName: "test-\(UUID())")!)
        let area = KeyCombo(encoded: s.screenshotHotkey("captureArea"))
        #expect(area.keyCode == 0x15 && area.modifiers == KeyCombo.controlKey | KeyCombo.shiftKey)
        #expect(KeyCombo(encoded: s.screenshotHotkey("captureWindow")).keyCode == 0x17)
        #expect(KeyCombo(encoded: s.screenshotHotkey("captureFullScreen")).displayString == "⌃⇧3")
        s.setHotkey("captureArea", KeyCombo(keyCode: 0x00, modifiers: KeyCombo.cmdKey).encoded)
        #expect(KeyCombo(encoded: s.screenshotHotkey("captureArea")).keyCode == 0x00)
        s.setHotkey("captureWindow", 0)                                   // explicitly cleared = disabled
        #expect(s.screenshotHotkey("captureWindow") == 0)
        #expect(s.screenshotHotkey("unknown") == 0)
    }
}
