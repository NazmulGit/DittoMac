# Changelog

All notable changes to DittoMac are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/)
and the project uses [Semantic Versioning](https://semver.org/).

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
