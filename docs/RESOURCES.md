# Resources

## Upstream
- Ditto repository: https://github.com/sabrogden/Ditto (GPL-3.0)
- Ported release: https://github.com/sabrogden/Ditto/releases/tag/3.25.113.0 (2025-09-27)
- Ditto wiki: https://github.com/sabrogden/Ditto/wiki
- Key upstream files studied: `src/ActionEnums.cpp`, `src/Options.cpp`, `src/QPasteWnd.cpp`, `src/Clip.cpp`,
  `src/DatabaseUtilities.cpp`, `src/OleClipSource.cpp`, `src/FormatSQL.cpp`, `src/Server.cpp`, `src/Client.cpp`,
  `EncryptDecrypt/Encryption.cpp`, `src/Theme.cpp`, `Debug/Themes/*.xml`, `Debug/Language/*.xml`

## Apple platform
- NSPasteboard: https://developer.apple.com/documentation/appkit/nspasteboard
- Transient/concealed pasteboard markers: http://nspasteboard.org
- Carbon hotkeys `RegisterEventHotKey` (HIToolbox `Events.h` / `CarbonEvents.h`)
- CGEvent keyboard events: https://developer.apple.com/documentation/coregraphics/cgevent
- Accessibility trust: `AXIsProcessTrustedWithOptions`
- SMAppService (launch at login): https://developer.apple.com/documentation/servicemanagement/smappservice
- Network.framework: https://developer.apple.com/documentation/network
- CryptoKit: https://developer.apple.com/documentation/cryptokit
- CoreImage QR: `CIQRCodeGenerator`
- Hardened runtime: https://developer.apple.com/documentation/security/hardened_runtime

## Tooling
- SwiftPM universal builds: `swift build -c release --arch arm64 --arch x86_64`
- swift-testing: https://github.com/swiftlang/swift-testing
- `hdiutil`, `iconutil`, `sips`, `codesign`, `lipo` (macOS built-ins)

## Knowledge base (this repo)
- `docs/ARCHITECTURE.md`: modules and API contract
- `docs/FEATURES.md`: parity matrix
- `docs/PLAN.md`: decisions and phases
- `docs/RELEASE.md`: release process
- `docs/kb/data-model.md`, `docs/kb/macos-platform.md`, `docs/kb/themes.md`, `docs/kb/friends-protocol.md`,
  `docs/kb/security-review-upstream.md`
