# Cloud sync and backup (v1.2)

Request: "able to add Google Drive and other to save data and sync". Decision (`docs/PLAN.md`): **folder-based, end-to-end encrypted,
no OAuth, no provider API, no tokens.** DittoMac writes encrypted files into a folder that the user's cloud app already syncs.

| Code | Role |
|---|---|
| `Sources/DittoCore/SyncEngine.swift` | Pure logic: snapshot model, `.dmsync` codec, validation, hash index, tombstones, merge, folder runs, backups |
| `Sources/DittoCore/Settings+Sync.swift` | `sync*` settings, `Settings.syncKeys` |
| `Sources/DittoMac/Services/Sync/CloudFolders.swift` | Detects Google Drive / iCloud Drive / Dropbox / OneDrive / Box / pCloud folders; "Choose folder…" panel |
| `Sources/DittoMac/Services/Sync/SyncService.swift` | `SyncServicing` implementation: Keychain passphrase, timers, status, background queue |
| `Sources/DittoMac/UI/PreferencesSync.swift` | Sync tab |
| `Tests/DittoCoreTests/SyncTests.swift` | 22 tests |

## Providers
No provider is special. `CloudFolders.detect()` lists existing folders (nothing is created): `~/Library/CloudStorage/GoogleDrive-*/My Drive` (and the
account root), `Dropbox*`, `OneDrive*`, `Box*`, `pCloud*` (also iCloud/Proton/Nextcloud/Mega-style names), `~/Library/Mobile Documents/com~apple~CloudDocs`
(iCloud Drive), `~/Dropbox`, `~/Google Drive`, `~/OneDrive`, `~/Box`. "Choose folder…" accepts any folder. For Google Drive the user installs
"Google Drive for desktop" and picks "My Drive". DittoMac creates `<folder>/DittoMac Sync` (0700); files are 0600 locally.
The cloud app does the upload; DittoMac makes no network connection for sync.

## `.dmsync` format
```
"DMSYNC1" | version u8 (=1) | PBKDF2 iterations u32 BE | salt[16] | nonce[12] | AES-256-GCM ciphertext | tag[16]
```
* AAD = the 40-byte header. Plaintext = zlib (Apple Compression, raw deflate) of the JSON `SyncSnapshot`.
* Key = PBKDF2-HMAC-SHA256(NFC passphrase, salt, iterations); default **600 000** iterations. Derived keys are cached per (passphrase, salt, iterations).
  A device reuses one random salt for its pushes in a session (fresh random nonce per file).
* Read side accepts **100 000 – 2 000 000** iterations only and checks this **before** deriving a key. Ciphertext cap 256 MiB, decompressed cap 256 MiB (streaming, so a bomb stops at the cap).
* The sync passphrase (≥ 12 characters) lives in the Keychain (service `io.github.dittomac`, account `sync.passphrase`), never in UserDefaults, never logged, never in status or error text.
  The same passphrase must be used on every Mac.

JSON: `deviceID`, `deviceName`, `createdAt`, `groups [{uid, name, parentUID}]`, `clips [{contentHash, date, lastPasteDate, description, quickPasteText,
neverAutoDelete, stickyTop, stickyLast, groupUID?, formats [{type, base64}]}]`.

`contentHash` = SHA-256 over the sorted per-format digests `SHA256(type | 0x00 | data)`, so it ignores format order and local ids. It is computed over
**all** stored formats even when some are left out of the snapshot (see "Imported clips keep their hash").

### Never in a snapshot
Locked clips (`isLocked`, hard exclusion, re-checked atomically with `ClipStore.unlockedFormats` when the snapshot is built), group hot keys, clip shortcuts,
copy-buffer clips (`sourceApp == "copybuffer"`), file-reference formats (`public.file-url`, `NSFilenamesPboardType`, promised-file types; never imported either:
a path on one Mac means nothing on another), the Friends passphrase, the vault key or password. Friend-received clips are included.

### Options
`includeImages` (image types and PDF), `includeRichFormats` (RTF, RTFD, HTML, web archives), `maxTotalMB` (default 150, UI 10–150; newest first, clips that
don't fit are skipped), per-format cap 16 MiB, `maxClips` 5000.

## Sync semantics
* Each Mac writes **only** `device-<DEVICE-UUID>.dmsync` (temp file `0600` in the same folder, `fsync`, `rename`). Nobody ever writes another Mac's file, so cloud conflict copies cannot occur.
* It reads every other `device-*.dmsync` (file name must match the UUID pattern; symlinks and non-regular files are ignored) and **adds** clips whose content hash it does not have.
* **Index** (`sync-index.json`, in the app-support folder): `hash → local clip id` for local and imported clips; a content-hash cache keyed by (id, CRC, date)
  so unchanged clips are never re-hashed; for imported clips the hash declared by the sender and the CRC at import time; the digest of the last push.
* **Imported clips keep their hash.** If a snapshot was built without images, the receiver's stored clip has fewer formats than the sender's. The receiver records the
  *declared* hash for that local id and uses it when it pushes, so the sender doesn't see the clip as new content. Editing the clip (CRC changes) gives it a fresh hash.
* **Merge is additive and idempotent.** Merging the same snapshot twice imports nothing. Date, last-paste date, never-auto-delete, quick-paste text and sticky
  state are kept. Groups are matched by name under the same parent path and created only when an imported clip needs them. Imported clips are slotted into the
  list by date (midpoint ordering), not simply put on top.
* **Tombstones** (`sync-tombstones.json`): when an indexed clip has disappeared locally (the user deleted it, or retention did), its hash is recorded with the time and
  is not imported again. Tombstones expire after 90 days. If the user copies the same content again, the tombstone is dropped. "Restore / merge from file" ignores tombstones on purpose.
* **Deletions are not propagated** (v1.2): a clip deleted on Mac A stays in Mac B's snapshot and on Mac B.
* `maxNewClips` = the history limit (`maxEntries`) caps how many clips one run imports, newest first, so retention does not delete what was just imported.
* **Cadence:** on launch and whenever sync settings change; 60 s after local clip changes (debounced `.dittoClipsChanged`); every N minutes (default 5, 1–60);
  every 30 s a stat-only check of the other files, pulling when one changed; `syncNow()`. The push is skipped when a digest of the would-be snapshot equals the
  last pushed one and the file exists (less cloud churn). One run at a time; extra triggers are coalesced.
* All hashing, compression, PBKDF2, IO and import work runs on a private serial queue. `.dittoClipsChanged` is posted on the main thread after an import.
* **Backups** (off by default): `backup-<yyyy-MM-dd>-<device name>.dmsync` in the same folder, at most one per day, the last N (default 7, 1–30) kept for this Mac. Same
  encryption and exclusions. **Restore / merge** takes any `.dmsync` file (backup or another Mac's), asks for a passphrase when the saved one fails (used once, not stored)
  and merges additively.

## Validation of hostile snapshots
`SyncValidator.sanitize` runs on every file and on every `merge`: device id must be a UUID; ≤ 20 000 clips, ≤ 5 000 groups (else rejected); ≤ 32 formats per clip; format type
`[A-Za-z0-9.+_-]` 1–128 chars; format data 1 byte – 16 MiB; hash = 64 lowercase hex and unique; text fields stripped of control characters and truncated (100 000 chars;
names 256; device name 64); group uids restricted and unique, parent cycles and over-deep chains broken, unknown group references dropped; dates clamped to 1990…now+2 days
(NaN/∞ and implausible values replaced). Invalid clips are dropped, not fatal. Nothing from a snapshot is used as a path, URL or SQL text (all values are bound by `ClipStore`).
A 1000-input fuzz test (random bytes, valid header + random body, truncations, bit flips) must reject everything without crashing.

## Threat model
| Threat | Handling |
|---|---|
| Cloud provider or anyone with access to the folder reads clips | AES-256-GCM with a PBKDF2 key; provider sees only ciphertext, file sizes and modification times |
| Passphrase guessing (offline) against a stolen file | PBKDF2 600k; ≥ 12 characters enforced; strength hint. A weak passphrase is still weak. |
| Tampered or replaced file | GCM authentication over header + ciphertext; failure = "wrong passphrase or damaged" and the file is skipped |
| Malicious file from someone holding the passphrase, or a damaged file | Validation above; size caps; no code, paths or URLs taken from it |
| Resource exhaustion (iteration count, decompression bomb, huge counts) | Iteration clamp before KDF; streaming decompression cap; count and size caps |
| Replay of an old snapshot | Can only *add* clips the user may have deleted (tombstones cover 90 days) |
| Other Mac with the passphrase | Trusted: it can add clips to your history (never delete). |

Honest limits: anyone who has the passphrase and the folder can read all synced clips; the passphrase can't be recovered; clipboard history may contain secrets, so choose what to sync
(`Images`, `Rich`) and lock sensitive notes (never synced). Modification times and sizes leak activity patterns. There is no forward secrecy and no per-file key rotation.

## Limitations (v1.2)
* No deletion sync; no edit sync (an edited clip is new content and arrives as a new clip on other Macs).
* The snapshot is whole-history (newest first within the cap), not incremental. Large histories mean large files; keep the max size modest on slow links.
* File-URL clips, shortcuts, hot keys, copy buffers and locked clips are not synced.
* iCloud Drive "Optimize Mac Storage" may evict `device-*.dmsync` to a placeholder; such files are skipped until downloaded. Google Drive "stream files" mode downloads on demand; a half-downloaded file fails authentication and is retried after 5 minutes or when it changes.
* The engine trusts the local clock for dates and tombstone expiry.
* Locking a note does **not** remove plaintext copies that were already synced or backed up (`device-*.dmsync`, `.dmsync` backups) before it was locked; they stay readable with the sync passphrase until deleted from the cloud folder. Lock sensitive notes *before* the first sync, or delete the old files.
* Deletions are not synced (a clip deleted here stays on other Macs and is not re-added here).
* Synced sticky notes arrive on other Macs as ordinary clips: note colour, desktop position / open state and floating state are per-Mac settings and are not synced.
* Passphrase change: set the new passphrase on every Mac; files written with the old one show as "can't decrypt" until that Mac rewrites its file.

## Integration notes
* `AppDelegate` already calls `state.sync?.applySettings()` on launch and on `.dittoSettingsChanged`; `applySettings` does nothing unless a sync setting actually changed.
  What a change means is decided by `SyncConfigSnapshot.change(from:)` (DittoCore/SyncConfigChange.swift): enabling/disabling, folder, passphrase presence, image/rich/backup toggles restart sync (timers + forced full sync);
  the interval only recreates the push timer; the device name, size limit and backup count are read by the next scheduled run, so they never force a sync. The device-name field in the Sync tab commits on Return, after ~1 s of quiet, or when the tab closes (`CommitTextField`).
* `hasPassphrase` is a cached presence flag (`Keychain.has(account:)`, refreshed by `Keychain.set` / `delete`); SwiftUI renders never query the Keychain. "Sync Now" in the status menu is disabled (with the reason in its title) unless `SyncServicing.isReady`.
* `Settings.resetToDefaults()` does not know `Settings.syncKeys`; if "Reset settings" should reset sync, also remove those keys (but keep `syncDeviceID`).
* Concrete extras beyond `SyncServicing` (used by the tab): `SyncService.hasPassphrase`, `setPassphrase(_:)`, `removePassphrase()`, `devices`, `lastMessage`, `restore(from:passphrase:completion:)`,
  and `Notification.Name.dittoSyncStatusChanged`.
