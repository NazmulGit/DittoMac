# Sticky notes and desktop notes (v1.2)

User request: "sticky note as lock system so that mistakenly it doesn't get deleted; lock with the Mac password or a
new password". A **sticky note** is an ordinary clip — normally top-sticky — created by **New Sticky Note**, with
source app `io.github.dittomac.note` (`StickyNoteMarker.sourceApp`). It can be locked like any clip (vault, see
`vault.md`), which encrypts it and protects it from every delete path.

## Creating
⌥⌘N (popup, app menu), context menu, More menu, status menu, Preferences › Appearance → `StickyNoteCenter.newNote`
→ `EditorWindowController(noteMode: true)`:
- Title (optional; stored as the description, kept on later edits), rich or plain text.
- **Pin to top** (default on) → `AddOptions.makeTopSticky`. Duplicates are allowed for notes.
- **Lock this note** → `vault.lock` after the first save (first use runs vault setup).
- **Show on desktop** (default on) and colour → `Settings.setNoteColor`.
In the list a note shows a note icon in its colour and a bold first line; locked notes behave as described in vault.md.

## Desktop note window (`UI/StickyNoteWindow.swift`)
- "Show as Desktop Note" (context menu) or Show on desktop → `WindowRouting.showStickyNote(clipID:)` →
  `StickyNoteCenter.show`. One window per clip.
- Titled, transparent title bar, resizable (min 180×140), movable by background; close button; bar buttons: colour
  menu, pin (float above other windows — `stickyNoteNotFloating` lists notes that don't), lock.
- Colours `NoteColor` yellow / green / pink / blue / purple / grey, light and dark variants (follows the effective
  appearance), stored per clip in `stickyNoteColors`.
- Plain-text editing; autosave 0.6 s after the last keystroke via `store.replaceFormats` (plain text + the clip's
  non-text formats; stale RTF/HTML copies dropped). Locked notes are re-encrypted by the store; each edit calls
  `VaultService.noteActivity()` so the vault doesn't auto-lock while typing.
- If the vault locks with unsaved edits, `replaceFormats` throws `ClipStoreError.locked`; the text is kept in memory
  (`pendingText`) and written after the next unlock. The window then shows the locked view and clears its text view.
- Frame per clip in `stickyNoteFrames` (`NSStringFromRect`; ignored when off-screen or absurd).
- Lock button: unlocked note → lock it; locked and visible → Lock Notes Now / Remove Lock…; locked and hidden → unlock.
- While the clip is locked and the vault is locked: "🔒 Locked note — Unlock…" view; the note's text is never put in
  the window (title "Locked note").
- Clip deleted → window closes and its stored colour / frame / open state are forgotten.

## Restore at launch
Open note ids are saved in `stickyNoteOpenIDs` (≤ 50) whenever a note opens or the user closes one; quitting leaves
them listed. With `restoreDesktopNotes` (default on) `AppDelegate` calls `StickyNoteCenter.restore` after the
services start. Locked notes reopen in their locked view.
