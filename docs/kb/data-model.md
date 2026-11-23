# Data model (mirrors upstream Ditto, hardened)

Upstream: single SQLite file, tables `Main`, `Data`, `Types`, `CopyBuffers`, `MainDeletes` (`src/DatabaseUtilities.cpp:693-773`).

## Port schema (`ClipStore`)

```sql
PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
CREATE TABLE Main(
  lID INTEGER PRIMARY KEY AUTOINCREMENT,
  lDate INTEGER NOT NULL,            -- capture time, unix seconds
  mText TEXT NOT NULL DEFAULT '',    -- description / preview (<= DescTextSize chars); group name for groups
  lShortCut INTEGER NOT NULL DEFAULT 0,
  lDontAutoDelete INTEGER NOT NULL DEFAULT 0,
  CRC INTEGER NOT NULL DEFAULT 0,    -- CRC32 over formats (signed storage like upstream)
  bIsGroup INTEGER NOT NULL DEFAULT 0,
  lParentID INTEGER NOT NULL DEFAULT -1,
  QuickPasteText TEXT NOT NULL DEFAULT '',
  clipOrder REAL NOT NULL DEFAULT 0,
  clipGroupOrder REAL NOT NULL DEFAULT 0,
  globalShortCut INTEGER NOT NULL DEFAULT 0,
  lastPasteDate INTEGER NOT NULL DEFAULT 0,
  stickyClipOrder REAL NOT NULL DEFAULT -2147483647,
  stickyClipGroupOrder REAL NOT NULL DEFAULT -2147483647,
  MoveToGroupShortCut INTEGER NOT NULL DEFAULT 0,
  GlobalMoveToGroupShortCut INTEGER NOT NULL DEFAULT 0,
  sourceApp TEXT NOT NULL DEFAULT ''   -- macOS addition: bundle id of source app
);
CREATE TABLE Data(
  lID INTEGER PRIMARY KEY AUTOINCREMENT,
  lParentID INTEGER NOT NULL REFERENCES Main(lID) ON DELETE CASCADE,
  strClipBoardFormat TEXT NOT NULL,   -- UTI, e.g. public.utf8-plain-text, public.rtf, public.html, public.png, public.file-url
  ooData BLOB NOT NULL
);
CREATE TABLE CopyBuffers(lID INTEGER PRIMARY KEY AUTOINCREMENT, lClipID INTEGER, lCopyBuffer INTEGER);
```
Indexes as upstream: `Main_TopLevel(stickyClipOrder DESC, bIsGroup, clipOrder DESC)`,
`Main_InGroup2(lParentID, stickyClipGroupOrder DESC, bIsGroup, clipGroupOrder DESC)`, `Main_CRC(CRC)`,
`Main_ParentId`, `Data_ParentId_Format(lParentID, strClipBoardFormat)`.

Differences from upstream: FK cascade instead of `MainDeletes` tombstone queue; every statement bound; `sourceApp` column.

## Rules carried over
- **Sticky sentinel** `-2147483647` = not sticky. Make top sticky = `max+1`, last sticky = `min-1`.
- **Order**: newest = highest `clipOrder`. New/recopied = `max+1`; move to bottom = `min-1`; move up/down = midpoint.
  Port adds renormalisation when gap < 1e-6 (upstream risk).
- **List sort**: `stickyClipOrder DESC, bIsGroup ASC, clipOrder DESC` (top level, `lParentID = -1`);
  in group use the `...Group...` columns.
- **Dedupe** (`Clip.cpp:815`): when `AllowDuplicates=false` → any row with same CRC at same level gets bumped to top
  (`clipOrder=max+1`), no insert. `AllowDuplicates=true, AllowBackToBackDuplicates=false` → compare with last added only.
  Clips captured into a group are not deduped.
- **Auto-delete protection**: deletable only if `bIsGroup=0 AND lShortCut=0 AND lParentID<=0 AND lDontAutoDelete=0`
  and both sticky columns = sentinel.
- **Max entries** (`CheckForMaxEntries`, default **on** in port, `MaxEntries` 500): delete beyond offset N ordered by `clipOrder DESC`.
- **Expiry** (`CheckForExpiredEntries`, default off, `ExpiredEntries` 5 days): `lastPasteDate < now - N days`.
- **Delete group**: children re-parented to -1 (not deleted).
- **Description**: text truncated to `DescTextSize` (500); non-text → "Copied File(s) - name" or format name.

## Implementation notes
- **Schema version**: `PRAGMA user_version = 1`. Add migrations as `if version < 2 { … }` in `ClipStore.migrate()`. One extra index `Main_ClipOrder(clipOrder DESC)` speeds up retention.
- **Dates** are stored as whole unix seconds (sub-second precision is dropped). On insert `lastPasteDate = lDate` (as upstream), so `wasPasted` is false and expiry counts from capture time until the first paste.
- **Dedupe** looks only at top-level non-group clips (`lParentID = -1`). A bump sets `clipOrder = max+1` only, and the sticky `AddOptions` are applied to the bumped clip too. Back-to-back mode compares with the newest non-group row by `lID`.
- **`replaceTopSticky`** clears the sticky flag on the current top sticky (it does not delete it). The new clip becomes top sticky. Sticky values start at 1 (`max+1` over non-sentinel values, or `0+1` if there are none) and `min-1` for last sticky.
- **Ordering**: `moveUp/moveDown(inGroup: nil)` moves among all non-group clips by `clipOrder` (this matches the default `showAllClipsInMainList = true`). With a group id they use `clipGroupOrder` among that group's children. A sticky clip moves among the stickies (on its sticky column). If a gap falls below 1e-6, the scope is renumbered 1…n and the move is retried. `moveToTop/Bottom` also update `clipGroupOrder` for clips inside a group.
- **History filter**: when `showGroupsInMainList` is on, only top-level groups are listed. Groups sort after clips (`bIsGroup ASC`). `ClipFilter.limit <= 0` means no limit.
- **Search**: full text uses `LEFT JOIN Data ft` on the first `public.utf8-plain-text` row and matches `COALESCE(CAST(ft.ooData AS TEXT), '')`, so `NOT` terms also work on clips with no text. Operators `OR`/`AND`/`NOT` count only in upper case. Case-insensitive search uses `LIKE … ESCAPE '\'`, which folds ASCII only, as upstream. Case-sensitive search uses `GLOB ?` with escaped metacharacters. In regex mode a `(?i)` prefix is added when case-insensitive. A blank query gives `"1"`, and ClipStore skips it.
- **Retention**: when `maxEntries` or `expireDays` is nil or ≤ 0, that rule is off. So a setting value of 0 never wipes history.
- **`deleteNonUsedClips()`** matches upstream `DeleteNonUsedClips`: it deletes every unprotected clip (not a group, no shortcut, not in a group, not never-auto-delete, not sticky), then cleans up orphan `Data` rows and empty clips.
- **`deleteData(clipIDs:types:)`** deletes a clip once it has no formats left. Otherwise it recomputes the CRC. `deleteFormat` and `replaceFormats` also recompute the CRC.
- **`move` / `copyClips`**: moving a group into itself or one of its descendants is silently skipped. Copies are not deduped, and they lose sticky and shortcut values.
- **ImportExport API** (not in the contract): `ImportExport.exportClips(ids:from:to:) -> Int`, `importClips(from:into:) -> ImportSummary`, `importWindowsDitto(from:into:) -> ImportSummary`, `convertWindowsFormats(_:)`, `cfHTMLFragment(_:)`, `textFileName(for: Clip, index:)` and `fileExtension = "dittoclips"`.
  - Export includes the descendants of selected groups and the ancestor groups of exported clips. Shortcuts are cleared. The file is replaced if it exists and is set to 0600.
  - Import uses `addClip`, so top-level duplicates count as `duplicates`. Groups are reused when a group with the same name exists under the same parent. Date, never-auto-delete and quick-paste text are restored afterwards.
  - Source databases are opened `SQLITE_OPEN_READONLY`. Missing Main columns fall back to constant defaults, picked from a fixed whitelist via `PRAGMA table_info`.
- Extra public helpers: `ClipUTI` constants, `ClipKind.classify(types:isGroup:)`, a memberwise `Clip.init` with defaults (`lastPasteDate` defaults to `date`), and `SQLiteError`. The internal wrapper types are named `SQLiteDatabase` / `SQLiteStatement`, so they don't clash with app code.
- **Testing on Command Line Tools**: swift-testing macros need `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`. Use the `--filter` value `"ClipStoreTests|SearchQueryTests|ImportExportTests"`; the shorter `"ClipStore|SearchQuery|ImportExport"` ran nothing in practice.
