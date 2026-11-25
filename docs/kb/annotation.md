# Annotation tools (screenshot editor)

Files: `Sources/DittoMac/UI/Screenshot/Annotation{Canvas,Toolbar,Model,Renderer,TextEditor}.swift`,
`Sources/DittoCore/AnnotationMath.swift` (pure, tested), `Sources/DittoCore/Settings+Annotation.swift`,
`Tests/DittoCoreTests/AnnotationMathTests.swift`. Proof image: `docs/assets/annotation-tools.png`.

## Architecture
- `Annotation` (value type: kind + colour + width + fontSize + id) in canvas points, y down (`AnnotationCanvas.isFlipped`).
- Undo/redo = snapshots of the `[Annotation]` array (max 500). Moves/resizes record one snapshot per drag. Redo clears on any new edit.
- Step numbers are never stored: `AnnotationMath.stepNumbers` derives 1,2,3… from z-order, so deleting renumbers.
- One renderer (`AnnotationRenderer.draw`) serves the live view (`preview: true`) and `flattened()` (`preview: false`).
  The flatten context is created at the base's pixel size, base drawn 1:1, then the CTM is flipped and scaled by pixels-per-point.
- Pixelate/blur are vector regions. `AnnotationRegionEffects` crops the base (top-left pixel rect via
  `AnnotationMath.pixelRect`), runs `CIFilter.pixellate` (center = crop origin so blocks align) or `gaussianBlur`
  (`clampedToExtent` then `cropped(to:)`), and caches the CGImage per region. CIContext has colour management off, so pixels pass through exactly.
  Strength = `regionStrength(forLineWidth:)` = clamp(3 x line width, 4...36) points.
- Marker: multiply blend inside a transparency layer (overlaps in one stroke do not darken) at 0.8 alpha when flattening; plain 0.4 alpha colour in the view (the base is under the view, not in it).
- Text: `AnnotationTextEditor` (NSTextView subview). Return commits, ⇧Return newline, Esc cancels. Esc is consumed only while editing; otherwise `keyDown` calls `super` so the capture overlay sees it.
- Eyedropper: samples the base through a 1x1 sRGB CGContext; click sets `color`, copies `#RRGGBB` to the pasteboard, fires `onPickColor`.

## Interaction summary
| Tool (key) | Gesture |
|---|---|
| Select (V) | click, ⇧-click multi-select, drag to move, handles to resize (line/arrow: endpoint handles, ⇧ = 45°), ⌫ delete, arrows nudge 1 pt (⇧ 10), double-click text to edit; changing colour/width/size recolours the selection |
| Pen (P) | freehand, decimated and Catmull-Rom smoothed |
| Line (L) / Arrow (A) | drag; ⇧ = 45° steps; arrow head scales with width |
| Rectangle (R) / Ellipse (O) | drag; ⇧ square/circle; ⌥ toggles fill (`fillShapes` default) |
| Marker (M) | drag; ⇧ keeps it horizontal |
| Text (T) | click to place; click an existing text to edit |
| Step (N) | click to drop a numbered badge (size from `fontSize`) |
| Pixelate (X) / Blur (B) | drag a region (clamped to the canvas) |
| Eyedropper (I) | hover shows swatch + hex, click picks |

Single-letter shortcuts work only while the canvas is first responder and no text is being edited, with no ⌘/⌃/⌥.

## Persistence
`Settings.screenshotLastTool` (raw tool name), `screenshotLastColor` (`#RRGGBB[AA]`), `screenshotLastLineWidth`, `screenshotLastFontSize`.
Written on every change, restored in `AnnotationCanvas.init`. Invalid stored values fall back to red / 3 / 18.

## API for the capture agent
- `AnnotationCanvas`: stub API unchanged, plus `fillShapes`, `textChip`, `annotationCount`, `isEditingText`, `hasSelection`,
  `commitEditing()`, `cancelEditing()`, `static let stateDidChange: Notification.Name`, and the point-based entry points
  `pointerDown/Dragged/Up/Moved` (used by tests; NSEvent overrides forward to them).
- `AnnotationToolbarView(canvas:)`: ~40 pt wide; height depends on the tool (option rows appear/disappear). `onSizeChange` fires when
  `intrinsicContentSize` changes; the toolbar also refreshes itself from `stateDidChange`, so `refresh()` is only needed for manual calls.
- Call `canvas.commitEditing()` (done automatically by `flattened()`) before saving if you handle the commit yourself.

## Offscreen verification
No window is needed: build a canvas with a synthetic base, drive it through `pointerDown/Dragged/Up`, then
`flattened()` -> PNG, and `bitmapImageRepForCachingDisplay` + `cacheDisplay` for the live view and toolbar.
NSVisualEffectView renders flat grey offscreen (no vibrancy), so toolbar proofs show the panel without the blur.
Quirks hit: drawing a cached rep into a flipped NSImage needs `respectFlipped: true`; SwiftPM test targets ignore symlinked test files.
