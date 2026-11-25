# Plan and TODO

## Decisions (made autonomously, per request)
| Decision | Choice | Why |
|---|---|---|
| Approach | Native Swift rewrite (AppKit popup, SwiftUI prefs) | Upstream is Win32/MFC; no portable layer exists |
| Name | **DittoMac** (unofficial port), GPL-3.0 | Credit upstream, comply with GPL, avoid implying official status |
| Min macOS | 13 Ventura | SMAppService, modern SwiftUI; covers all Apple-silicon Macs |
| CPU | Universal (arm64 + x86_64) | Apple silicon M1–M5 native; Intel still works |
| Storage | SQLite3 (system lib), upstream-compatible schema | Parity + Windows DB import |
| Default hotkey | ⌃` (Control+backtick) | Same as upstream Ctrl+` |
| Signing | Ad-hoc + hardened runtime | No Developer ID available; documented Gatekeeper steps |
| Networking | Secure redesign, off by default | Upstream protocol has critical flaws (docs/kb/security-review-upstream.md) |
| Scripting/add-ins | Replaced by declarative Copy Rules | Eliminates code-execution surface |
| Repo visibility | Public GitHub repo under the user's account | Requested release |

## Phases
- [x] P0 Research (5 parallel agents: features, data model, security, themes/lang, macOS toolchain)
- [x] P1 Architecture, API contract, KB docs
- [ ] P2 Build — wave 1 (parallel): Core store+search · Transforms/Rules/CRC/Settings · Friends protocol · Themes/icon/packaging scripts
- [ ] P3 Build — wave 2 (parallel): Popup+paste+hotkeys app shell · Secondary windows (prefs, properties, editor, preview, QR, compare, delete data) · Friends service + copy buffers
- [ ] P4 Integrate, universal build, swift-testing suite green
- [ ] P5 Independent security review of the port + fixes
- [ ] P6 Package `.app` → sign → DMG → verify; GitHub repo; release v1.0.0 with notes and checksums

---

# v1.2 plan: Screenshots, Locked Notes, Sync, Appearance

Request (2026-11-25): add everything Lightshot does so DittoMac can replace it (capture, annotate, upload and share by link,
professional borders), lockable sticky notes (Mac password or a new password), Google Drive and other cloud sync/backup,
more customization and UI polish, then release and update the local install.

## Decisions
| Topic | Decision | Why |
|---|---|---|
| prntscr.com upload | **Not used.** Lightshot's server has no public API and DittoMac must not impersonate it or send images to a service without terms for third-party clients. Upload goes to a user-chosen provider (custom HTTPS endpoint, Imgur with the user's own Client-ID, or 0x0.st), **off until the user enables it and accepts a one-time notice** | Privacy and legality; links are public to anyone who has them |
| Share by link | After upload: copy link, open in browser, share via the macOS Share menu, plus web-intent buttons (X/Twitter, Facebook, Pinterest, VK, Reddit, email) and "Search similar image" (Google Lens by URL) | Matches Lightshot's share/search buttons without private APIs |
| Capture engine | Frozen full-screen snapshot per display (strategy chosen from the verified API report), then our own overlay, so selection, handles and tools work like Lightshot | Same UX as Lightshot; no dependence on `screencapture -i` UI |
| Beautify (professional borders) | Padding, gradient/solid/transparent backgrounds, rounded corners, shadow, outline, optional macOS window frame; presets; can auto-apply to every capture | Requested "good design border" |
| Lock | Per-clip lock: AES-256-GCM at rest with a random vault key in the Keychain; unlock via **Touch ID / Mac login password** (macOS prompt, app never sees it) or a **separate DittoMac password** (PBKDF2-SHA256 600k); auto-lock timer, lock on sleep/screen lock; locked clips are never deleted by retention, delete-all, delete-unused, delete-data, or Delete key without unlocking | "Don't get deleted by mistake" plus real confidentiality at rest |
| Sticky notes | A sticky note is a top-sticky clip (new "New Sticky Note" action) that can be locked; optional floating desktop note window | Reuses sticky + lock instead of a second data model |
| Cloud | **Folder-based E2E-encrypted sync/backup** through whatever your cloud app syncs: Google Drive for Desktop, iCloud Drive, Dropbox, OneDrive, Box, … (auto-detected under `~/Library/CloudStorage`). No OAuth, no tokens, provider never sees plaintext. Locked clips are not synced in v1.2 | Real Google Drive API needs a registered OAuth app and stores tokens; folder sync works with every provider and is safer |
| Hotkey defaults | Area ⌃⇧4, Window ⌃⇧5… final values chosen in the screenshots agent; all configurable | Avoid macOS system shortcuts (⌘⇧3/4/5) |
| Signing | Still ad-hoc. macOS ties Screen Recording and Accessibility permissions to the app's signature, so they must be re-granted after each update | No Developer ID; documented in README |

## Work packages (parallel, disjoint files)
| ID | Owner | Scope |
|---|---|---|
| A | Vault agent | `ClipStore` schema v2 (lock columns, encrypted blobs, delete protection), `Vault` crypto in DittoCore, `VaultService` (LocalAuthentication, password, auto-lock), Security prefs tab, tests |
| B1 | Capture agent | Screen capture, overlay, selection, all Lightshot tools, editor window, actions (copy/save/print/upload/share), hotkeys, Screenshots prefs |
| B2 | Beautify + upload agent | `BeautifyRenderer`, styles/presets UI, `ImageUploader` + providers, share-link helpers, tests |
| C | Sync agent | Cloud-folder detection, encrypted snapshot sync + backup, merge logic, Sync prefs tab, tests |
| D | UI agent (after A–C) | Appearance prefs, row polish (source-app icon, timestamp, density), lock UI in popup and menus, New Sticky Note, desktop note window |
| E | Review agents | Security review, parity review |

## Release
Version **1.2.0**: update CHANGELOG, README, FEATURES, SECURITY, kb docs; tag; GitHub release; install to /Applications and relaunch.
