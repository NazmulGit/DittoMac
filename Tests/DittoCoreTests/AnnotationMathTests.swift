import Testing
import Foundation
import CoreGraphics
@testable import DittoCore

@Suite struct AnnotationMathTests {
    typealias M = AnnotationMath
    func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.001) -> Bool { abs(a - b) <= tol }

    @Test func constrain45Snaps() {
        let o = CGPoint.zero
        let h = M.constrain45(from: o, to: CGPoint(x: 100, y: 8))
        #expect(near(h.x, 100.3, 0.5) && near(h.y, 0))
        let d = M.constrain45(from: o, to: CGPoint(x: 50, y: 60))
        #expect(near(d.x, d.y))
        #expect(near(hypot(d.x, d.y), hypot(50, 60)))
        let v = M.constrain45(from: o, to: CGPoint(x: -3, y: -80))
        #expect(near(v.x, 0, 0.01) && v.y < 0)
        #expect(M.constrain45(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5)) == CGPoint(x: 5, y: 5))
    }

    @Test func squareConstrainKeepsQuadrant() {
        let p = M.squareConstrain(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: -5))
        #expect(p == CGPoint(x: 40, y: -20))
        let q = M.squareConstrain(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 30))
        #expect(q == CGPoint(x: 30, y: 30))
        let r = M.rect(from: CGPoint(x: 10, y: 10), to: p)
        #expect(r.width == r.height)
    }

    @Test func arrowHeadGeometry() {
        let h = M.arrowHead(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), width: 3)
        #expect(h.tip == CGPoint(x: 100, y: 0))
        #expect(near(h.left.x, h.right.x) && near(h.left.y, -h.right.y))
        #expect(h.left.x < 100 && h.shaftEnd.x < 100 && h.shaftEnd.x > h.left.x - 1)
        #expect(near(hypot(h.left.x - 100, h.left.y), M.arrowHeadLength(width: 3)))
        let big = M.arrowHead(from: .zero, to: CGPoint(x: 200, y: 0), width: 12)
        #expect(big.length > h.length)
        let tiny = M.arrowHead(from: .zero, to: CGPoint(x: 4, y: 0), width: 6)
        #expect(tiny.length <= 4.0001)
        let zero = M.arrowHead(from: .zero, to: .zero, width: 3)
        #expect(zero.length == 0)
    }

    @Test func smoothingStaysNearInput() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 25), CGPoint(x: 50, y: 5), CGPoint(x: 80, y: 0)]
        let s = M.smooth(pts, segments: 8)
        #expect(s.count == (pts.count - 1) * 8 + 1)
        #expect(s.first == pts.first && s.last == pts.last)
        let box = CGRect(x: 0, y: 0, width: 80, height: 25).insetBy(dx: -10, dy: -10)
        #expect(s.allSatisfy { box.contains($0) })
        #expect(M.smooth([CGPoint.zero, CGPoint(x: 1, y: 1)]) == [CGPoint.zero, CGPoint(x: 1, y: 1)])
    }

    @Test func decimateKeepsEnds() {
        let pts = (0...20).map { CGPoint(x: CGFloat($0) * 0.5, y: 0) }
        let d = M.decimate(pts, minDistance: 2)
        #expect(d.first == pts.first && d.last == pts.last)
        #expect(d.count < pts.count)
    }

    @Test func distances() {
        #expect(near(M.distanceToSegment(CGPoint(x: 5, y: 5), CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)), 5))
        #expect(near(M.distanceToSegment(CGPoint(x: 15, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)), 5))
        #expect(near(M.distanceToSegment(CGPoint(x: 3, y: 4), .zero, .zero), 5))
        #expect(M.distanceToPolyline(.zero, []) == .infinity)
        let r = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(near(M.distanceToRectOutline(CGPoint(x: 50, y: 3), r), 3))
        #expect(near(M.distanceToRectOutline(CGPoint(x: 50, y: 25), r), 25))
        #expect(M.distanceToEllipseOutline(CGPoint(x: 100, y: 25), r) < 0.01)
        #expect(M.distanceToEllipseOutline(CGPoint(x: 50, y: 25), r) > 10)
        #expect(M.ellipseContains(CGPoint(x: 50, y: 25), r) && !M.ellipseContains(CGPoint(x: 2, y: 2), r))
    }

    @Test func handleHitAndResize() {
        let r = CGRect(x: 10, y: 10, width: 100, height: 60)
        #expect(M.hitHandle(CGPoint(x: 12, y: 11), in: r, radius: 6) == .nw)
        #expect(M.hitHandle(CGPoint(x: 60, y: 69), in: r, radius: 6) == .s)
        #expect(M.hitHandle(CGPoint(x: 60, y: 40), in: r, radius: 6) == nil)
        let e = M.resize(r, handle: .e, to: CGPoint(x: 200, y: 999))
        #expect(e == CGRect(x: 10, y: 10, width: 190, height: 60))
        let flip = M.resize(r, handle: .nw, to: CGPoint(x: 150, y: 100))
        #expect(flip.minX == 110 && flip.maxX == 150 && flip.minY == 70 && flip.maxY == 100)
        let m = M.map(CGPoint(x: 60, y: 40), from: r, to: CGRect(x: 0, y: 0, width: 200, height: 120))
        #expect(near(m.x, 100) && near(m.y, 60))
        let t = M.map(CGPoint(x: 5, y: 5), from: CGRect(x: 5, y: 0, width: 0, height: 10), to: CGRect(x: 15, y: 0, width: 0, height: 10))
        #expect(near(t.x, 15))
    }

    @Test func stepRenumbering() {
        #expect(M.stepNumbers(isStep: [true, false, true, true]) == [1, nil, 2, 3])
        #expect(M.stepNumbers(isStep: [false, true, true]) == [nil, 1, 2])
        #expect(M.stepNumbers(isStep: []).isEmpty)
    }

    @Test func regionClamping() {
        let size = CGSize(width: 100, height: 80)
        #expect(M.clampRegion(CGRect(x: -10, y: -10, width: 30, height: 30), to: size) == CGRect(x: 0, y: 0, width: 20, height: 20))
        #expect(M.clampRegion(CGRect(x: 90, y: 70, width: 50, height: 50), to: size) == CGRect(x: 90, y: 70, width: 10, height: 10))
        #expect(M.clampRegion(CGRect(x: 200, y: 0, width: 10, height: 10), to: size) == nil)
        #expect(M.clampRegion(CGRect(x: 10, y: 10, width: 0.4, height: 20), to: size) == nil)
        let px = M.pixelRect(for: CGRect(x: 10.3, y: 5.2, width: 20.2, height: 10), scale: 2, imageWidth: 200, imageHeight: 160)
        #expect(px == CGRect(x: 20, y: 10, width: 41, height: 21))
        #expect(M.pixelRect(for: CGRect(x: 500, y: 0, width: 10, height: 10), scale: 2, imageWidth: 200, imageHeight: 160) == nil)
        #expect(M.regionStrength(forLineWidth: 1) == 4 && M.regionStrength(forLineWidth: 3) == 9 && M.regionStrength(forLineWidth: 40) == 36)
    }

    @Test func hexRoundTrip() {
        let c = M.parseHex("#FF8000")
        #expect(c != nil && c!.a == 1 && near(CGFloat(c!.g), 128.0 / 255))
        #expect(M.hexString(c!) == "#FF8000")
        let a = M.parseHex("33669980")
        #expect(a != nil && M.hexString(a!, includeAlpha: true) == "#33669980")
        #expect(M.hexString(a!) == "#336699")
        #expect(M.parseHex(" #abcdef ") != nil)
        for bad in ["", "#", "#12345", "#1234567", "#GG0000", "red", "#FFF", "#ＦＦ0000"] { #expect(M.parseHex(bad) == nil, "\(bad)") }
        #expect(M.hexString(.init(r: 2, g: -1, b: 0.5)) == "#FF0080")
    }

    @Test func clampsAndLuminance() {
        #expect(M.clampLineWidth(0) == 1 && M.clampLineWidth(100) == 40 && M.clampLineWidth(5) == 5 && M.clampLineWidth(.nan) == 1)
        #expect(M.clampFontSize(2) == 8 && M.clampFontSize(999) == 200)
        #expect(M.luminance(.init(r: 1, g: 1, b: 1)) > 0.99 && M.luminance(.init(r: 0, g: 0, b: 0)) == 0)
    }

    @Test func settingsPersistence() {
        let s = Settings(defaults: UserDefaults(suiteName: "test-annot-\(UUID())")!)
        #expect(s.screenshotLastTool == nil && s.screenshotLastColor == "#FF3B30")
        #expect(s.screenshotLastLineWidth == 3 && s.screenshotLastFontSize == 18)
        s.screenshotLastTool = "arrow"; s.screenshotLastColor = "#00FF00"; s.screenshotLastLineWidth = 99; s.screenshotLastFontSize = 24
        #expect(s.screenshotLastTool == "arrow" && s.screenshotLastColor == "#00FF00")
        #expect(s.screenshotLastLineWidth == 40 && s.screenshotLastFontSize == 24)
        s.screenshotLastColor = "nope"
        #expect(s.screenshotLastColor == "#00FF00")
    }
}
