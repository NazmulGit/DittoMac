# DittoMac architecture and API contract

DittoMac is an unofficial native macOS port of [Ditto](https://github.com/sabrogden/Ditto) 3.25.113.0 (GPL-3.0).
It is a clean-room rewrite in Swift: Ditto's behaviour, data model and options are ported, not its C++ code.

- Target: macOS 13+, universal binary (arm64 for Apple silicon M1–M5, and x86_64).
- Build: SwiftPM with Command Line Tools (no Xcode project). Tests use swift-testing.
- Swift language mode 5 (tools 5.10). `@MainActor` is used for all UI types.

## Targets and file ownership

```
Sources/DittoCore/          pure logic, no AppKit (Foundation, SQLite3, CryptoKit, CommonCrypto only)
  SQLite.swift              thin sqlite3 wrapper: prepared statements, bind, step, transactions
  Models.swift              Clip, ClipFormat, ClipKind, constants (StickySentinel, UTIs)
  ClipStore.swift           schema, migrations, CRUD, dedupe, ordering, groups, stickies, retention, stats
  SearchQuery.swift         query parser (wildcard/contains/regex, AND/OR/NOT, quotes, /q /f prefixes) → SQL + binds
  TextTransforms.swift      special paste transforms (all Ditto ones)
  CopyRules.swift           declarative on-copy rules (replaces ChaiScript) + regex exclusions
  CRC32.swift               CRC32 (IEEE) for dedupe
  Settings.swift            typed settings keys + defaults (UserDefaults-backed, injectable suite)
  ImportExport.swift        export/import .dittoclips (SQLite), import Windows Ditto.db, text export helpers
  FriendsProtocol.swift     secure LAN sync framing + crypto (PBKDF2 → HKDF → ChaChaPoly), caps, pure/testable
  ThemeData.swift           12 Ditto themes + System as hex strings
  PasteFormat.swift         PasteFormat (original/plainText/richText/markdown/htmlSource) + per-app plain-text matcher
  HTMLToMarkdown.swift      pure-Swift HTML → GitHub Markdown / plain text (bounded, no WebKit); entity decoding
  WebArchive.swift          main HTML of a com.apple.webarchive via PropertyListSerialization (no WebKit)
Sources/DittoMac/
  App/main.swift, App/AppDelegate.swift, App/AppState.swift (wires services)
  Services/ClipboardMonitor.swift   NSPasteboard polling → ClipStore
  Services/PasteService.swift       write clip to pasteboard (with transforms / paste formats), restore focus, ⌘V via CGEvent
  Services/RichFormats.swift        PasteContent conversions per PasteFormat, RTFToMarkdown (AppKit)
  Services/HotKeyCenter.swift       Carbon RegisterEventHotKey; KeyCombo model + recorder helpers
  Services/CopyBuffers.swift        5 copy buffers (global copy/paste hotkeys)
  Services/FriendsService.swift     Network.framework listener/sender using FriendsProtocol
  Services/LoginItem.swift          SMAppService
  UI/StatusItemController.swift     menu-bar icon + menu
  UI/QuickPasteWindow.swift         the popup (NSPanel): search field, clip table, groups sidebar, status line
  UI/ClipTableView.swift            NSTableView rows: n-lines text, thumbnails, colour swatch, symbols, first-ten index
  UI/ClipContextMenu.swift          right-click menu (all actions, Paste As ▸ / Copy As ▸)
  UI/SaveClipAs.swift               Save Clip As… (.rtf/.rtfd, .webarchive, .html, .md, .txt, .png)
  UI/PreviewWindow.swift            description window (text/RTF/HTML/image zoom)
  UI/EditorWindow.swift             built-in clip editor (plain/rich text)
  UI/PropertiesWindow.swift         clip properties
  UI/PreferencesWindow.swift        tabs: General, Quick Paste, Keyboard, Copy Buffers, Types, Friends, Rules, Stats, Advanced
  UI/QRCodeWindow.swift, UI/CompareWindow.swift, UI/DeleteClipDataWindow.swift, UI/GroupPicker.swift
  UI/Theme.swift                    ThemeData → NSColor (built-in or custom theme, accent override)
  UI/AppearanceManager.swift        NSApp.appearance, ClipRowStyle, CustomThemes (JSON files), AppIconCache
  UI/PreferencesAppearance.swift    Appearance tab (themes, editor, rows, font, menu bar, notes)
  UI/QuickPasteLock.swift           lock / unlock / lock-aware delete / sticky-note actions in the popup
  UI/StickyNoteWindow.swift         StickyNoteCenter + floating desktop note windows
  UI/UIProofRenderer.swift          `DittoMac --render-ui-proofs <dir>`: offscreen PNG proofs (dev tool)
  UI/KeyRecorderView.swift          shortcut recorder control
Tests/DittoCoreTests/*.swift
```

## DittoCore public API (contract — implementers must match these signatures)

```swift
public enum Ditto {
    public static let stickySentinel: Double = -2147483647
    public static let topLevelParent: Int64 = -1
}

public struct ClipFormat: Sendable, Equatable {
    public var id: Int64            // 0 when not yet stored
    public var type: String         // UTI / NSPasteboard.PasteboardType rawValue
    public var data: Data
    public init(id: Int64 = 0, type: String, data: Data)
}

public struct Clip: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var date: Date                 // lDate
    public var text: String               // mText description / group name
    public var shortcut: Int              // lShortCut (encoded KeyCombo, 0 = none)
    public var globalShortcut: Bool
    public var dontAutoDelete: Bool
    public var crc: Int32
    public var isGroup: Bool
    public var parentID: Int64            // -1 top level
    public var quickPasteText: String
    public var clipOrder: Double
    public var clipGroupOrder: Double
    public var lastPasteDate: Date
    public var stickyClipOrder: Double
    public var stickyClipGroupOrder: Double
    public var moveToGroupShortcut: Int
    public var globalMoveToGroupShortcut: Bool
    public var sourceApp: String
    public var isSticky: Bool { get }     // either sticky column != sentinel
    public var wasPasted: Bool { get }    // lastPasteDate > date + 1s
}

public struct ClipFilter: Sendable {
    public var parentID: Int64? = nil           // nil = history (top level); value = inside group
    public var showAllClipsInMainList = true    // history includes clips that live in groups
    public var showGroupsInMainList = false
    public var search: SearchQuery? = nil
    public var limit: Int = 500
    public var offset: Int = 0
    public init(...)  // memberwise with defaults
}

public enum AddResult: Sendable, Equatable { case inserted(Int64), duplicateBumped(Int64), rejected }

public final class ClipStore: @unchecked Sendable {   // internally serialised with a lock
    public init(path: String) throws                     // creates dir 0700 / file 0600, WAL, migrations
    public static func inMemory() throws -> ClipStore
    public var path: String { get }

    // capture
    public func addClip(formats: [ClipFormat], description: String, sourceApp: String,
                        parentID: Int64 = -1, options: AddOptions = .init()) throws -> AddResult
    public struct AddOptions: Sendable { public var allowDuplicates = false; public var allowBackToBackDuplicates = false
        public var makeTopSticky = false; public var makeLastSticky = false; public var replaceTopSticky = false; public init() }

    // reading
    public func clips(_ filter: ClipFilter) throws -> [Clip]
    public func count(_ filter: ClipFilter) throws -> Int
    public func clip(id: Int64) throws -> Clip?
    public func formats(clipID: Int64) throws -> [ClipFormat]
    public func formatTypes(clipID: Int64) throws -> [(type: String, size: Int)]
    public func data(clipID: Int64, type: String) throws -> Data?
    public func groups() throws -> [Clip]                 // all groups (for tree), ordered by name
    public func children(ofGroup id: Int64) throws -> [Clip]
    public func clipsWithShortcuts() throws -> [Clip]

    // mutation
    public func update(_ clip: Clip) throws               // writes all Main columns
    public func replaceFormats(clipID: Int64, formats: [ClipFormat], description: String?) throws  // recomputes CRC
    public func deleteFormat(formatID: Int64) throws
    public func delete(ids: [Int64]) throws               // groups: children reparented to -1
    public func createGroup(name: String, parentID: Int64 = -1) throws -> Int64
    public func move(ids: [Int64], toGroup groupID: Int64) throws     // -1 = top level
    public func copyClips(ids: [Int64], toGroup groupID: Int64) throws -> [Int64]
    public func markPasted(id: Int64, moveToTop: Bool) throws
    public func moveToTop(id: Int64) throws; public func moveToBottom(id: Int64) throws
    public func moveUp(id: Int64, inGroup: Int64?) throws; public func moveDown(id: Int64, inGroup: Int64?) throws
    public func makeTopSticky(id: Int64, inGroup: Bool) throws; public func makeLastSticky(id: Int64, inGroup: Bool) throws
    public func removeSticky(id: Int64) throws

    // retention / maintenance
    public func applyRetention(maxEntries: Int?, expireDays: Int?, now: Date = Date()) throws -> Int  // returns deleted count
    public func deleteNonUsedClips() throws -> Int
    public func deleteAll() throws
    public func vacuum() throws
    public func backup(to url: URL) throws                // sqlite3_backup
    public func stats() throws -> StoreStats              // clipCount, groupCount, formatCount, dbBytes
    public func clipsMatching(dataFilter: ClipDataFilter) throws -> [(clip: Clip, bytes: Int)]   // Delete Clip Data window
    public func deleteData(clipIDs: [Int64], types: [String]?) throws // delete specific formats (nil = whole clips)
}
public struct StoreStats: Sendable { public var clips, groups, formats: Int; public var databaseBytes: Int64 }
public struct ClipDataFilter: Sendable { public var titleContains: String?; public var createdFrom, createdTo, usedFrom, usedTo: Date?; public var formatType: String? }

public struct SearchQuery: Sendable, Equatable {
    public enum Mode: String, Sendable, CaseIterable { case wildcard, contains, regex }
    public var raw: String; public var mode: Mode
    public var searchDescription = true, searchFullText = false, searchQuickPaste = false
    public var caseInsensitive = true
    public init(_ raw: String, mode: Mode = .wildcard)
    public func sqlWhere() -> (sql: String, binds: [String])   // uses LIKE ... ESCAPE '\'; regex → REGEXP fn registered by ClipStore (bounded: input capped at 100k chars, pattern compile cached)
}

public enum TextTransform: String, CaseIterable, Sendable {
    case plainText, upperCase, lowerCase, capitalize, sentenceCase, invertCase, trimWhiteSpace, camelCase,
         asciiOnly, removeLineFeeds, addOneLineFeed, addTwoLineFeeds, addCurrentTime, typoglycemia, slugify
    public var title: String { get }
    public func apply(_ s: String, slugSeparator: String = "-", now: Date = Date(), rng: inout some RandomNumberGenerator) -> String
    public func apply(_ s: String) -> String            // convenience (system RNG)
}
public enum MultiPaste { public static func join(_ parts: [String], separator: String, reverse: Bool) -> String }  // "[LF]" → "\n", "[TAB]" → "\t"

public struct CopyRule: Codable, Sendable, Equatable, Identifiable {
    public enum Action: String, Codable, Sendable, CaseIterable { case ignore, makeTopSticky, makeLastSticky, neverAutoDelete, stripToPlainText, replaceRegex, moveToGroup }
    public var id: UUID; public var name: String; public var enabled: Bool
    public var appPattern: String          // ";"-separated wildcard list on bundle id or app name; "" / "*" = any
    public var textRegex: String           // "" = any
    public var action: Action
    public var replacement: String         // for replaceRegex
    public var groupName: String           // for moveToGroup
}
public struct CopyRuleOutcome: Sendable { public var ignore = false; public var text: String?; public var stripToPlain = false
    public var makeTopSticky = false; public var makeLastSticky = false; public var neverAutoDelete = false; public var groupName: String? }
public enum CopyRuleEngine { public static func evaluate(rules: [CopyRule], text: String?, appBundleID: String, appName: String) -> CopyRuleOutcome
    public static func wildcardMatch(_ pattern: String, _ s: String) -> Bool }   // regex input capped (100k chars), invalid regex = no match

public enum CRC32 { public static func checksum(_ data: Data, seed: UInt32 = 0) -> UInt32; public static func clipCRC(_ formats: [ClipFormat]) -> Int32 }

public final class Settings: @unchecked Sendable { public init(defaults: UserDefaults = .standard); public static let shared: Settings
    // typed properties, each with Ditto default. See docs/kb/options-mapping.md. Examples:
    public var maxEntries: Int (500); public var checkForMaxEntries: Bool (true); public var expiredEntries: Int (5); public var checkForExpiredEntries: Bool (false)
    public var allowDuplicates: Bool (false); public var allowBackToBackDuplicates: Bool (false); public var descTextSize: Int (500)
    public var maxClipSizeBytes: Int (0); public var linesPerRow: Int (2); public var popupPosition: PopupPosition (.caret)
    ... (full list in Settings.swift) }

public enum FriendsProtocol { /* see FriendsProtocol.swift header doc */ }
public enum ThemeData { public static let all: [ThemeSpec]; public static func named(_ n: String) -> ThemeSpec }
public struct ThemeSpec: Sendable { public var name: String; public var colors: [String: String] /* key → "#RRGGBB" */; public var isDark: Bool }
```

## Key behaviours (from upstream, see docs/kb/*)
- Capture loop polls every 0.5 s; skips concealed/transient markers, our own writes, excluded apps, rules → ignore, oversize.
- Stored formats per clip: `public.utf8-plain-text`, `public.rtf`, `public.html`, `public.png` (TIFF converted to PNG), `public.file-url` (newline-joined), plus any enabled extra types, plus (when `keepFullFormatting`) the full-formatting set `ClipUTI.fullFormattingTypes` — see docs/kb/rich-formats.md.
- Sort: sticky DESC, groups-first-as-in-upstream (`bIsGroup` ASC means non-groups first — keep upstream SQL), clipOrder DESC.
- Paste: write formats to pasteboard tagged `org.dittomac.internal`, reactivate prior app, after 80 ms post ⌘V.

## Security invariants
1. Every SQL statement uses bound parameters. No string-built SQL with user/peer data.
2. Friends sync is off by default. When on: passphrase ≥ 12 chars in Keychain, AEAD per frame, local KDF params, caps, no file requests, no connect-back.
3. No dynamic code loading, no scripting engine, no shell-outs with user data.
4. URLs opened only via `URLComponents`; templates must be `https://`.
5. DB dir 0700, file 0600. Password-manager clips never stored.
6. Hardened runtime signature.

## App layer notes

### Wiring (AppDelegate.applicationDidFinishLaunching)
1. `enforceSingleInstance()` (willFinishLaunching): if another process with our bundle id runs, activate it, post the
   distributed notification `io.github.dittomac.activateRunningInstance` (the running instance opens Quick Paste) and exit.
2. Activation policy: `.accessory`, or `.regular` when `Settings.showDockIcon` (re-applied on `.dittoSettingsChanged`).
3. `ClipStore(path: ~/Library/Application Support/DittoMac/Ditto.db)` (dir created 0700); failure → critical alert + quit.
4. `AppState(store:settings:)` → `AppState.shared`; `showMessage` → `HUD.shared.show`.
5. Services, in order: `HotKeyCenter()` → `PasteService(state:)` → `ClipboardMonitor(state:)` → `WindowRouter(state:)` →
   `FriendsService(state:)` → `CopyBuffers(state:)` (needs `state.hotkeys`) → `QuickPasteController(state:)` (sets
   `state.showQuickPaste/hideQuickPaste`) → `StatusItemController(state:)` → minimal main menu (App/Edit/Window, so
   ⌘C/⌘V/⌘A work in text fields of an accessory app).
6. `monitor.start()` (0.5 s timer, `.common` mode), `registerHotkeys()`, retention now + every 15 min (background queue),
   first-run Accessibility alert (once; opens `x-apple.systempreferences:…Privacy_Accessibility`), startup HUD.

### Global hotkeys (names = Preferences › Keyboard; re-registered on `.dittoHotkeysChanged`)
| Settings name | HotKeyCenter name | Action |
|---|---|---|
| `activate`, `activate2`, `activate3` | `main.<name>` | `QuickPasteController.activateHotkeyPressed()` (show / hold-to-cycle / hide) |
| `textOnlyPaste` | `main.textOnlyPaste` | current clipboard → plain text → ⌘V |
| `saveClipboard` | `main.saveClipboard` | `monitor.saveCurrentClipboard()` |
| `copyAndSave` | `main.copyAndSave` | ⌘C to front app (+ force save when disconnected) |
| `lastTen1`…`lastTen10` | `main.lastTen<n>` | paste Nth history clip into front app |
| clip `shortcut` + `globalShortcut` | `clip.<id>` | paste that clip into front app |
| group `shortcut` + `globalShortcut` | `group.<id>` | once: open popup in group · twice < 0.5 s: ⌘C → next clip filed into group |
| group `moveToGroupShortcut` + global | `mtg.<id>` | ⌘C → next clip filed into group |
| `buffer<i>.copy/paste/cut` | (CopyBuffers) | copy buffers |
Non-global clip/group shortcuts work inside the popup (paste clip / open group; move-to-group shortcut moves selection).

### Capture (ClipboardMonitor)
changeCount poll → skip if disconnected / ≤ ignored count / concealed-transient markers / `org.dittomac.internal` →
wait `saveClipDelayMS` (≤ 2 s, re-checks changeCount) → include/exclude app wildcards (bundle id or name) → read
text/RTF/HTML/PNG (TIFF→PNG)/file URLs + full-formatting set (web archive, RTFD, JPEG/GIF/HEIC, PDF, URL; 64 MiB
per format) + enabled extra types (or all non-legacy types) → derive plain text for rich-only clips → max size (drops
rich extras first) → Copy Rules
(ignore, replace text — drops RTF/HTML, strip to plain, stickies, never-auto-delete, move to group by name — created
if missing) → description → `captureNextClip` group → `store.addClip` → sound, `recordCopy`, friends auto-send, `clipsChanged`.

### Paste (PasteService)
A paste without transform uses `defaultPasteFormat()` (Settings.defaultPasteFormat, or plain text when the target
matches Settings.plainTextApps); `paste(clipIDs:format:…)` / `copyToPasteboard(clipIDs:format:)` take an explicit
PasteFormat (conversions in RichFormats.swift; `.original` = all stored formats).
Formats are written as NSPasteboardItems (one per extra file URL) tagged `org.dittomac.internal`; the resulting
changeCount goes to `monitor.ignoreChangeCount`. Any transform → text only (Remove Line Feeds also keeps a transformed
RTF). Multi-select → `MultiPaste.join(separator, reverse)` (+ saved as a new clip if `saveMultiPaste`; file-only
selections merge file URLs). Send paste = activate `targetApp`, after 0.12 s post ⌘<key> via CGEvent at
`.cghidEventTap`; the key code is looked up for the current keyboard layout with UCKeyTranslate (⌘ held), falling back
to `kVK_ANSI_V`. Not trusted → clip stays on the clipboard + HUD "press ⌘V". `markPasted(moveToTop: moveToTop &&
updateTimeOnPaste)`, `recordPaste`.

### Quick Paste popup (QuickPasteWindow / Actions / Keyboard, ClipTableView, ClipContextMenu)
`QuickPastePanel` (titled utility NSPanel, key-capable; level `.floating` only when always-on-top) routes every keyDown
through `QuickPasteController.handleKeyDown` first. Target app is recorded before activation; caret position comes
from AX (focused element → selected range → bounds-for-range, Y flipped), else mouse, else saved top-left; clamped to
the screen's visibleFrame; size/position saved on hide/resize. Hidden when DittoMac resigns active unless always-on-top.
List: view-based NSTableView, pages of 500 loaded on scroll, custom-drawn rows (theme colours, n lines, thumbnails via
ImageIO off-main + NSCache, colour swatches, symbols `* s G !`, first-ten index, pasted dot, sticky pin, search
highlight). Groups sidebar = NSOutlineView ("History" + nested groups), visibility stored in defaults key
`quickPasteShowGroupsSidebar`. Status line: `pos / total · Target · Group · Filtered [Disconnected] [Always on top]`;
gear button = clip menu, ellipsis button = "More" (window) menu.

### Keyboard map (popup)
| Key | Action |
|---|---|
| Return / Enter, double-click | paste selection in the default paste format (group → open it). In search with an un-applied query: run search |
| ⇧Return | paste as plain text |
| ⌥⇧Return | paste as Markdown |
| ⌘⇧S | Save Clip As… |
| ⌥Return, ⌘I | properties |
| ⌘1…⌘9, ⌘0 | paste first-ten position (labels follow `firstTenHotKeysStart`) |
| ⌥⌘1…⌥⌘0 | plain-text paste of position |
| ⌘C | copy selection to clipboard (in search with selected text: normal copy) |
| ⌫ | in a group with empty search: back to parent; otherwise delete |
| ⌘⌫, ⌦ | delete (confirm if `promptWhenDeletingClips`; groups: "Delete Group?") |
| Esc | clear search → else hide (restore focus). ⇧Esc force-hide. ⌘W hide |
| ⌘F | focus search; typing a printable character in the list jumps to search seeded with it |
| ↑ ↓ PgUp PgDn (in search) | move list selection (⇧ extends) |
| ⌥⌘F | cycle search mode wildcard → contains → regex (also the mode pop-up and the search-field menu) |
| ⌘G | toggle groups sidebar |
| ⌘N / ⌘E | new clip / edit clip |
| F3, Space (list) | preview |
| ⌘⇧N, F7 | new group from selection |
| ⌃⌘N | new group |
| ⌥⌘N | new sticky note (editor in note mode) |
| ⌘L | lock selection; when every selected clip is locked: remove lock |
| ⇧⌘L | lock notes now (vault) |
| ⌘↑ | back to parent group |
| Home (list), ⌘Home | History (top level) |
| ⌘R, F5 | refresh |
| ⌃Space | toggle always on top |
| ⌘A | select all (in search: select text) |
| ⌘, | preferences |
| activate hotkey again while held | move selection down; releasing all modifiers pastes (`moveSelectionOnOpenHotkey`) |
| activate hotkey again after release | hide (`hideOnHotKeyIfAlreadyShown`) |
