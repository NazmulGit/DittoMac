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
