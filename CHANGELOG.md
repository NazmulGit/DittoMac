# Changelog

All notable changes to DittoMac are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/)
and the project uses [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-11-25
### Added
- **Screenshots (Lightshot replacement).** Area (⌃⇧4), window (⌃⇧5) and full-screen (⌃⇧3) capture with a frozen-screen
  overlay, selection move/resize, magnifier with colour code, ⌘A whole screen and hold-⌘ instant copy; tools: pen, line,
  arrow, rectangle, ellipse, marker, text, numbered steps, pixelate, blur, eyedropper, undo/redo; actions: copy, save
  (PNG/JPG/BMP), print, pin to screen, upload and share by link, share to social networks, search similar images.
  Every screenshot is added to the clipboard history.
- **Beautify:** 18 professional presets, gradients/solid/transparent backgrounds, padding, rounded corners, shadow,
  outline, macOS-window and browser frames, aspect ratios; per capture or automatic.
- **Upload and share:** bring-your-own provider (custom HTTPS endpoint, Imgur with your Client-ID, 0x0.st), one-time
  consent notice, upload history with delete for Imgur; share-link buttons for X, Facebook, Pinterest, VK, Reddit,
  LinkedIn, WhatsApp, Telegram, email, and Google Lens search.
- **Locked sticky notes (vault).** Lock clips so retention, delete-all, delete-unused and the Delete key can't remove
  them; AES-256-GCM at rest; unlock with Touch ID / Mac login password or a new DittoMac password; auto-lock, lock on
  sleep/screen lock; New Sticky Note (⌥⌘N) and floating desktop notes.
- **Cloud sync and backup** through any folder your cloud app syncs (Google Drive, iCloud Drive, Dropbox, OneDrive, Box):
  end-to-end encrypted snapshots, additive merge across Macs, rolling backups, restore.
- **Appearance and customization:** light/dark/system, accent colour, theme editor with import/export, row density,
  timestamps, source-app icons, format badges, translucent popup, menu-bar icon styles, popup polish.
### Fixed
- Capture/vault/sync hardening from two review passes (see `docs/kb/security-review-v12.md`).
- Reset all settings now also resets the new screenshot, upload, sync, appearance and vault timing options.

## [1.1.1] - 2026-11-25
### Fixed
- **Drag and drop of several clips now works.** Select any number of clips and drag them to Finder, the desktop,
  Mail, Notes, Messages or another app: each clip is dropped as a real file (image, .rtfd/.rtf/.html/.txt) and also
  offers its text/rich-text/image formats to apps that paste them directly. Clips copied from Finder are still
  dragged as the original files.
- Start-at-login now re-points itself at the installed copy if the app was moved or reinstalled.

## [1.1.0] - 2026-11-23
### Added
- Full-fidelity formatting. With "Keep full formatting" (Preferences › Types, on by default) DittoMac also saves web
  archives, RTFD (rich text with inline images), JPEG, GIF, HEIC, PDF and links, byte for byte, so a copy from Safari,
  Notes or Pages pastes back with its headings, styles and pictures. Each format is capped at 64 MB.
- Clips that only carry rich text (RTFD- or HTML-only sources) get a plain-text description and full-text search.
- Paste formats: Original (keep all formatting), Plain Text, Rich Text (no images), Markdown and HTML Source.
  Right-click › **Paste As** and **Copy As** submenus, for one clip or several.
- ⌥⇧Return pastes as Markdown. HTML is converted by a new built-in converter (headings, nested lists, tables, code,
  quotes, links and images); RTF/RTFD by font size and traits.
- Preferences › Quick Paste: **Default paste format** (Return, double-click, ⌘1–⌘0 and global paste hotkeys) and
  **Always paste plain text into these apps**.
- **Save Clip As…** (⌘⇧S): Rich Text Document (.rtf, or .rtfd when the clip has images), Web Archive, HTML, Markdown,
  Plain Text or PNG. With several clips selected, one file per clip is written to a folder.
- Clip rows show a subtle symbol for clips that keep formatting, and for clips with an image as well as text.
- The preview shows RTFD with its images and lists the clip's formats.

### Security
- Web archives and HTML are never rendered by WebKit directly: previews go through the allow-list sanitiser, and
  Markdown / plain-text conversion is pure Swift. Nothing is fetched from the network. Links are kept only for
  http, https and mailto. RTFD previews keep image attachments only, and images too large to decode are shown as
  thumbnails.

## [1.0.1] - 2026-11-23
### Changed
- DittoMac now starts with your Mac by default. It registers itself as a login item on first launch. Turn this off in
  Preferences › General or System Settings › General › Login Items; either choice is respected afterwards.

## [1.0.0] - 2026-11-23
First release: a native macOS port of Ditto 3.25.113.0.

### Added
- Clipboard history for text, RTF, HTML, images and file references, stored in SQLite (schema mirrors upstream).
- Quick Paste popup (⌃`) with search (wildcard, contains, regex; description, full-text and quick-paste scopes),
  nested groups, sticky clips, paste positions ⌘1–⌘0, hold-modifier cycling, and always-on-top.
- All upstream special-paste transforms, multi-paste with separator and reverse, and stitched image paste.
- Built-in editor, preview window, properties, compare, local QR codes, web search and translate.
- 5 copy buffers, global hotkeys (activate ×3, text-only paste, save clipboard, last-ten positions, per-clip, per-group).
- Copy Rules, a safe replacement for ChaiScript scripts and regex filters.
- Retention (max entries, expiry), delete unused clips, delete clip data, compact, backup and restore.
- Import of a Windows Ditto `Ditto.db`; `.dittoclips` export/import; export to text or image files; Share menu.
- Friends: end-to-end encrypted LAN clip sharing (X25519 + PSK, ChaCha20-Poly1305). Off by default.
- 12 upstream themes plus System; launch at login; menu-bar icon.
- Universal binary (Apple silicon + Intel), macOS 13+.

### Security
- Fixed by design versus upstream: default network password, remote file read, unauthenticated encryption,
  pre-auth DoS, string-built SQL, unsafe URL building and DLL/script code execution.
  See `docs/kb/security-review-upstream.md`.
- Port review fixes (HTML sanitiser allow-list, link scheme policy, image size probing, hardened import,
  Friends inbox limits). See `docs/kb/security-review-port.md`.
