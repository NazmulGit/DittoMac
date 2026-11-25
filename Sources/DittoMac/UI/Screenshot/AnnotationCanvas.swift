// AnnotationCanvas.swift — transparent view laid exactly over the selected region; draws and edits annotations.
import AppKit
import DittoCore

enum AnnotationTool: String, CaseIterable {
    case select, pen, line, arrow, rectangle, ellipse, marker, text, step, pixelate, blur, eyedropper
}

/// Transparent view laid exactly over the selected region; draws and edits annotations.
/// Coordinates are flipped (origin top-left), in points relative to the canvas.
@MainActor
final class AnnotationCanvas: NSView {
    /// Posted (object = the canvas) when tool, colour, width, font size, fill or chip settings or the undo state change.
    static let stateDidChange = Notification.Name("AnnotationCanvasStateDidChange")

    // MARK: Public API (stub contract)
    var tool: AnnotationTool = .pen {
        didSet {
            guard tool != oldValue else { return }
            if editor != nil { commitEditing() }
            if tool != .select { selection.removeAll() }
            hoverPoint = nil
            Settings.shared.screenshotLastTool = tool.rawValue
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            stateChanged()
        }
    }
    var color: NSColor = .systemRed {
        didSet {
            if let hex = Self.hex(of: color) { Settings.shared.screenshotLastColor = hex }
            if tool == .select, !selection.isEmpty { mutateSelection { $0.color = color } }
            editor?.style(fontSize: fontSize, color: color, chip: textChip)
            stateChanged()
        }
    }
    var lineWidth: CGFloat = 3 {
        didSet {
            let c = AnnotationMath.clampLineWidth(lineWidth)
            if c != lineWidth { lineWidth = c; return }
            Settings.shared.screenshotLastLineWidth = Double(c)
            if tool == .select, !selection.isEmpty { mutateSelection { if !$0.isText && !$0.isStep { $0.width = c } } }
            stateChanged()
        }
    }
    var fontSize: CGFloat = 18 {
        didSet {
            let c = AnnotationMath.clampFontSize(fontSize)
            if c != fontSize { fontSize = c; return }
            Settings.shared.screenshotLastFontSize = Double(c)
            if tool == .select, !selection.isEmpty { mutateSelection { if $0.isText || $0.isStep { $0.fontSize = c } } }
            editor?.style(fontSize: c, color: color, chip: textChip)
            stateChanged()
        }
    }
    /// Rectangle/ellipse are drawn filled (⌥ while dragging toggles this for one shape).
    var fillShapes = false { didSet { stateChanged() } }
    /// New text gets a contrasting background chip.
    var textChip = false {
        didSet { editor?.style(fontSize: fontSize, color: color, chip: textChip); stateChanged() }
    }
    /// Called after any change (to refresh undo/redo state).
    var onChange: (() -> Void)?
    /// Called when the eyedropper picks a colour (also sets `color`).
    var onPickColor: ((NSColor) -> Void)?

    var hasAnnotations: Bool { !items.isEmpty }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var annotationCount: Int { items.count }
    var isEditingText: Bool { editor != nil }
    var hasSelection: Bool { !selection.isEmpty }

    /// The pixels under the canvas (selection crop), used for pixelate/blur/eyedropper. `pixelScale` = pixels per point.
    func setBase(_ image: CGImage, pixelScale: CGFloat) {
        base = image
        self.pixelScale = max(pixelScale, 0.01)
        effects = AnnotationRegionEffects(base: image, pixelScale: self.pixelScale)
        needsDisplay = true
    }

    func undo() {
        if let e = editor { e.undoManager?.undo(); return }
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(items)
        items = prev
        selection = selection.filter { id in items.contains { $0.id == id } }
        didChange()
    }

    func redo() {
        if editor != nil { return }
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        selection = selection.filter { id in items.contains { $0.id == id } }
        didChange()
    }

    func clearAll() {
        cancelEditing()
        guard !items.isEmpty else { return }
        push()
        items = []
        selection = []
        didChange()
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        push()
        items.removeAll { selection.contains($0.id) }
        selection = []
        didChange()
    }

    /// The base image with every annotation rasterised at the base's pixel size; nil if no base set.
    func flattened() -> CGImage? {
        guard let base else { return nil }
        if editor != nil { commitEditing() }
        let sx = bounds.width > 1 ? CGFloat(base.width) / bounds.width : pixelScale
        let sy = bounds.height > 1 ? CGFloat(base.height) / bounds.height : pixelScale
        // If the canvas is not exactly the crop's size (rounding), fall back to the declared pixel scale.
        let useRatio = abs(sx - pixelScale) / pixelScale < 0.05 && abs(sy - pixelScale) / pixelScale < 0.05
        return AnnotationRenderer.flatten(base: base, items: items, sx: useRatio ? sx : pixelScale, sy: useRatio ? sy : pixelScale, effects: effects)
    }

    // MARK: State
    private var items: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private(set) var selection: Set<UUID> = []
    private var base: CGImage?
    private var pixelScale: CGFloat = 1
    private var effects: AnnotationRegionEffects?
    private var draft: Annotation?
    private var dragStart: CGPoint = .zero
    private var drag: DragState = .none
    private var hoverPoint: CGPoint?
    private var hoverColor: NSColor?
    private var editor: AnnotationTextEditor?
    private var editingID: UUID?
    private var trackingArea: NSTrackingArea?

    private enum DragHandle: Equatable { case endpoint(Int), box(AnnotationMath.Handle) }
    private enum DragState {
        case none
        case creating
        case moving(original: [Annotation], moved: Bool)
        case resizing(original: Annotation, handle: DragHandle, before: [Annotation], moved: Bool)
    }

    // MARK: Init
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let s = Settings.shared
        // "Remember the last annotation tool, colour and line width" (Screenshots settings); off = fresh defaults.
        if s.screenshotRememberTool {
            if let t = s.screenshotLastTool, let tool = AnnotationTool(rawValue: t) { self.tool = tool }
            if let c = Self.color(fromHex: s.screenshotLastColor) { self.color = c }
            self.lineWidth = CGFloat(s.screenshotLastLineWidth)
            self.fontSize = CGFloat(s.screenshotLastFontSize)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Annotation canvas")
        setAccessibilityHelp("Draw annotations over the screenshot. Single-letter keys select tools.")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }
    override func accessibilityValue() -> Any? { "\(items.count) annotations, tool \(tool.title)" }

    // MARK: Colour helpers
    static func hex(of c: NSColor) -> String? {
        let r = AnnotationRenderer.rgba(c)
        return AnnotationMath.hexString(r, includeAlpha: r.a < 0.999)
    }
    static func color(fromHex s: String) -> NSColor? {
        guard let c = AnnotationMath.parseHex(s) else { return nil }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    // MARK: Change tracking
    private func stateChanged() {
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
    }
    private func didChange() {
        needsDisplay = true
        stateChanged()
        onChange?()
    }
    private func push() {
        undoStack.append(items)
        if undoStack.count > 500 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    private func add(_ a: Annotation) {
        push()
        items.append(a)
        didChange()
    }
    /// Applies `f` to every selected annotation as one undoable edit.
    private func mutateSelection(_ f: (inout Annotation) -> Void) {
        var changed = false
        var new = items
        for i in new.indices where selection.contains(new[i].id) { f(&new[i]); changed = true }
        guard changed else { return }
        push()
        items = new
        didChange()
    }

    // MARK: Drawing
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var skip: Set<UUID> = []
        if let e = editingID { skip.insert(e) }
        var all = items
        if let d = draft { all.append(d) }
        AnnotationRenderer.draw(all, in: ctx, effects: effects, preview: true, skipping: skip)
        drawSelection(in: ctx)
        drawEyedropperSwatch(in: ctx)
    }

    private func handles(for a: Annotation) -> [(DragHandle, CGPoint)] {
        switch a.kind {
        case .line(let p, let q), .arrow(let p, let q): return [(.endpoint(0), p), (.endpoint(1), q)]
        case .step, .text:
            let f = a.frame
            return [.nw, .ne, .se, .sw].map { (DragHandle.box($0), AnnotationMath.handlePoint($0, in: f)) }
        default:
            let f = a.frame
            return AnnotationMath.Handle.allCases.map { (DragHandle.box($0), AnnotationMath.handlePoint($0, in: f)) }
        }
    }

    private func drawSelection(in ctx: CGContext) {
        guard tool == .select, !selection.isEmpty else { return }
        for a in items where selection.contains(a.id) {
            if a.id == editingID { continue }
            let vb = a.visualBounds
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            if !a.isLineLike { ctx.stroke(vb.insetBy(dx: -2, dy: -2)) }
            ctx.restoreGState()
            if selection.count == 1 {
                for (_, pt) in handles(for: a) {
                    let r = CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fill(r)
                    ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                    ctx.setLineWidth(1.5)
                    ctx.stroke(r)
                }
            }
        }
    }

    private func drawEyedropperSwatch(in ctx: CGContext) {
        guard tool == .eyedropper, let p = hoverPoint, let c = hoverColor else { return }
        let hex = Self.hex(of: c) ?? ""
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let ts = (hex as NSString).size(withAttributes: attrs)
        let box = CGSize(width: 26 + ts.width + 10, height: 24)
        var o = CGPoint(x: p.x + 16, y: p.y + 16)
        if o.x + box.width > bounds.maxX { o.x = p.x - 16 - box.width }
        if o.y + box.height > bounds.maxY { o.y = p.y - 16 - box.height }
        let r = CGRect(origin: o, size: box)
        ctx.setFillColor(NSColor(white: 0.1, alpha: 0.88).cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.fillPath()
        let sw = CGRect(x: r.minX + 5, y: r.minY + 5, width: 14, height: 14)
        ctx.setFillColor(c.cgColor); ctx.fill(sw)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.8).cgColor); ctx.setLineWidth(1); ctx.stroke(sw)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gc
        (hex as NSString).draw(at: CGPoint(x: r.minX + 24, y: r.minY + (r.height - ts.height) / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        // crosshair mark at the sampled pixel
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.stroke(CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
    }

    // MARK: Cursor & tracking
    override func resetCursorRects() {
        let c: NSCursor
        switch tool {
        case .select: c = .arrow
        case .text: c = .iBeam
        default: c = .crosshair
        }
        addCursorRect(bounds, cursor: c)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Keyboard
    override func keyDown(with event: NSEvent) {
        guard editor == nil else { super.keyDown(with: event); return }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty {
            switch event.keyCode {
            case 51, 117:                      // delete / forward delete
                if hasSelection { deleteSelected(); return }
            case 123, 124, 125, 126:           // arrows nudge the selection
                if hasSelection {
                    let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                    let d: CGSize
                    switch event.keyCode {
                    case 123: d = CGSize(width: -step, height: 0)
                    case 124: d = CGSize(width: step, height: 0)
                    case 125: d = CGSize(width: 0, height: step)
                    default: d = CGSize(width: 0, height: -step)
                    }
                    push()
                    items = items.map { selection.contains($0.id) ? $0.translated(by: d) : $0 }
                    didChange()
                    return
                }
            default: break
            }
            if let ch = event.charactersIgnoringModifiers?.first, let t = AnnotationTool.forShortcut(ch) {
                tool = t
                return
            }
        }
        super.keyDown(with: event)             // Esc and everything else keep travelling up the responder chain
    }

    // MARK: Mouse (NSEvent entry points forward to the point-based handlers below)
    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    override func mouseDown(with e: NSEvent) { pointerDown(point(e), modifiers: e.modifierFlags, clickCount: e.clickCount) }
    override func mouseDragged(with e: NSEvent) { pointerDragged(point(e), modifiers: e.modifierFlags) }
    override func mouseUp(with e: NSEvent) { pointerUp(point(e), modifiers: e.modifierFlags) }
    override func mouseMoved(with e: NSEvent) { pointerMoved(point(e)) }
    override func mouseExited(with e: NSEvent) { if hoverPoint != nil { hoverPoint = nil; hoverColor = nil; needsDisplay = true } }

    func pointerMoved(_ p: CGPoint) {
        guard tool == .eyedropper else { return }
        hoverPoint = p
        hoverColor = sampleColor(at: p)
        needsDisplay = true
    }

    func pointerDown(_ p: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int = 1) {
        if editor != nil { commitEditing() }
        window?.makeFirstResponder(self)
        dragStart = p
        switch tool {
        case .select: selectDown(p, modifiers: modifiers, clickCount: clickCount)
        case .pen, .marker:
            let kind: Annotation.Kind = tool == .pen ? .pen(points: [p]) : .marker(points: [p])
            draft = Annotation(kind: kind, color: color, width: lineWidth, fontSize: fontSize)
            drag = .creating
        case .line, .arrow, .rectangle, .ellipse, .pixelate, .blur:
            draft = nil
            drag = .creating
        case .text:
            if let hit = items.last(where: { $0.isText && $0.frame.contains(p) }) { beginEditing(existing: hit) }
            else { beginEditing(newAt: p) }
        case .step:
            add(Annotation(kind: .step(center: p), color: color, width: lineWidth, fontSize: fontSize))
            selection = []
        case .eyedropper:
            pick(at: p)
        }
        needsDisplay = true
    }

    func pointerDragged(_ p: CGPoint, modifiers m: NSEvent.ModifierFlags) {
        switch drag {
        case .creating:
            updateDraft(to: p, modifiers: m)
        case .moving(let original, _):
            let d = CGSize(width: p.x - dragStart.x, height: p.y - dragStart.y)
            items = items.map { a in
                guard selection.contains(a.id), let o = original.first(where: { $0.id == a.id }) else { return a }
                return o.translated(by: d)
            }
            drag = .moving(original: original, moved: true)
            needsDisplay = true
        case .resizing(let orig, let handle, let before, _):
            var new = orig
            switch handle {
            case .endpoint(let i):
                var q = p
                if case .line(let a, let b) = orig.kind {
                    let other = i == 0 ? b : a
                    if m.contains(.shift) { q = AnnotationMath.constrain45(from: other, to: p) }
                    new.kind = .line(a: i == 0 ? q : a, b: i == 1 ? q : b)
                } else if case .arrow(let a, let b) = orig.kind {
                    let other = i == 0 ? b : a
                    if m.contains(.shift) { q = AnnotationMath.constrain45(from: other, to: p) }
                    new.kind = .arrow(a: i == 0 ? q : a, b: i == 1 ? q : b)
                }
            case .box(let h):
                let old = orig.frame
                let target = AnnotationMath.resize(old, handle: h, to: p, minSize: 4)
                new = orig.transformed(from: old, to: target)
            }
            if let idx = items.firstIndex(where: { $0.id == orig.id }) { items[idx] = new }
            drag = .resizing(original: orig, handle: handle, before: before, moved: true)
            needsDisplay = true
        case .none: break
        }
    }

    func pointerUp(_ p: CGPoint, modifiers m: NSEvent.ModifierFlags) {
        defer { drag = .none; draft = nil; needsDisplay = true }
        switch drag {
        case .creating:
            updateDraft(to: p, modifiers: m)
            if let d = draft, Self.isMeaningful(d) { add(d) }
        case .moving(let original, let moved):
            if moved { undoStack.append(original); redoStack.removeAll(); didChange() }
        case .resizing(_, _, let before, let moved):
            if moved { undoStack.append(before); redoStack.removeAll(); didChange() }
        case .none: break
        }
    }

    private static func isMeaningful(_ a: Annotation) -> Bool {
        switch a.kind {
        case .pen, .marker, .step, .text: return true
        case .line(let p, let q), .arrow(let p, let q): return hypot(p.x - q.x, p.y - q.y) >= 3
        case .rectangle(let r, _), .ellipse(let r, _): return r.width >= 3 || r.height >= 3
        case .region(let r, _): return r.width >= 4 && r.height >= 4
        }
    }

    private func updateDraft(to p: CGPoint, modifiers m: NSEvent.ModifierFlags) {
        let a = dragStart
        func make(_ k: Annotation.Kind) -> Annotation {
            var d = Annotation(kind: k, color: color, width: lineWidth, fontSize: fontSize)
            if let old = draft { d.id = old.id }
            return d
        }
        switch tool {
        case .pen, .marker:
            guard var d = draft else { return }
            // drop points that barely moved; keeps arrays small for long strokes
            switch d.kind {
            case .pen(var pts): if hypot(p.x - pts[pts.count - 1].x, p.y - pts[pts.count - 1].y) >= 0.8 { pts.append(p) }; d.kind = .pen(points: pts)
            case .marker(var pts):
                var q = p
                if m.contains(.shift) { q = CGPoint(x: p.x, y: pts[0].y) }     // ⇧ keeps a marker stroke straight
                if hypot(q.x - pts[pts.count - 1].x, q.y - pts[pts.count - 1].y) >= 0.8 { pts.append(q) }
                if m.contains(.shift) { pts = [pts[0], q] }
                d.kind = .marker(points: pts)
            default: break
            }
            draft = d
        case .line:
            draft = make(.line(a: a, b: m.contains(.shift) ? AnnotationMath.constrain45(from: a, to: p) : p))
        case .arrow:
            draft = make(.arrow(a: a, b: m.contains(.shift) ? AnnotationMath.constrain45(from: a, to: p) : p))
        case .rectangle, .ellipse:
            let end = m.contains(.shift) ? AnnotationMath.squareConstrain(from: a, to: p) : p
            let r = AnnotationMath.rect(from: a, to: end)
            let filled = fillShapes != m.contains(.option)
            draft = make(tool == .rectangle ? .rectangle(r, filled: filled) : .ellipse(r, filled: filled))
        case .pixelate, .blur:
            let r = AnnotationMath.clampRegion(AnnotationMath.rect(from: a, to: p), to: bounds.size) ?? .zero
            draft = make(.region(r, mode: tool == .pixelate ? .pixelate : .blur))
        default: break
        }
        needsDisplay = true
    }

    // MARK: Select tool
    private func selectDown(_ p: CGPoint, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        // handle of the single selected item
        if selection.count == 1, let sel = items.first(where: { selection.contains($0.id) }) {
            for (h, pt) in handles(for: sel) where hypot(p.x - pt.x, p.y - pt.y) <= 7 {
                drag = .resizing(original: sel, handle: h, before: items, moved: false)
                return
            }
        }
        if let hit = items.last(where: { $0.hit(p) }) {
            if clickCount >= 2, hit.isText { selection = [hit.id]; beginEditing(existing: hit); return }
            if modifiers.contains(.shift) {
                if selection.contains(hit.id) { selection.remove(hit.id) } else { selection.insert(hit.id) }
            } else if !selection.contains(hit.id) {
                selection = [hit.id]
            }
            if selection.contains(hit.id) { drag = .moving(original: items, moved: false) }
            stateChanged()
        } else {
            if !modifiers.contains(.shift) { selection = [] }
            drag = .none
            stateChanged()
        }
    }

    // MARK: Text editing
    private func beginEditing(newAt p: CGPoint) {
        let lineH = Annotation.textContentSize("M", fontSize: fontSize).height
        let o = CGPoint(x: p.x - Annotation.textPadding, y: p.y - lineH / 2 - Annotation.textPadding)
        startEditor(origin: o, string: "", fontSize: fontSize, color: color, chip: textChip, existing: nil)
    }
    private func beginEditing(existing a: Annotation) {
        guard case .text(let o, let s, let chip) = a.kind else { return }
        editingID = a.id
        startEditor(origin: o, string: s, fontSize: a.fontSize, color: a.color, chip: chip, existing: a)
    }
    private func startEditor(origin: CGPoint, string: String, fontSize: CGFloat, color: NSColor, chip: Bool, existing: Annotation?) {
        let e = AnnotationTextEditor(origin: origin, string: string, fontSize: fontSize, color: color, chip: chip)
        e.onCommit = { [weak self] in self?.commitEditing() }
        e.onCancel = { [weak self] in self?.cancelEditing() }
        editor = e
        editingID = existing?.id
        addSubview(e)
        window?.makeFirstResponder(e)
        e.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        needsDisplay = true
    }

    /// Test/automation hook: type into the active text editor.
    func setEditorText(_ s: String) { editor?.string = s; editor?.fit() }

    func commitEditing() {
        guard let e = editor else { return }
        let s = e.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = e.frame.origin
        let existing = editingID
        teardownEditor()
        if let id = existing, let idx = items.firstIndex(where: { $0.id == id }) {
            if s.isEmpty {
                push(); items.remove(at: idx); selection.remove(id)
            } else if case .text(_, let old, _) = items[idx].kind, old != e.string {
                push()
                if case .text(let o, _, let chip) = items[idx].kind { items[idx].kind = .text(origin: o, string: e.string, chip: chip) }
            } else { needsDisplay = true; return }
            didChange()
        } else if !s.isEmpty {
            add(Annotation(kind: .text(origin: origin, string: e.string, chip: textChip), color: color, width: lineWidth, fontSize: fontSize))
        }
        needsDisplay = true
    }

    func cancelEditing() {
        guard editor != nil else { return }
        teardownEditor()
        needsDisplay = true
    }

    private func teardownEditor() {
        editor?.removeFromSuperview()
        editor = nil
        editingID = nil
        window?.makeFirstResponder(self)
    }

    // MARK: Eyedropper
    /// Colour of the base pixel under `p` (canvas points), in sRGB.
    func sampleColor(at p: CGPoint) -> NSColor? {
        guard let base else { return nil }
        let px = min(max(Int((p.x * pixelScale).rounded(.down)), 0), base.width - 1)
        let py = min(max(Int((p.y * pixelScale).rounded(.down)), 0), base.height - 1)
        var pixel = [UInt8](repeating: 0, count: 4)
        let ok = pixel.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(base, in: CGRect(x: -px, y: -(base.height - 1 - py), width: base.width, height: base.height))
            return true
        }
        guard ok else { return nil }
        return NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    private func pick(at p: CGPoint) {
        guard let c = sampleColor(at: p) else { return }
        hoverPoint = p; hoverColor = c
        color = c
        if let hex = Self.hex(of: c) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
        }
        onPickColor?(c)
        needsDisplay = true
        onChange?()
    }
}
