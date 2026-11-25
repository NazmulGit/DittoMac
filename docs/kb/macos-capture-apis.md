# macOS capture, auth, crypto and upload APIs (verified 2026-11-25, CLT-only toolchain, SDK 27.2)

## Screen capture
- Deployment target 13: `CGDisplayCreateImage` / `CGWindowListCreateImage` compile (deprecated in 14, **unavailable at target 15+**). Use them only as the macOS 13 fallback.
- macOS 14+: `SCScreenshotManager.captureImage(contentFilter:configuration:)` inside `if #available(macOS 14.0, *)`.
  Retina: `config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))` (same for height).
  Per window: `SCContentFilter(desktopIndependentWindow:)`; shadow via `ignoreShadowsSingleWindow = false`.
  Per display: `SCContentFilter(display:excludingWindows:)`; `SCDisplay.frame` is global points, top-left origin.
- `SCShareableContent.excludingDesktopWindows(_:onScreenWindowsOnly:)` (async).
- `CGPreflightScreenCaptureAccess()` is safe to call anytime; call `CGRequestScreenCaptureAccess()` only on an explicit user action.
  `CGWindowListCopyWindowInfo` works without permission but window names are redacted.
- Permission is tied to the app's code signature: ad-hoc builds must be re-granted after each update.

## LocalAuthentication
`LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason:)` shows Touch ID with Mac-password fallback; no entitlement needed on macOS; `localizedReason` must be non-empty.

## Crypto
AES-GCM via CryptoKit (`combined` = nonce(12) + ciphertext + tag(16)). PBKDF2-HMAC-SHA256 via `CCKeyDerivationPBKDF`:
600k iterations ≈ 0.10 s on Apple silicon (slower on Intel). Use `HMAC.isValidAuthenticationCode` or an XOR fold for constant-time compares.

## Keychain
Ad-hoc binaries cannot use the data-protection keychain (-34018 `errSecMissingEntitlement`). Use the file-based login keychain with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` or `AfterFirstUnlockThisDeviceOnly`. It ties access to the code signature, so a re-signed
build may trigger a keychain prompt; prefer storing a *wrapped* key.

## Image effects
`CIFilter.pixellate()` / `gaussianBlur()` (`import CoreImage.CIFilterBuiltins`). Blur: `.clampedToExtent()` before, `.cropped(to:)` after.
Pixellate: set `center` to the crop-rect origin so blocks align. `CGPath(roundedRect:cornerWidth:cornerHeight:transform:)`.
Offscreen: `CGContext` sRGB premultipliedLast → gradient → shadow while filling a rounded path → clip and draw image → PNG via `NSBitmapImageRep`.

## Upload and ATS
`URLSession.uploadTask(with:from:)` multipart works. Cap the response with a `URLSessionDataDelegate` (cancel the task past the cap).
`http://127.0.0.1:<port>` works with no ATS key; remote http is blocked by ATS (good: only https providers).

## Sharing
`NSSharingService.sharingServices(forItems:)` is deprecated in 13; use `NSSharingServicePicker` (needs a view to show) or `standardShareMenuItem`.
