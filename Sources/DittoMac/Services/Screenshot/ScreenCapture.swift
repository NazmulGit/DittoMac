// ScreenCapture.swift — frozen per-display snapshots + on-screen window list.
// macOS 14+: ScreenCaptureKit (SCScreenshotManager). macOS 13: CGDisplayCreateImage (deprecated in 14, so only behind
// #available). Injectable through `ScreenCaptureProviding` so the overlay can be exercised with synthetic images.

import AppKit
import ScreenCaptureKit
import DittoCore

/// One display, frozen at capture time.
struct DisplaySnapshot {
    let displayID: CGDirectDisplayID
    /// AppKit global frame in points (NSScreen.frame).
    let frame: CGRect
    /// Image at native pixels (rows top-down, covering `frame`).
    let image: CGImage
    /// Backing scale reported by the system (2 on Retina).
    let backingScale: CGFloat

    /// Pixels per point actually present in `image` (use this for crops; it can differ slightly from backingScale).
    var pixelScale: CGFloat { frame.width > 0 ? CGFloat(image.width) / frame.width : backingScale }
    /// Overlay-local bounds (flipped view space).
    var localBounds: CGRect { CGRect(origin: .zero, size: frame.size) }
}

/// A normal on-screen window (window-capture mode).
struct CaptureWindowInfo {
    let windowID: CGWindowID
    /// AppKit global frame in points.
    let frame: CGRect
    let ownerName: String
    let title: String
}

enum ScreenCaptureError: LocalizedError {
    case noPermission, noDisplays, failed(String)
    var errorDescription: String? {
        switch self {
        case .noPermission: return "DittoMac doesn't have Screen Recording permission."
        case .noDisplays: return "No display could be captured."
        case .failed(let m): return "Screen capture failed: \(m)"
        }
    }
}

@MainActor
protocol ScreenCaptureProviding: AnyObject {
    func hasPermission() -> Bool
    /// Snapshot of every display (frozen frame per display).
    func snapshotAllDisplays(includeCursor: Bool) async throws -> [DisplaySnapshot]
    /// On-screen, normal-layer windows front to back, excluding the given process (our own overlay windows).
    func onScreenWindows(excludingPID: pid_t) -> [CaptureWindowInfo]
}

@MainActor
final class SystemScreenCapture: ScreenCaptureProviding {

    func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    func snapshotAllDisplays(includeCursor: Bool) async throws -> [DisplaySnapshot] {
        guard hasPermission() else { throw ScreenCaptureError.noPermission }
        let screens = NSScreen.screens
        var result: [DisplaySnapshot] = []
        if #available(macOS 14.0, *) {
            result = try await captureWithScreenCaptureKit(screens: screens, includeCursor: includeCursor)
        } else {
            result = captureWithCoreGraphics(screens: screens, includeCursor: includeCursor)
        }
        guard !result.isEmpty else { throw ScreenCaptureError.noDisplays }
        return result
    }

    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit(screens: [NSScreen], includeCursor: Bool) async throws -> [DisplaySnapshot] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.failed(error.localizedDescription)
        }
        var out: [DisplaySnapshot] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = max(1, Int((filter.contentRect.width * scale).rounded()))
            config.height = max(1, Int((filter.contentRect.height * scale).rounded()))
            config.showsCursor = includeCursor
            config.captureResolution = .best
            config.scalesToFit = false
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let screen = screens.first { $0.displayID == display.displayID }
                let frame = screen?.frame ?? ScreenshotGeometry.flipQuartzAppKit(display.frame, primaryHeight: Self.primaryHeight)
                out.append(DisplaySnapshot(displayID: display.displayID, frame: frame, image: image,
                                           backingScale: screen?.backingScaleFactor ?? scale))
            } catch {
                // One failing display (e.g. disconnecting) shouldn't abort the others.
                NSLog("DittoMac: capture of display \(display.displayID) failed: \(error.localizedDescription)")
            }
        }
        if out.isEmpty, let first = content.displays.first {
            _ = first
            throw ScreenCaptureError.failed("no display image returned")
        }
        return out
    }

    /// macOS 13 fallback.
    private func captureWithCoreGraphics(screens: [NSScreen], includeCursor: Bool) -> [DisplaySnapshot] {
        var out: [DisplaySnapshot] = []
        let cursor = includeCursor ? Self.currentCursor() : nil
        for screen in screens {
            guard let id = screen.displayID, var image = CGDisplayCreateImage(id) else { continue }
            if let cursor, screen.frame.contains(cursor.location),
               let composited = Self.composite(cursor: cursor, onto: image, displayFrame: screen.frame) {
                image = composited
            }
            out.append(DisplaySnapshot(displayID: id, frame: screen.frame, image: image, backingScale: screen.backingScaleFactor))
        }
        return out
    }

    private struct CursorSnapshot { let image: NSImage; let hotSpot: NSPoint; let location: NSPoint }

    private static func currentCursor() -> CursorSnapshot? {
        guard let c = NSCursor.currentSystem else { return nil }
        return CursorSnapshot(image: c.image, hotSpot: c.hotSpot, location: NSEvent.mouseLocation)
    }

    private static func composite(cursor: CursorSnapshot, onto image: CGImage, displayFrame f: CGRect) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let scale = CGFloat(w) / f.width
        guard let cg = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // Pixel position (top-down) of the cursor's top-left corner, converted to CGContext's bottom-up space.
        let px = ScreenshotGeometry.globalToPixel(cursor.location, displayFrame: f, scale: scale)
        let size = CGSize(width: cursor.image.size.width * scale, height: cursor.image.size.height * scale)
        let x = px.x - cursor.hotSpot.x * scale
        let yTop = px.y - cursor.hotSpot.y * scale
        ctx.draw(cg, in: CGRect(x: x, y: CGFloat(h) - yTop - size.height, width: size.width, height: size.height))
        return ctx.makeImage()
    }

    static var primaryHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0
    }

    func onScreenWindows(excludingPID: pid_t) -> [CaptureWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let primary = Self.primaryHeight
        var out: [CaptureWindowInfo] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int, pid_t(pid) != excludingPID,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let qb = CGRect(dictionaryRepresentation: boundsDict),
                  qb.width >= 24, qb.height >= 24,
                  let num = w[kCGWindowNumber as String] as? Int
            else { continue }
            if let alpha = w[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            out.append(CaptureWindowInfo(windowID: CGWindowID(num),
                                         frame: ScreenshotGeometry.flipQuartzAppKit(qb, primaryHeight: primary),
                                         ownerName: w[kCGWindowOwnerName as String] as? String ?? "",
                                         title: w[kCGWindowName as String] as? String ?? ""))
        }
        return out
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

// MARK: - Image helpers

enum CaptureImage {
    /// Crops a flipped-view rect (points) out of a display snapshot.
    static func crop(_ snapshot: DisplaySnapshot, viewRect: CGRect) -> CGImage? {
        let px = ScreenshotGeometry.viewRectToPixels(viewRect, scale: snapshot.pixelScale,
                                                     imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height))
        guard px.width >= 1, px.height >= 1 else { return nil }
        return snapshot.image.cropping(to: px)
    }

    /// RGBA of one pixel (top-down coordinates) or nil when out of range.
    static func color(in image: CGImage, x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02X%02X%02X", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()),
                      Int((s.blueComponent * 255).rounded()))
    }
}
