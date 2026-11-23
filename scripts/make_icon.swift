#!/usr/bin/env swift
// Renders the DittoMac app icon as a 1024x1024 PNG.
//
// Usage: swift scripts/make_icon.swift out.png
//    or: swiftc -O -o /tmp/make_icon scripts/make_icon.swift && /tmp/make_icon out.png
//
// Design: Big-Sur-style rounded square (inset 100 px, corner radius ~22% of the
// tile) with a deep teal -> blue vertical gradient, a white clipboard board with a
// clip at the top, and two offset "history" cards behind it in translucent white.

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 2 else {
    fputs("usage: make_icon.swift out.png\n", stderr)
    exit(2)
}
let outPath = args[1]
let canvas: CGFloat = 1024

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fputs("error: no sRGB colour space\n", stderr)
    exit(1)
}

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas),
    pixelsHigh: Int(canvas),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("error: could not allocate bitmap\n", stderr)
    exit(1)
}
rep.size = NSSize(width: canvas, height: canvas)

guard let nsContext = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("error: could not create graphics context\n", stderr)
    exit(1)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsContext
let ctx = nsContext.cgContext

ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

// MARK: - Tile

let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
let tileRadius = tile.width * 0.2237
let tilePath = CGPath(roundedRect: tile, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil)

// Soft drop shadow beneath the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 32, color: CGColor(gray: 0, alpha: 0.30))
ctx.setFillColor(CGColor(red: 0.04, green: 0.42, blue: 0.52, alpha: 1))
ctx.addPath(tilePath)
ctx.fillPath()
ctx.restoreGState()

// Vertical gradient: deep teal (top) to blue (bottom). CG's origin is bottom-left,
// so the top of the tile is at maxY.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradientColors = [
    CGColor(red: 0.02, green: 0.56, blue: 0.60, alpha: 1), // deep teal
    CGColor(red: 0.07, green: 0.30, blue: 0.80, alpha: 1), // blue
] as CFArray
if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0, 1]) {
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: canvas / 2, y: tile.maxY),
        end: CGPoint(x: canvas / 2, y: tile.minY),
        options: []
    )
}
// Subtle top sheen for depth.
if let sheen = CGGradient(
    colorsSpace: colorSpace,
    colors: [CGColor(gray: 1, alpha: 0.14), CGColor(gray: 1, alpha: 0)] as CFArray,
    locations: [0, 1]
) {
    ctx.drawLinearGradient(
        sheen,
        start: CGPoint(x: canvas / 2, y: tile.maxY),
        end: CGPoint(x: canvas / 2, y: tile.midY),
        options: []
    )
}
ctx.restoreGState()

// MARK: - Clipboard artwork

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let centerX = canvas / 2
let boardWidth: CGFloat = 400
let boardHeight: CGFloat = 500
let boardCenterY: CGFloat = 500
let boardRect = CGRect(
    x: centerX - boardWidth / 2,
    y: boardCenterY - boardHeight / 2,
    width: boardWidth,
    height: boardHeight
)

// History cards stacked behind the board (furthest first), offset up and right.
let cardWidth: CGFloat = 340
let cardHeight: CGFloat = 460
let cardOffsets: [(dx: CGFloat, dy: CGFloat, alpha: CGFloat)] = [
    (dx: 72, dy: 52, alpha: 0.22),
    (dx: 36, dy: 26, alpha: 0.40),
]
for card in cardOffsets {
    let rect = CGRect(
        x: centerX - cardWidth / 2 + card.dx,
        y: boardCenterY - cardHeight / 2 + card.dy,
        width: cardWidth,
        height: cardHeight
    )
    ctx.setFillColor(CGColor(gray: 1, alpha: card.alpha))
    ctx.addPath(roundedRect(rect, radius: 48))
    ctx.fillPath()
}

// Board with a soft shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 36, color: CGColor(gray: 0, alpha: 0.25))
ctx.setFillColor(CGColor(gray: 1, alpha: 1))
ctx.addPath(roundedRect(boardRect, radius: 56))
ctx.fillPath()
ctx.restoreGState()

// Stylised text lines on the board.
let lineColor = CGColor(red: 0.10, green: 0.36, blue: 0.80, alpha: 0.28)
let lineSpecs: [(y: CGFloat, width: CGFloat)] = [
    (y: 640, width: 280),
    (y: 572, width: 280),
    (y: 504, width: 280),
    (y: 436, width: 180),
]
ctx.setFillColor(lineColor)
for line in lineSpecs {
    let rect = CGRect(x: centerX - line.width / 2, y: line.y, width: line.width, height: 26)
    ctx.addPath(roundedRect(rect, radius: 13))
    ctx.fillPath()
}

// Clip straddling the top edge of the board.
let clipRect = CGRect(x: centerX - 95, y: boardRect.maxY - 46, width: 190, height: 92)
ctx.setFillColor(CGColor(red: 0.05, green: 0.36, blue: 0.62, alpha: 1))
ctx.addPath(roundedRect(clipRect, radius: 30))
ctx.fillPath()

// Small highlight on the clip so it reads as a separate piece.
let clipHighlight = CGRect(x: centerX - 40, y: clipRect.maxY - 22, width: 80, height: 10)
ctx.setFillColor(CGColor(gray: 1, alpha: 0.35))
ctx.addPath(roundedRect(clipHighlight, radius: 5))
ctx.fillPath()

NSGraphicsContext.restoreGraphicsState()

// MARK: - Write PNG

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("error: PNG encoding failed\n", stderr)
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath), options: .atomic)
} catch {
    fputs("error: could not write \(outPath): \(error)\n", stderr)
    exit(1)
}
print("wrote \(outPath) (\(Int(canvas))x\(Int(canvas)))")
