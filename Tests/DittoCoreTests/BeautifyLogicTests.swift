import Testing
import Foundation
@testable import DittoCore

@Suite struct BeautifyLogicTests {
    @Test func autoLayoutAddsPaddingOnAllSides() {
        let r = BeautifyLayout.compute(imageWidth: 800, imageHeight: 400, pixelScale: 2, padding: 48, aspectRatio: nil)
        #expect(r.canvasWidth == 400 + 96 && r.canvasHeight == 200 + 96)
        #expect(r.pixelWidth == 992 && r.pixelHeight == 592)
        #expect(r.contentX == 48 && r.contentY == 48 && r.contentWidth == 400 && r.contentHeight == 200)
        #expect(!r.wasCapped && r.renderScale == 2)
    }

    @Test func aspectGrowsCanvasAndCentresContent() {
        // 400x200 pt + 48 padding = 496x296 → 1:1 grows height to 496.
        let sq = BeautifyLayout.compute(imageWidth: 400, imageHeight: 200, pixelScale: 1, padding: 48, aspectRatio: 1)
        #expect(sq.canvasWidth == 496 && sq.canvasHeight == 496)
        #expect(sq.contentX == 48 && sq.contentY == 48 + (496 - 296) / 2)
        // 16:9 on a tall image grows the width instead.
        let tall = BeautifyLayout.compute(imageWidth: 200, imageHeight: 600, pixelScale: 1, padding: 0, aspectRatio: 16.0 / 9)
        #expect(tall.canvasHeight == 600 && abs(tall.canvasWidth - 600 * 16 / 9) < 1e-9)
        #expect(abs(tall.contentX - (tall.canvasWidth - 200) / 2) < 1e-9)
        // Every aspect: the result matches the ratio within a pixel.
        for ratio in [16.0 / 9, 4.0 / 3, 1, 3.0 / 2] {
            let r = BeautifyLayout.compute(imageWidth: 1234, imageHeight: 777, pixelScale: 2, padding: 40, aspectRatio: ratio)
            #expect(abs(Double(r.pixelWidth) / Double(r.pixelHeight) - ratio) < 0.01)
        }
    }

    @Test func chromeHeightExtendsTheContent() {
        let r = BeautifyLayout.compute(imageWidth: 200, imageHeight: 100, pixelScale: 1, padding: 10, aspectRatio: nil, chromeHeight: 28)
        #expect(r.contentHeight == 128 && r.canvasHeight == 148 && r.chromeHeight == 28)
    }

    @Test func capsTheLongestSide() {
        let r = BeautifyLayout.compute(imageWidth: 30_000, imageHeight: 500, pixelScale: 2, padding: 48, aspectRatio: nil)
        #expect(r.pixelWidth == BeautifyLayout.maxSide)
        #expect(r.wasCapped && r.renderScale < 2)
        #expect(r.pixelHeight >= 1 && r.pixelHeight < 500)
        // Total-pixel guard: a 16384 x 16384 request is scaled below the 128 MP limit.
        let sq = BeautifyLayout.compute(imageWidth: 16_000, imageHeight: 16_000, pixelScale: 1, padding: 100, aspectRatio: nil)
        #expect(sq.pixelWidth * sq.pixelHeight <= BeautifyLayout.maxPixels + 20_000)
    }

    @Test func neverCrashesOnDegenerateInput() {
        for (w, h, s, p) in [(0, 0, 2.0, 48.0), (1, 1, 0.0, 48.0), (1, 1, -3.0, -9.0), (0, 10, Double.nan, Double.infinity),
                             (Int.max / 4, 5, 1.0, 1e12), (1, 1, 1e9, 0.0)] {
            let r = BeautifyLayout.compute(imageWidth: w, imageHeight: h, pixelScale: s, padding: p, aspectRatio: 0)
            #expect(r.pixelWidth >= 1 && r.pixelHeight >= 1)
            #expect(r.pixelWidth <= BeautifyLayout.maxSide && r.pixelHeight <= BeautifyLayout.maxSide)
        }
        let nan = BeautifyLayout.compute(imageWidth: 10, imageHeight: 10, pixelScale: 1, padding: 0, aspectRatio: .nan)
        #expect(nan.pixelWidth == 10)
    }

    @Test func hexColourParsingAndRoundTrip() {
        #expect(HexColor("#FF8000") == HexColor(r: 1, g: 128.0 / 255, b: 0))
        #expect(HexColor("f80")?.hex == "#FF8800")
        #expect(HexColor("#11223344")?.a == 0x44 / 255.0)
        #expect(HexColor("#11223344")?.hex == "#11223344")
        for s in ["#000000", "#FFFFFF", "#7F7FD5", "#86A8E7", "#010203"] { #expect(HexColor(s)?.hex == s) }
        for bad in ["", "#", "#12", "#12345", "#GGGGGG", "red", "#1234567", "#12 456", "0x123456", "#１２３４５６"] { #expect(HexColor(bad) == nil, "\(bad)") }
        #expect(HexColor(r: 2, g: -1, b: .nan).hex.count == 7)
    }
}

@Suite struct BeautifyPresetCatalogTests {
    @Test func atLeastTwelveDistinctlyNamedPresets() {
        let specs = BeautifyPresetCatalog.specs
        #expect(specs.count >= 12)
        #expect(Set(specs.map(\.name)).count == specs.count)
        for needed in ["Aurora", "Sunset", "Ocean", "Midnight", "Peach", "Mint", "Candy", "Slate", "Paper", "Mono", "Neon", "Forest",
                       "Clean White shadow", "Transparent shadow", "macOS window — Sunset", "macOS window — Dark", "Browser — Ocean"] {
            #expect(specs.contains { $0.name == needed }, "\(needed)")
        }
    }

    @Test func everyPresetIsValid() {
        for s in BeautifyPresetCatalog.specs {
            switch s.fill {
            case .gradient(let a, let b, let angle): #expect(HexColor(a) != nil && HexColor(b) != nil && (0...360).contains(angle), "\(s.name)")
            case .solid(let h): #expect(HexColor(h) != nil, "\(s.name)")
            case .transparent: break
            }
            #expect(HexColor(s.outlineColor) != nil)
            #expect((0...160).contains(s.padding) && (0...40).contains(s.cornerRadius), "\(s.name)")
            #expect((0...80).contains(s.shadowRadius) && (0...1).contains(s.shadowOpacity) && (0...40).contains(s.shadowOffsetY), "\(s.name)")
            #expect(BeautifyPresetCatalog.frames.contains(s.frame), "\(s.name)")
        }
        #expect(BeautifyPresetCatalog.specs.contains { $0.fill == .transparent })
        #expect(Set(BeautifyPresetCatalog.specs.map(\.frame)) == BeautifyPresetCatalog.frames)
    }
}
