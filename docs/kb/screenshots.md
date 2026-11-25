# Screenshots (Lightshot-style capture)

DittoMac replaces Lightshot: a hotkey freezes every display, you drag a selection on the frozen image, annotate it,
then copy / save / upload / share / print / pin it. Each finished screenshot is also added to the clip history
(setting), so it shows up in Quick Paste.

## Flow

1. **Trigger**: hotkey (registered by `ScreenshotService.registerHotkeys()` under the names `captureArea`,
   `captureWindow`, `captureFullScreen`) or the status menu (*Capture Area… / Window… / Full Screen*).
2. **Permission**: `CGPreflightScreenCaptureAccess()`. When it's missing, a friendly alert explains Screen Recording
   and offers *Grant Access* (calls `CGRequestScreenCaptureAccess()` on that click; if macOS won't prompt again it
   opens System Settings) and *Open System Settings*
   (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`).
3. **Delay** (0/3/5/10 s): a countdown HUD (`CaptureCountdown`) is shown and hidden 0.2 s before the snapshot.
4. **Snapshot** (`SystemScreenCapture`, behind the `ScreenCaptureProviding` protocol): one frozen image per display at
   native pixels with its AppKit frame and scale. macOS 14+: `SCScreenshotManager.captureImage` per `SCDisplay`
   (`width = contentRect.width × pointPixelScale`, `showsCursor` from the setting). macOS 13: `CGDisplayCreateImage`
   (only behind `#available`; the cursor is composited manually when enabled). Window mode also reads
   `CGWindowListCopyWindowInfo` (layer 0, on-screen, not our process) front to back.
5. **Full screen** with a non-editor action → straight to the output (whole display under the mouse). Otherwise:
6. **Overlay** (`CaptureSession`): one `CaptureOverlayWindow` per display (borderless, `.screenSaver` level,
   `canJoinAllSpaces + fullScreenAuxiliary`, key-capable) hosting a `CaptureOverlayView`: frozen image, dimming outside
   the selection, crosshair, loupe with pixel colour, size badge (pixels), 8 handles. Selections live on the display
   where the drag started; starting one on another display clears the old one.
7. **Editing**: after selecting, an `AnnotationCanvas` is laid exactly over the selection (`setBase(crop, pixelScale:)`),
   the `AnnotationToolbarView` sits beside it (right, else left, else inside) and the `CaptureActionBar` below it
   (else above, else inside). Once the canvas has annotations the selection is frozen (handles hidden) because
   annotations are positioned relative to the canvas.
8. **Output**: `canvas.flattened()` (or the raw crop) → optional Beautify (`BeautifyRenderer.render`) → action.
   Overlay windows close *before* anything modal (save panel, print panel, share panel) so nothing is hidden behind a
   screen-saver-level window.

All overlay geometry is in the flipped view's points; pixels appear only in `ScreenshotGeometry.viewRectToPixels`
(crop/export). Pure helpers live in `DittoCore/ScreenshotGeometry.swift` and are unit-tested.

## Keyboard map (overlay)

| Key | Action |
|---|---|
| drag | select an area (on the display where the drag starts) |
| drag handle / ⇧-drag handle | resize / resize keeping the aspect ratio |
| drag border (or inside, before annotating with the Select tool) | move the selection |
| click (window mode) | select the window under the pointer (still editable) |
| hold ⌘ while releasing the drag | copy instantly and close (Lightshot) |
| ⌘A | select the whole display under the mouse |
| ← → ↑ ↓ / ⇧ + arrows | nudge 1 pt / 10 pt |
| Return / Enter | default action (Preferences: copy / save / upload / nothing) |
| ⌘C | copy (PNG to the clipboard + history) |
| ⌘S | save (save panel or auto-save folder) |
| ⌘D | upload → link copied + share panel |
| ⌘G | search similar images (uploads first) |
| ⌘P | print |
| ⌘B | Beautify popover (per-capture toggle + style + live preview) |
| ⌘T | pin to screen |
| ⌘Z / ⇧⌘Z | undo / redo annotations |
| Delete | delete the selected annotation |
| Esc, ⌘W, right-click | close the Beautify popover, else cancel the capture |

Action bar buttons (left → right): Upload, Share, Search similar, Print │ Beautify, Pin │ Copy, Save │ Close. Hover
labels are drawn by the bar itself because system tooltips can render below a `.screenSaver` window. While a text
annotation is being edited (first responder is an `NSText`), keys go to the text editor instead.

Pinned screenshots: drag to move, ⌥-scroll or pinch to resize, double-click or Esc to close, right-click for
Copy / Save / Actual Size / Close.

## Global hotkeys

Defaults ⌃⇧4 area, ⌃⇧5 window, ⌃⇧3 full screen (the system owns ⌘⇧3/4/5). Stored in `Settings.hotkeys` via
`setHotkey`; `Settings.screenshotHotkey(name)` returns the stored value when the key exists (0 = turned off by the
user) and the default when it was never set. Preferences › Screenshots has recorders and *Restore Defaults*.

## Output details

- **Copy**: PNG via `state.paste.writeToPasteboard` (tagged internal, so `ClipboardMonitor` ignores it).
- **History**: with `screenshotAddToHistory` (default on) the PNG is added once per capture via
  `store.addClip(formats: [png], description: "Screenshot W×H", sourceApp: "screenshot")` + `clipsChanged()` — for
  copy, save, upload/share, print and pin.
- **Save**: PNG/JPG/BMP (JPEG quality 0.6–1.0, default 0.9). Folder default `~/Pictures/DittoMac Screenshots`,
  created with 0700. Name template default `Screenshot yyyy-MM-dd 'at' HH.mm.ss` — tokens `yyyy yy MMMM MMM MM dd
  EEEE EEE HH hh mm ss SSS a`, literal text in 'quotes', everything else literal; names are sanitised (no `/ : \`,
  control characters, leading dots or `~`, ≤ 180 chars) and never overwrite (`Name 2.png`, `Name 3.png`, …).
- **Upload / Share / Search similar**: `CaptureSharePanel` (floating panel) uses `ImageUploader.shared.ensureReady` +
  `upload`; on success the link is copied, a HUD confirms it and the panel offers Copy / Open, web-intent networks
  (`ShareLinks.url(for:link:title:)`), the macOS share picker (`NSSharingServicePicker` with a temporary PNG removed
  when the panel closes) and Search similar (`ShareLinks.similarImageSearch`). Uploads are off until configured
  (see the Upload & Share section); links are public to anyone who has them.
- **Sound**: optional camera sound (system "Screen Capture"/"Grab" sound when present, else Tink).

## Permission notes

- `CGPreflightScreenCaptureAccess()` never prompts and is safe anywhere; `CGRequestScreenCaptureAccess()` is only
  called from an explicit click (alert button or Preferences).
- After granting, macOS may require quitting and reopening DittoMac.
- DittoMac is ad-hoc signed, so macOS ties the grant to that exact build: after an update the permission may need
  to be switched off and on again (or removed and re-added) in Privacy & Security › Screen & System Audio Recording.

## Settings (`Settings+Screenshots.swift`, `Settings.screenshotKeys`)

`screenshotDefaultAction` (copy) · `screenshotFullScreenAction` (copy) · `screenshotWindowAction` (editor) ·
`screenshotFormat` (png) · `screenshotJPEGQuality` (0.9) · `screenshotSaveFolder` · `screenshotNameTemplate` ·
`screenshotAskWhereToSave` (true) · `screenshotIncludeCursor` (false) · `screenshotDelaySeconds` (0) ·
`screenshotDimOpacity` (0.45, 0…0.85) · `screenshotShowMagnifier` (true) · `screenshotPlaySound` (true) ·
`screenshotAddToHistory` (true) · `screenshotRememberTool` (true). The remembered tool/colour/width/font size
(`screenshotLastTool` …) are declared by the annotation code in `Settings+Annotation.swift`; Beautify's
`beautifyAutoApply` / `beautifyDefaultStyle` live in `Settings+Beautify.swift` and are only read here.

## Files

| File | Role |
|---|---|
| `Services/Screenshot/ScreenshotService.swift` | `ScreenshotServicing`: hotkeys, permission, countdown → snapshot → session / direct output |
| `Services/Screenshot/ScreenCapture.swift` | `ScreenCaptureProviding`, `SystemScreenCapture` (SCK 14+ / CG 13), `DisplaySnapshot`, window list, crop/colour helpers |
| `Services/Screenshot/CaptureSession.swift` | overlay windows per display, keyboard map, actions, Beautify state |
| `Services/Screenshot/ScreenshotOutput.swift` | encode PNG/JPG/BMP, copy + history, save (panel/auto, unique names), print, sound |
| `Services/Screenshot/ScreenCapturePermission.swift` | preflight / request / System Settings / explanation alert |
| `UI/Screenshot/CaptureOverlayView.swift` | the overlay view (backdrop, chrome: dim, border, handles, badge, loupe, window highlight, hints) |
| `UI/Screenshot/CaptureOverlayWindow.swift` | borderless `.screenSaver` window, key routing |
| `UI/Screenshot/CaptureActionBar.swift` | action bar, hover labels |
| `UI/Screenshot/CaptureBeautifyPopover.swift` | per-capture Beautify toggle, `BeautifyControls`, live preview |
| `UI/Screenshot/CaptureSharePanel.swift` | upload progress, link, networks, share picker, search similar |
| `UI/Screenshot/CaptureCountdown.swift` | delayed-capture countdown |
| `UI/Screenshot/PinnedScreenshotWindow.swift` | pin to screen |
| `UI/PreferencesScreenshots.swift` | Preferences › Screenshots (embeds `BeautifyDefaultsView` and `UploadSettingsView`) |
| `DittoCore/ScreenshotGeometry.swift` | selection, handles, resize/aspect, nudge, coordinate conversions, panel placement, file names, JPEG clamp |
| `DittoCore/Settings+Screenshots.swift` | settings + hotkey defaults |
| `Tests/DittoCoreTests/ScreenshotGeometryTests.swift` | swift-testing coverage of the above |

## Testing without touching the real screen

The overlay only depends on `DisplaySnapshot` values, so it can be driven with a synthetic image: create a
`CaptureOverlayView(snapshot:config:)`, feed it synthetic `NSEvent.mouseEvent`s (mouse down/drag/up), and render it
with `cacheDisplay(in:to:)` into a bitmap — no window, no Screen Recording permission, no `CGRequestScreenCaptureAccess`.
`ScreenshotService(state:capture:)` accepts any `ScreenCaptureProviding` for the same reason.

## Behaviour notes (bug-fix pass after the v1.2 security review)
* **Keys:** after a selection is made the canvas becomes first responder (`beginEditing`), and the overlay forwards `keyDown` to it, so tool letters (P, R, T …) work. Arrow keys nudge the *annotation* when one is selected, otherwise the selection (`CaptureSession.handleKey`); Esc and ⌘ shortcuts still go through the session first.
* **Save:** the session ends only after a successful save. Cancelling the Save panel (or a write error) returns to the still-editable overlay; while the panel is up the overlays drop from screen-saver level so it is visible, and the "foreign modal window cancels the capture" guard is suspended.
* **Custom colour:** "More colours…" is an in-overlay popover (swatch grid + hex field). `NSColorWell` / `NSColorPanel` were removed because the shared colour panel opens behind the screen-saver-level overlay.
* **Countdown:** Esc (local monitor, plus a global monitor when macOS allows it) or pressing a capture hotkey again cancels it and clears `busy`; the timer runs in `.common` run-loop modes so it keeps ticking while a menu is tracked.
* **Starting a capture:** from the status menu the capture waits 0.25 s so the fading menu isn't in the snapshot; the Quick Paste popup is hidden first. The screen-parameters observer is registered before the capture `await`, and `ScreenshotGeometry.displaysMatch` re-validates the display frames afterwards; a mismatch cancels with a visible message.
* **Hotkeys:** a capture hotkey macOS refuses is reported with a HUD message and under Preferences › Screenshots › Shortcuts (`ScreenshotServicing.hotkeyProblems`). The clash check (`HotkeyClash`, `Settings.effectiveHotkeys`) includes the capture defaults even when never set.
* **History:** Save reuses the PNG it already encoded; a cancelled Print adds nothing; an oversize (`.rejected`) screenshot shows a HUD message instead of silently not being added.
* **Beautify default:** the capture default is `settings.beautifyDefaultStyle` (same as Preferences).
* **Share panel:** late upload-progress callbacks are ignored unless the model is currently uploading (`CaptureShareModel.updateProgress`), so they can't overwrite `.done`, `.failed` or a cancel.
* **Performance:** pointer moves and drags invalidate only the old / new loupe, selection (with badge room) and hovered-window rects (`CaptureChromeView.invalidateForMove`).
* **Permission row:** Preferences › Screenshots reads the status through `ScreenshotServicing.hasScreenRecordingPermission(prompt:)`.
