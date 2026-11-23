# Release process

## Build a release locally
```bash
scripts/release.sh 1.0.0
```
This runs the test suite, builds a universal (arm64 + x86_64) release binary, assembles and signs `dist/DittoMac.app`,
then creates `dist/DittoMac-<version>-universal.dmg` plus a `.sha256` file.

Set `SIGN_IDENTITY="Developer ID Application: …"` to sign with a real certificate instead of ad-hoc.
Notarization (`xcrun notarytool`) requires Xcode and an Apple Developer account. It is not part of the current pipeline.

## Publish
```bash
git tag -a v1.0.0 -m "DittoMac 1.0.0"
git push origin main --tags
gh release create v1.0.0 dist/DittoMac-1.0.0-universal.dmg dist/DittoMac-1.0.0-universal.dmg.sha256 \
  --title "DittoMac 1.0.0" --notes-file docs/release-notes/1.0.0.md
```

## Checklist
- [ ] `swift test` green
- [ ] `lipo -archs` shows `x86_64 arm64`
- [ ] `codesign --verify --deep --strict` passes; `codesign -dv` shows `flags=…(runtime)`
- [ ] `hdiutil verify` passes; DMG mounts and contains the app and an Applications link
- [ ] App launches from the mounted DMG, menu-bar icon appears, a copy shows up in the popup
- [ ] CHANGELOG and release notes updated

## Release log
| Version | Date | Notes |
|---|---|---|
| 1.0.0 | 2026-11-23 | First release, port of Ditto 3.25.113.0 |
