# Appearance and customization (v1.2)

Preferences › Appearance (`UI/PreferencesAppearance.swift`). Every change posts `.dittoSettingsChanged`; the popup
(`QuickPasteController.applySettings` + reload), the status item and `AppDelegate` (`AppearanceManager.apply`)
apply it immediately — no restart.

## Files
| File | Role |
|---|---|
| `Sources/DittoCore/Appearance.swift` | Pure logic: `HexColor` helpers, `AppearanceMode`, `AccentPalette`, `RowDensity` metrics, `FirstTenStyle`, `PopupMaterial`, `RelativeTime`, `NoteColor`, `MenuBarIcon`, `ThemeFile`, `LockPlan` |
| `Sources/DittoCore/Settings+Appearance.swift` | Keys (`Settings.appearanceKeys`), note state, `resetAppearance()` |
| `Sources/DittoMac/UI/AppearanceManager.swift` | `NSApp.appearance`, `ClipRowStyle`, `CustomThemes`, `AppIconCache` |
| `Sources/DittoMac/UI/Theme.swift` | `AppTheme.current`: built-in → custom → System; accent overrides the selection colour |
| `Sources/DittoMac/UI/ClipTableView.swift` | Row drawing (density, rounded inset selection, dividers, badges, timestamps, icons, lock / note states) |
| `Tests/DittoCoreTests/AppearanceTests.swift` | 13 tests |

## Settings (UserDefaults keys)
`appearanceMode` (system/light/dark) · `accentColorHex` ("" = theme) · `rowDensity` (compact/comfortable/spacious,
default comfortable) · `rowCornerRadius` (0–14, default 7; 0 = classic edge-to-edge selection) ·
`showRelativeTimestamps` (on) · `showSourceAppIcon` (off) · `showFormatBadges` (on) · `showRowDividers` (on; with the
System theme rows then use one flat colour instead of alternating) · `popupMaterial` (opaque/translucent) ·
`firstTenStyle` (plain/badge/keycap, default badge) · `menuBarIconSymbol` (validated against `MenuBarIcon.symbols`) ·
`menuBarDimWhenDisconnected` (on) · `menuBarShowRecentCount` (off; badge = `copyCountTotal − menuBarCountBaseline`,
baseline reset when Quick Paste opens) · `restoreDesktopNotes` (on). Theme, font and popup size keep their v1.0 keys
(`themeName`, `fontName`, `fontSize`, `popupWidth`, `popupHeight`); the theme / font controls moved from General to
Appearance.

## Row metrics
`RowDensity.metrics`: vertical padding 2/5/9, horizontal padding 6/9/11, selection inset 3×1 / 5×1.5 / 6×2, accessory
gap 5/7/9, minimum height 20/26/34 pt. Row height = `lineHeight × lines + 2 × (vPad + insetY)`, rounded up.

## Custom themes
- JSON: `{"format":"dittomac-theme","version":1,"name":"…","colors":{"MainWindowBG":"#RRGGBB",…}}`.
- `ThemeFile.parse`: ≤ 64 KB, must be a JSON object with `colors`; unknown `format` or newer `version` rejected; only the
  28 upstream keys accepted; values must be `#RGB/#RRGGBB/#RRGGBBAA` (normalised to `#RRGGBB`, alpha dropped);
  ≤ 128 entries; at least one valid colour. Names: control characters, path separators and leading dots removed,
  whitespace collapsed, ≤ 40 characters, never empty. File names: ASCII slug + `.json`. A name equal to a built-in
  gets " (Custom)".
- Missing keys are completed from the 12 editor colours (`ThemeFile.completed`), so partial themes still render.
- Stored in `~/Library/Application Support/DittoMac/Themes` (dir 0700, files 0600); every load re-validates; at most
  200 files read. Theme JSON is data only — nothing is executed or fetched.
- Theme editor colours: window, row, alternate row, row text, alternate text, selection, selected text, search
  highlight, pasted dot, status text, groups sidebar, groups text.

## Popup polish
Rounded inset selection (radius setting), hairline dividers, first-ten badges/keycaps, right-aligned relative time,
rounded thumbnails, subtle format symbols, bottom bar with separator, lock button, gear and More. Translucent material
puts an `NSVisualEffectView` (`.popover`, behind-window) under the content and stops drawing row backgrounds.
Fixed a launch bug: the async split position no longer un-hides a groups sidebar the user turned off.

## Offscreen proofs
`DittoMac --render-ui-proofs <dir>` (`UI/UIProofRenderer.swift`) renders the popup (light, dark, unlocked, Nord),
desktop notes and the Appearance tab with synthetic data in an in-memory store and a temporary defaults suite, using
`cacheDisplay` on views that are never ordered front. `docs/assets/ui-v12.png` is its composite.
