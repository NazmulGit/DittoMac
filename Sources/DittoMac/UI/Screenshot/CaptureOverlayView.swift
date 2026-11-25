// CaptureOverlayView.swift — Lightshot-style overlay for one display: frozen screenshot, dimming, drag-to-select,
// 8 resize handles, size badge, loupe, window highlight; hosts the annotation canvas, tool strip and action bar.
// All geometry is in this view's flipped point space; pixels only appear at crop/export time.

import AppKit
import DittoCore

enum CaptureMode { case area, window, fullScreen }

/// Actions offered by the action bar / keyboard.
enum CaptureAction: String, CaseIterable {
    case upload, share, searchSimilar, print, copy, save, beautify, pin, close
}

struct CaptureOverlayConfig {
    var mode: CaptureMode = .area
    var dimOpacity: CGFloat = 0.45
    var showMagnifier = true
    /// On-screen windows (AppKit global frames), front to back.
    var windows: [CaptureWindowInfo] = []
    var beautifyOn = false
}

@MainActor
protocol CaptureOverlayDelegate: AnyObject {
    /// False when another display holds an annotated selection that must not be discarded.
    func overlayShouldBeginSelection(_ view: CaptureOverlayView) -> Bool
    /// A new selection started on this display (others must clear theirs).
    func overlayDidBeginSelection(_ view: CaptureOverlayView)
    /// The user finished a selection. `instantCopy` = ⌘ held on mouse-up; `windowClick` = picked by clicking a window.
    func overlay(_ view: CaptureOverlayView, didFinishSelection instantCopy: Bool, windowClick: Bool)
    func overlay(_ view: CaptureOverlayView, perform action: CaptureAction, sender: NSView?)
    func overlayDidCancel(_ view: CaptureOverlayView)
}

@MainActor
final class CaptureOverlayView: NSView {
    let snapshot: DisplaySnapshot
    var config: CaptureOverlayConfig { didSet { actionBar?.beautifyOn = config.beautifyOn; chrome.needsDisplay = true } }
    weak var delegate: CaptureOverlayDelegate?

    /// Current selection (flipped view points), nil when nothing is selected.
    private(set) var selection: CGRect?
    private(set) var canvas: AnnotationCanvas?
    private(set) var toolbar: AnnotationToolbarView?
    private(set) var actionBar: CaptureActionBar?

    private enum Drag { case none, creating(CGPoint), moving(CGPoint, CGRect), resizing(ResizeHandle, CGRect) }
    private var drag: Drag = .none
    private var didDrag = false
    fileprivate(set) var mouse: CGPoint?
    fileprivate(set) var hoverWindow: CaptureWindowInfo?
    fileprivate var isAdjusting: Bool { if case .none = drag { return false } else { return true } }

    private let backdrop: CaptureBackdropView
    fileprivate let chrome = CaptureChromeView()
    private var tracking: NSTrackingArea?

    static let handleSize: CGFloat = 9
    static let handleTolerance: CGFloat = 7
    static let borderBand: CGFloat = 4
    static let minSelection: CGFloat = 4

    init(snapshot: DisplaySnapshot, config: CaptureOverlayConfig) {
        self.snapshot = snapshot
        self.config = config
        backdrop = CaptureBackdropView(image: snapshot.image)
        super.init(frame: snapshot.localBounds)
        wantsLayer = true
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        chrome.frame = bounds
        chrome.autoresizingMask = [.width, .height]
        chrome.owner = self
        addSubview(backdrop)
        addSubview(chrome)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Screenshot selection")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The selection is frozen once annotations exist (they're positioned relative to the canvas).
    var selectionLocked: Bool { canvas?.hasAnnotations == true }
    var isEditing: Bool { canvas != nil }

    // MARK: tracking / cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        hoverWindow = nil
        chrome.needsDisplay = true      // the loupe and hint disappear: rare, redraw everything
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let oldMouse = mouse, oldHover = hoverWindow
        mouse = p
        if config.mode == .window, selection == nil { hoverWindow = window(at: p) }
        updateCursor(at: p)
        chrome.invalidateForMove(oldMouse: oldMouse, oldSelection: selection, oldHover: oldHover)
    }

    /// Tool letters (P, R, T …) reach the canvas even when a click made the overlay itself first responder.
    override func keyDown(with event: NSEvent) {
        if let canvas { canvas.keyDown(with: event) } else { super.keyDown(with: event) }
    }

    private func updateCursor(at p: CGPoint) {
        if let v = hitTest(convert(p, to: superview)), v !== self, v !== chrome, v !== backdrop {
            return                                             // canvas / bars manage their own cursor
        }
        if let sel = selection, !selectionLocked {
            if let h = ScreenshotGeometry.hitHandle(at: p, in: sel, tolerance: Self.handleTolerance) {
                switch h {
                case .left, .right: NSCursor.resizeLeftRight.set()
                case .top, .bottom: NSCursor.resizeUpDown.set()
                default: NSCursor.crosshair.set()
                }
                return
            }
            if canMove(at: p, in: sel) { NSCursor.openHand.set(); return }
        }
        NSCursor.crosshair.set()
    }

    private func canMove(at p: CGPoint, in sel: CGRect) -> Bool {
        if ScreenshotGeometry.isOnBorder(p, of: sel, band: Self.borderBand) { return true }
        guard sel.contains(p) else { return false }
        guard let canvas else { return true }
        return canvas.tool == .select && !canvas.hasAnnotations
    }

    // MARK: hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === chrome || hit === backdrop { return self }
        if let tb = toolbar, hit === tb || hit.isDescendant(of: tb) { return hit }
        if let ab = actionBar, hit === ab || hit.isDescendant(of: ab) { return hit }
        let p = convert(point, from: superview)
        if let sel = selection, !selectionLocked {
            if ScreenshotGeometry.hitHandle(at: p, in: sel, tolerance: Self.handleTolerance) != nil { return self }
            if canMove(at: p, in: sel) { return self }
        }
        return hit
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let p = clampToBounds(convert(event.locationInWindow, from: nil))
        didDrag = false
        if let sel = selection {
            if selectionLocked { NSSound.beep(); return }      // keep annotations safe
            if let h = ScreenshotGeometry.hitHandle(at: p, in: sel, tolerance: Self.handleTolerance) {
                drag = .resizing(h, sel); hideEditingChrome(); return
            }
            if canMove(at: p, in: sel) {
                drag = .moving(p, sel); NSCursor.closedHand.set(); hideEditingChrome(); return
            }
        }
        // Start a new selection (discarding an unannotated one).
        if delegate?.overlayShouldBeginSelection(self) == false { NSSound.beep(); return }
        removeEditing()
        selection = nil
        drag = .creating(p)
        delegate?.overlayDidBeginSelection(self)
        chrome.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clampToBounds(convert(event.locationInWindow, from: nil))
        let oldMouse = mouse, oldSelection = selection, oldHover = hoverWindow
        mouse = p
        switch drag {
        case .none: return
        case .creating(let start):
            if !didDrag, hypot(p.x - start.x, p.y - start.y) < 3 { return }
            didDrag = true
            hoverWindow = nil
            selection = ScreenshotGeometry.normalizedRect(from: start, to: p)
        case .moving(let start, let orig):
            didDrag = true
            selection = ScreenshotGeometry.nudge(orig, dx: (p.x - start.x).rounded(), dy: (p.y - start.y).rounded(), bounds: bounds)
        case .resizing(let h, let orig):
            didDrag = true
            let aspect: CGFloat? = event.modifierFlags.contains(.shift) && orig.height > 0 ? orig.width / orig.height : nil
            selection = ScreenshotGeometry.resize(orig, handle: h, to: p,
                                                  minSize: CGSize(width: Self.minSelection, height: Self.minSelection),
                                                  bounds: bounds, aspect: aspect)
        }
        if let canvas, let sel = selection { canvas.frame = sel }
        chrome.invalidateForMove(oldMouse: oldMouse, oldSelection: oldSelection, oldHover: oldHover)
    }

    override func mouseUp(with event: NSEvent) {
        let p = clampToBounds(convert(event.locationInWindow, from: nil))
        let instant = event.modifierFlags.contains(.command)
        let current = drag
        drag = .none
        switch current {
        case .none: return
        case .creating:
            if !didDrag {
                // Click without drag: pick the window under the pointer (window mode, or any mode when hovering one).
                if config.mode == .window, let w = window(at: p) {
                    let r = ScreenshotGeometry.clamp(ScreenshotGeometry.globalRectToView(w.frame, displayFrame: snapshot.frame), to: bounds)
                    if r.width >= Self.minSelection, r.height >= Self.minSelection {
                        selection = r.integral
                        hoverWindow = nil
                        chrome.needsDisplay = true
                        delegate?.overlay(self, didFinishSelection: instant, windowClick: true)
                        return
                    }
                }
                selection = nil
                chrome.needsDisplay = true
                return
            }
            guard let sel = selection, sel.width >= Self.minSelection, sel.height >= Self.minSelection else {
                selection = nil; chrome.needsDisplay = true; return
            }
            selection = ScreenshotGeometry.clamp(sel.integral, to: bounds)
            chrome.needsDisplay = true
            delegate?.overlay(self, didFinishSelection: instant, windowClick: false)
        case .moving, .resizing:
            if let sel = selection { selection = ScreenshotGeometry.clamp(sel.integral, to: bounds) }
            if isEditing { refreshEditing() } else if selection != nil {
                delegate?.overlay(self, didFinishSelection: instant && didDrag, windowClick: false)
            }
            updateCursor(at: p)
            chrome.needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Lightshot: right-click cancels a fresh selection, otherwise the whole capture.
        if selection != nil, !selectionLocked { clearSelection() } else { delegate?.overlayDidCancel(self) }
    }

    private func clampToBounds(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    private func window(at p: CGPoint) -> CaptureWindowInfo? {
        let g = ScreenshotGeometry.viewToGlobal(p, displayFrame: snapshot.frame)
        return config.windows.first { $0.frame.contains(g) }
    }

    // MARK: programmatic selection

    /// Sets the selection (e.g. ⌘A, full-screen mode, window pick). Does not notify the delegate.
    func setSelection(_ r: CGRect?) {
        guard !selectionLocked else { return }
        selection = r.map { ScreenshotGeometry.clamp($0.integral, to: bounds) }
        if isEditing { if selection == nil { removeEditing() } else { refreshEditing() } }
        hoverWindow = nil
        chrome.needsDisplay = true
    }

    func clearSelection() {
        guard !selectionLocked else { return }
        removeEditing()
        selection = nil
        chrome.needsDisplay = true
    }

    /// Arrow-key nudge. Returns false when there is nothing to move.
    @discardableResult func nudge(dx: CGFloat, dy: CGFloat) -> Bool {
        guard let sel = selection, !selectionLocked else { return false }
        selection = ScreenshotGeometry.nudge(sel, dx: dx, dy: dy, bounds: bounds)
        if isEditing { refreshEditing() }
        chrome.needsDisplay = true
        return true
    }

    /// Crop of the current selection at native pixels.
    func selectionImage() -> CGImage? {
        guard let sel = selection else { return nil }
        return CaptureImage.crop(snapshot, viewRect: sel)
    }

    /// Final pixels: annotations flattened onto the crop (Beautify is applied by the caller).
    func renderedSelection() -> CGImage? {
        if let canvas, let flat = canvas.flattened() { return flat }
        return selectionImage()
    }

    var selectionPixelSize: CGSize? {
        guard let sel = selection else { return nil }
        let px = ScreenshotGeometry.viewRectToPixels(sel, scale: snapshot.pixelScale,
                                                     imageSize: CGSize(width: snapshot.image.width, height: snapshot.image.height))
        return px.size
    }

    // MARK: editing chrome (canvas + tool strip + action bar)

    func beginEditing() {
        guard let sel = selection else { return }
        if canvas == nil {
            let c = AnnotationCanvas(frame: sel)
            c.onChange = { [weak self] in
                guard let self else { return }
                self.toolbar?.refresh()
                self.actionBar?.refresh()
                self.chrome.needsDisplay = true
            }
            addSubview(c, positioned: .above, relativeTo: backdrop)
            canvas = c
            let tb = AnnotationToolbarView(canvas: c)
            addSubview(tb)
            toolbar = tb
            let ab = CaptureActionBar()
            ab.beautifyOn = config.beautifyOn
            ab.onAction = { [weak self] action, sender in
                guard let self else { return }
                self.delegate?.overlay(self, perform: action, sender: sender)
            }
            ab.canUndo = { [weak c] in c?.canUndo ?? false }
            addSubview(ab)
            actionBar = ab
        }
        refreshEditing()
        // Without this the overlay stays first responder and tool letters (P, R, T …) do nothing.
        window?.makeFirstResponder(canvas)
    }

    /// Re-crops the canvas base and re-places the bars after the selection changed.
    func refreshEditing() {
        guard let sel = selection, let canvas else { return }
        canvas.frame = sel
        if let img = selectionImage() { canvas.setBase(img, pixelScale: snapshot.pixelScale) }
        layoutEditingChrome()
    }

    private func hideEditingChrome() {
        toolbar?.isHidden = true
        actionBar?.isHidden = true
    }

    func layoutEditingChrome() {
        guard let sel = selection else { return }
        let area = bounds.insetBy(dx: 6, dy: 6)
        if let ab = actionBar {
            let size = ab.fittingSize
            let placed = ScreenshotGeometry.placePanel(size: size, anchor: sel, bounds: area,
                                                       sides: [.below, .above, .insideBottom], alignment: .trailing, gap: 8)
            ab.frame = placed.frame.integral
            ab.isHidden = false
        }
        if let tb = toolbar {
            var size = tb.intrinsicContentSize
            if size.width <= 0 || size.height <= 0 { size = tb.fittingSize }
            size.height = min(size.height, area.height)
            let placed = ScreenshotGeometry.placePanel(size: size, anchor: sel, bounds: area,
                                                       sides: [.right, .left, .insideRight], alignment: .trailing, gap: 8)
            var f = placed.frame
            // Don't cover the action bar when both end up in the same corner.
            if let ab = actionBar, f.intersects(ab.frame) {
                f.origin.y = max(area.minY, ab.frame.minY - 8 - f.height)
                if f.intersects(ab.frame) { f.origin.y = min(area.maxY - f.height, ab.frame.maxY + 8) }
            }
            tb.frame = f.integral
            tb.isHidden = false
            tb.refresh()
        }
        actionBar?.refresh()
    }

    func removeEditing() {
        canvas?.removeFromSuperview(); canvas = nil
        toolbar?.removeFromSuperview(); toolbar = nil
        actionBar?.removeFromSuperview(); actionBar = nil
    }
}

// MARK: - Backdrop (the frozen screen)

@MainActor
final class CaptureBackdropView: NSView {
    private let image: NSImage
    init(image: CGImage) {
        self.image = NSImage(cgImage: image, size: .zero)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
}

// MARK: - Chrome (dimming, border, handles, badge, loupe, hints)

@MainActor
final class CaptureChromeView: NSView {
    weak var owner: CaptureOverlayView?
    private lazy var snapshotImage: NSImage? = owner.map { NSImage(cgImage: $0.snapshot.image, size: .zero) }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let o = owner else { return }
        let dim = NSColor.black.withAlphaComponent(o.config.dimOpacity)

        // 1. Dimming with a hole for the selection (or hovered window).
        let hole: CGRect? = o.selection ?? o.hoverWindow.map {
            ScreenshotGeometry.clamp(ScreenshotGeometry.globalRectToView($0.frame, displayFrame: o.snapshot.frame), to: bounds)
        }
        let path = NSBezierPath(rect: bounds)
        if let hole { path.append(NSBezierPath(rect: hole)); path.windingRule = .evenOdd }
        dim.setFill()
        path.fill()

        if let sel = o.selection {
            drawSelection(sel, locked: o.selectionLocked, adjusting: o.isAdjusting)
            if let px = o.selectionPixelSize { drawSizeBadge(for: sel, pixels: px) }
        } else if let w = o.hoverWindow, let hole {
            drawWindowHighlight(hole, info: w)
        }

        if let m = o.mouse, o.config.showMagnifier, !o.isEditing || o.isAdjusting {
            drawLoupe(at: m)
        }
        if o.selection == nil, !o.isAdjusting, let m = o.mouse, bounds.contains(m) {
            drawHint(o.config.mode == .window
                     ? "Click a window to capture it, or drag to select an area · ⌘A whole screen · Esc cancel"
                     : "Drag to select an area · ⌘A whole screen · hold ⌘ on release to copy · Esc cancel")
        }
    }

    private func drawSelection(_ r: CGRect, locked: Bool, adjusting: Bool) {
        let outline = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        NSColor.black.withAlphaComponent(0.55).setStroke()
        outline.stroke()
        let line = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        line.lineWidth = 1
        NSColor.white.setStroke()
        line.setLineDash([4, 3], count: 2, phase: 0)
        line.stroke()
        guard !locked else { return }
        let s = CaptureOverlayView.handleSize
        for h in ResizeHandle.allCases {
            if !h.isCorner, (h == .top || h == .bottom ? r.width : r.height) < s * 3 { continue }
            let hr = ScreenshotGeometry.handleRect(h, of: r, size: s)
            let p = NSBezierPath(roundedRect: hr, xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            p.fill()
            NSColor(calibratedWhite: 0.15, alpha: 0.9).setStroke()
            p.lineWidth = 1
            p.stroke()
        }
    }

    private func pill(_ text: String, font: NSFont, at origin: CGPoint, maxX: CGFloat? = nil) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        var r = CGRect(x: origin.x, y: origin.y, width: ceil(size.width) + 14, height: ceil(size.height) + 6)
        if let maxX, r.maxX > maxX { r.origin.x = maxX - r.width }
        r = ScreenshotGeometry.keepInside(r, bounds: bounds.insetBy(dx: 4, dy: 4))
        let bg = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor(calibratedWhite: 0.08, alpha: 0.82).setFill()
        bg.fill()
        (text as NSString).draw(at: CGPoint(x: r.minX + 7, y: r.minY + 3), withAttributes: attrs)
        return r
    }

    private func drawSizeBadge(for sel: CGRect, pixels: CGSize) {
        let text = "\(Int(pixels.width)) × \(Int(pixels.height))"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let h: CGFloat = 20
        let y = sel.minY - h - 6 >= bounds.minY + 4 ? sel.minY - h - 6 : sel.minY + 6
        let x = sel.minY - h - 6 >= bounds.minY + 4 ? sel.minX : sel.minX + 6
        _ = pill(text, font: font, at: CGPoint(x: x, y: y))
    }

    private func drawWindowHighlight(_ r: CGRect, info: CaptureWindowInfo) {
        let p = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5))
        p.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        p.stroke()
        NSColor.controlAccentColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(rect: r).fill()
        let name = info.title.isEmpty ? info.ownerName : "\(info.ownerName) — \(info.title)"
        if !name.isEmpty {
            _ = pill(String(name.prefix(80)), font: .systemFont(ofSize: 12, weight: .medium), at: CGPoint(x: r.minX + 8, y: r.minY + 8))
        }
    }

    private func drawHint(_ text: String) {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let w = (text as NSString).size(withAttributes: [.font: font]).width + 14
        _ = pill(text, font: font, at: CGPoint(x: bounds.midX - w / 2, y: bounds.minY + 28))
    }

    static let loupeCells = 15
    static let loupeZoom: CGFloat = 8
    static let loupeLabelHeight: CGFloat = 36

    /// Where the loupe card is drawn for a pointer at `m` (flips to the other side near the right / bottom edge).
    static func loupeFrame(at m: CGPoint, in bounds: CGRect) -> CGRect {
        let side = CGFloat(loupeCells) * loupeZoom
        var frame = CGRect(x: m.x + 22, y: m.y + 22, width: side, height: side + loupeLabelHeight)
        if frame.maxX > bounds.maxX - 4 { frame.origin.x = m.x - 22 - frame.width }
        if frame.maxY > bounds.maxY - 4 { frame.origin.y = m.y - 22 - frame.height }
        return frame
    }

    /// Redraws only what a pointer move changed: the old and new loupe, and the old / new selection (with room for
    /// handles and the size badge) or hovered window. A pointer entering / leaving still redraws everything.
    func invalidateForMove(oldMouse: CGPoint?, oldSelection: CGRect?, oldHover: CaptureWindowInfo?) {
        guard let o = owner else { return }
        guard oldMouse != nil, o.mouse != nil else { needsDisplay = true; return }
        var dirty = CGRect.null
        if o.config.showMagnifier, !o.isEditing || o.isAdjusting {
            for m in [oldMouse, o.mouse].compactMap({ $0 }) {
                dirty = dirty.union(Self.loupeFrame(at: m, in: bounds).insetBy(dx: -16, dy: -16))   // card, shadow
            }
        }
        if oldSelection != o.selection {
            for r in [oldSelection, o.selection].compactMap({ $0 }) { dirty = dirty.union(r.insetBy(dx: -44, dy: -44)) }
        }
        if oldHover?.frame != o.hoverWindow?.frame {
            for w in [oldHover, o.hoverWindow].compactMap({ $0 }) {
                let r = ScreenshotGeometry.globalRectToView(w.frame, displayFrame: o.snapshot.frame)
                dirty = dirty.union(r.insetBy(dx: -6, dy: -6))
            }
        }
        if !dirty.isNull { setNeedsDisplay(dirty.intersection(bounds)) }
    }

    /// Magnifier: 15×15 source pixels at ~8×, crosshair, pixel coordinates and colour.
    private func drawLoupe(at m: CGPoint) {
        guard let o = owner, let img = snapshotImage else { return }
        let scale = o.snapshot.pixelScale
        let px = Int((m.x * scale).rounded(.down)), py = Int((m.y * scale).rounded(.down))
        let n = Self.loupeCells, zoom = Self.loupeZoom
        let side = CGFloat(n) * zoom
        let frame = Self.loupeFrame(at: m, in: bounds)
        let lens = CGRect(x: frame.minX, y: frame.minY, width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 8
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        let card = NSBezierPath(roundedRect: frame.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 0.1, alpha: 0.95).setFill()
        card.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: lens, xRadius: 5, yRadius: 5).addClip()
        NSColor.black.setFill()
        lens.fill()
        // Source rect in the NSImage's point space (= pixels here; image size is in pixels) — y is bottom-up.
        let imgH = img.size.height
        let src = CGRect(x: CGFloat(px - n / 2), y: imgH - CGFloat(py - n / 2) - CGFloat(n), width: CGFloat(n), height: CGFloat(n))
        NSGraphicsContext.current?.imageInterpolation = .none
        img.draw(in: lens, from: src, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        // Grid + centre pixel.
        NSColor(calibratedWhite: 0.5, alpha: 0.22).setStroke()
        let grid = NSBezierPath()
        for i in 1..<n {
            let o = lens.minX + CGFloat(i) * zoom
            grid.move(to: CGPoint(x: o, y: lens.minY)); grid.line(to: CGPoint(x: o, y: lens.maxY))
            let q = lens.minY + CGFloat(i) * zoom
            grid.move(to: CGPoint(x: lens.minX, y: q)); grid.line(to: CGPoint(x: lens.maxX, y: q))
        }
        grid.lineWidth = 0.5
        grid.stroke()
        // Crosshair through the centre pixel.
        let mid = lens.minX + (CGFloat(n / 2) + 0.5) * zoom, midY = lens.minY + (CGFloat(n / 2) + 0.5) * zoom
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: mid, y: lens.minY)); cross.line(to: CGPoint(x: mid, y: lens.maxY))
        cross.move(to: CGPoint(x: lens.minX, y: midY)); cross.line(to: CGPoint(x: lens.maxX, y: midY))
        cross.lineWidth = 1
        NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke()
        cross.stroke()
        let c = CGRect(x: lens.minX + CGFloat(n / 2) * zoom, y: lens.minY + CGFloat(n / 2) * zoom, width: zoom, height: zoom)
        NSColor.black.setStroke(); NSBezierPath(rect: c.insetBy(dx: -1, dy: -1)).stroke()
        NSColor.white.setStroke(); NSBezierPath(rect: c).stroke()
        NSGraphicsContext.restoreGraphicsState()

        let color = CaptureImage.color(in: o.snapshot.image, x: px, y: py)
        let hex = color.map(CaptureImage.hex) ?? "—"
        let swatch = CGRect(x: frame.minX + 6, y: lens.maxY + 9, width: 18, height: 18)
        if let color {
            color.setFill()
            let sp = NSBezierPath(roundedRect: swatch, xRadius: 4, yRadius: 4)
            sp.fill()
            NSColor.white.withAlphaComponent(0.6).setStroke(); sp.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        (hex as NSString).draw(at: CGPoint(x: swatch.maxX + 8, y: lens.maxY + 4), withAttributes: attrs)
        let sub: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                  .foregroundColor: NSColor.white.withAlphaComponent(0.65)]
        ("\(px), \(py)" as NSString).draw(at: CGPoint(x: swatch.maxX + 8, y: lens.maxY + 19), withAttributes: sub)
    }
}
