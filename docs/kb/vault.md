# Vault: locked clips and sticky notes

User request: "Add sticky note as lock system so that mistakenly don't get deleted. Can be locked down with a
password: the PC (Mac) password or a new password."

A **locked clip** (a locked sticky note is just a sticky clip that is also locked) is:

1. **Protected from deletion.** No ordinary delete path removes it (see the table below).
2. **Encrypted at rest.** Its formats, description and quick-paste text are AES-256-GCM ciphertext in the database.
3. **Hidden until unlocked.** While the vault is locked it reads as `"Locked note"` with no formats.

## Files

| File | Role |
|---|---|
| `Sources/DittoCore/Vault.swift` | Crypto primitives: data key, AES-GCM seal/open, PBKDF2, verifier, key wrapping, password policy |
| `Sources/DittoCore/ClipStore.swift` | Schema v2, `vaultKey`, lock/removeLock, transparent decryption, delete protection |
| `Sources/DittoCore/ImportExport.swift` | Export skips locked clips. Import skips locked rows and encrypted blobs |
| `Sources/DittoCore/Settings+Vault.swift` | `vaultMethod`, `vaultConfigured`, `vaultAutoLockMinutes`, `vaultLockOnSleep` (not secret) |
| `Sources/DittoMac/Services/VaultService.swift` | `VaultServicing`: Keychain, LocalAuthentication, password unlock, back-off, auto-lock, reset |
| `Sources/DittoMac/UI/VaultPrompts.swift` | NSAlert sheets: choose method, new password (twice, strength hint), password entry, reset |
| `Sources/DittoMac/UI/PreferencesSecurity.swift` | Security tab |
| `Tests/DittoCoreTests/VaultTests.swift` | 18 tests (crypto, store, every delete path, migration, export/import, concurrency) |

## Keys and methods

- **Data key (DK).** 32 random bytes, created once at setup. Every locked blob is sealed under it. Changing the
  method or the password only re-wraps the DK; nothing is re-encrypted.
- **Method `system`** (the default, "Mac password / Touch ID"):
  - The DK is a generic-password item in the login Keychain (service `io.github.dittomac.vault`, account
    `dataKey`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronizable).
  - Unlocking runs `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`, which shows Touch ID or the Mac login
    password in the macOS prompt. DittoMac never sees the password.
  - DittoMac is ad-hoc signed and so can't use data-protection-keychain access control (`SecAccessControl`
    with `.userPresence`). The prompt is therefore an **app-level gate**. The encryption protects the data at rest.
- **Method `password`** (a separate DittoMac password):
  - Only a `Vault.WrappedKey` is stored, as JSON in the Keychain under account `wrappedKey`. It holds:
    - `salt`: 16 random bytes
    - `iterations`: 600 000 by default, clamped to 100 000…2 000 000 on every use
    - `wrapped`: AES-GCM(KEK, DK) with AAD `"DittoMac vault wrap v1"`
    - `verifier`: HMAC-SHA256(KEK, `"DittoMac vault verifier v1"`)
  - KEK = PBKDF2-HMAC-SHA256(NFC(password), salt, iterations). The plaintext DK is never stored, so locked notes
    can't be decrypted without the password.
  - Passwords must have at least 8 characters, and the setup sheet shows a strength hint.
  - A forgotten password can't be recovered. The only way out is **Reset Vault**.
- **Wrong-password back-off.** The first 3 tries are free. After that the waits are 1 s, 2 s, 4 s … up to 30 s.
  The counter is kept in memory only. Offline guessing is limited by PBKDF2, not by this back-off.
- **Session.** On unlock the DK is placed in `ClipStore.vaultKey`, in memory only. It is cleared:
  - after `vaultAutoLockMinutes` of vault inactivity (default 5; 0 means never until quit). Activity means
    unlocking, locking or removing locks, or `noteActivity()`.
  - on `NSWorkspace.willSleepNotification`, on `sessionDidResignActive` (fast user switching), and on the
    distributed notification `com.apple.screenIsLocked`, when "Lock on sleep" is on.
  - on quit, and by `lockNow()`.
  Each of these posts `.dittoVaultChanged` and `.dittoClipsChanged`.
- **Changing the method or password** always asks again (Touch ID / Mac password, or the current DittoMac password), even
  while unlocked.
- **When the vault locks**, open editors of locked notes close (or hide unsaved text until the next unlock), Properties /
  Compare / QR windows showing locked notes close, and drag-out temp files of locked notes are deleted
  (`ClipDragWriter.purgeLockedStaging`; the whole staging area is also removed at launch and quit).
- **Locking needs no prompt with `system`.** Locking reveals nothing, so the DK is read from the Keychain and used
  through `store.lock(ids:key:)` while the session stays locked. With `password` there is no stored DK, so locking
  asks for the password when the vault is locked.
- **Settings recovery.** If `vaultConfigured` is false but vault Keychain items or locked rows exist, VaultService
  marks the vault as set up again. Otherwise a new key would be created and the old notes would become unreadable.
  `Settings.resetToDefaults()` doesn't touch the vault keys.

## Database (schema v2, `PRAGMA user_version = 2`)

The migration runs on a v1 database, and on a fresh database right after the v1 DDL. Each `ALTER` runs only when
its column is missing.

```sql
ALTER TABLE Main ADD COLUMN isLocked INTEGER NOT NULL DEFAULT 0;
ALTER TABLE Main ADD COLUMN lockedText BLOB;         -- AES-GCM(DK, JSON {description, quickPasteText}), AAD "text|<id>"
ALTER TABLE Data ADD COLUMN encrypted INTEGER NOT NULL DEFAULT 0;   -- ooData = AES-GCM(DK, bytes), AAD "clip|<id>|<type>"
```

- **`lock(ids:)`** works on clips that are not groups and not already locked. For each one it:
  - seals every Data blob, with AAD that binds the blob to its clip id and type, so blobs can't be swapped between rows
  - seals the description and quick-paste text into `lockedText`
  - sets `mText = "Locked note"` and `QuickPasteText = ''`
  - sets `CRC` to a random Int32, so the dedupe and CRC checks can't confirm the content
  - sets `isLocked = 1`
- **`removeLock(ids:)`** reverses this exactly and recomputes the CRC. If any blob fails to authenticate it throws
  `decryptionFailed` and the transaction rolls back.
- **Stale plaintext.** `PRAGMA secure_delete = ON` and a `wal_checkpoint(TRUNCATE)` after locking stop the replaced
  plaintext from lingering in free pages or the WAL. A test checks the raw file bytes.
- **Reads without `vaultKey`:**
  - `clip`/`clips` return the placeholder.
  - `formats`, `formatTypes` and `data` return nothing for encrypted rows.
- **Reads with `vaultKey`:** the same calls decrypt transparently. `formatTypes` reports plaintext sizes.
- **Writes to a locked clip:**
  - `update(_:)` never writes plaintext to `mText`, and never changes `isLocked`. With the key set it re-encrypts
    the new text. Without the key it ignores text changes. A clip that still holds the placeholder text (read while
    locked) keeps the stored text.
  - `replaceFormats` encrypts the new formats. Without the key it throws `ClipStoreError.locked`.
- **Search:** full-text search joins only rows with `encrypted = 0`. Description and quick-paste search see only
  the placeholder, so locked content never matches. A side effect is that, while unlocked, a locked note's real
  description can't be found by search.
- **Not secret:** order, sticky flags, group membership, "never auto-delete", dates, the source app and shortcuts
  stay in plaintext and keep working. A locked clip can be moved between groups or made sticky.

### Delete protection

| Path | Behaviour with locked clips |
|---|---|
| `delete(ids:)` | skips locked ids and returns the count actually deleted |
| deleting a group | locked children are re-parented to top level, as for every child |
| `applyRetention` (max entries, expiry) | `deletableWhere` has `isLocked = 0`. Locked clips don't count toward the max |
| `deleteNonUsedClips` | `isLocked = 0` in both deletes |
| `deleteAll()` | keeps locked clips. Their groups are deleted, so they move to top level |
| `deleteData(clipIDs:types:)` | skips locked ids, for whole clips and for single formats |
| `clipsMatching` (Delete Clip Data window) | never lists locked clips |
| `deleteFormat` | no-op on a locked clip while the vault is locked |
| `vacuum`, `backup` | don't delete rows. A backup contains ciphertext only |
| `copyClips` | skips locked clips, so no copy is made outside the lock |
| `deleteLocked(ids:)` | the deliberate path: needs `vaultKey`, otherwise throws `ClipStoreError.locked` |
| `purgeLockedClips()` | used only by **Reset Vault**, after a typed `DELETE` confirmation |

## Threat model

**Protected:**

- **Accidental deletion** by any UI or maintenance path, including history limits and cleanup.
- **The database file, its WAL, DittoMac backups, Time Machine copies made after locking, `.dittoclips` exports
  and sync folders.** Locked content is ciphertext and is never exported or synced. With the `system` method the
  key stays in the login Keychain on this Mac (`ThisDeviceOnly`).
- **Password method:** someone who has the database **and** the Keychain item still needs the password. Guessing
  costs PBKDF2 at 600 000 rounds per try.
- **Tampering:** AES-GCM with row-bound AAD detects modified, swapped or truncated blobs. Tampered rows read as
  missing; they never return wrong plaintext.
- **Shoulder-surfing and casual access** to an unlocked Mac while the vault is locked: the notes show as "Locked note".

**Not protected (stated honestly in the Security tab):**

- **System method:** someone logged in as you who can unlock your login Keychain, or malware running as you, can
  read the key and decrypt. The Touch ID / password prompt is an app-level gate, not a cryptographic one.
- **An unlocked session:** while unlocked, the key and the decrypted notes are in process memory, and anything
  pasted lands on the general pasteboard.
- **Old copies:** plaintext copies made before the clip was locked, such as older backups, Time Machine snapshots,
  earlier exports, or SSD blocks remapped by wear levelling.
- **Swift strings:** passwords pass through Swift `String`s, which can't be reliably zeroed. Fields are cleared
  after reading, and nothing is logged.
- **Metadata:** dates, order, group, the source app bundle id and format sizes (ciphertext length) stay visible.

## API for the UI agent

Contract (`VaultServicing`, via `state.vault`):

- `isSetUp`, `method`, `isUnlocked`, `autoLockMinutes`
- `requestUnlock(reason:completion:)`, `lockNow()`
- `lock(clipIDs:completion:)`: the first call runs setup.
- `removeLock(clipIDs:completion:)`, `configure(method:newPassword:completion:)`

Extras on `VaultService` (use `state.vault as? VaultService`):

- `var lockedCount: Int`, `var autoLockDate: Date?`, `var statusText: String`
- `func noteActivity()`: call when a locked note is viewed, pasted or edited.
- `func deleteLockedClips(clipIDs:confirm:completion:)`: authenticates, confirms, then calls `store.deleteLocked`.
- `func resetVault(completion:)`
- `Notification.Name.dittoVaultChanged`

Store (DittoCore):

- `ClipStore.lockedPlaceholder`, `vaultKey`
- `lock(ids:)`, `lock(ids:key:)`, `removeLock(ids:)`
- `lockedCount()`, `lockedIDs()`, `deleteLocked(ids:)`, `purgeLockedClips()`
- `ClipStoreError.locked` and `.decryptionFailed`
- `Clip.isLocked`

Suggestions for other packages:

- **Sync:** skip `clip.isLocked`, because while unlocked the store returns plaintext.
- **Paste:** when pasting a locked note, add `org.nspasteboard.ConcealedType`.
- **Delete key:** offer `deleteLockedClips` when the selection contains locked clips, because `delete(ids:)` skips them.

## Keychain read failures (bug-fix pass)
`VaultKeychain.read(account:)` returns `.found`, `.notFound` or `.failed(status)`. Only a definitive *not found* (or an undecodable key) shows "The vault key is missing" with the Reset Vault guidance. Any other failure (access denied after an ad-hoc re-sign, cancelled prompt, locked Keychain) shows "Keychain denied access — choose Always Allow and retry" and never mentions Reset. Vault key reads happen only on an explicit unlock / lock / verify action, never during rendering.
Windows showing a locked note's text close or blank on `.dittoVaultChanged` when the vault locks: editor, properties, compare, QR (WindowRouter), the Preview window (`PreviewWindowController.closeIfLockedNote`), and desktop sticky notes (blank text view + cleared undo stack). A desktop note whose edit is waiting for the vault asks "Unlock to save your changes?" (Unlock & Save / Discard / Cancel) on close. A new note saved with "Lock this note" that could not be locked says so ("The note was saved but not locked") and the toggle shows off.
