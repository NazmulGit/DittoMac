# Upload and share by link (v1.2)

Code: `Sources/DittoCore/Upload.swift` (pure logic), `UploadEngine.swift` (URLSession), `ShareLinks.swift`, `Settings+Upload.swift`;
app side `Services/Upload/ImageUploader.swift` and `UI/Screenshot/UploadSettingsView.swift`.
Tests: `UploadTests.swift` (includes the loopback integration test), `ShareLinksTests.swift`.

## Why not prnt.sc / Lightshot
Lightshot's upload server has no public API and no terms for third-party clients. Using it would mean impersonating the Lightshot app
and sending users' images to a service that has not agreed to receive them. DittoMac does not contact prntscr.com or prnt.sc in any way.
Upload is a separate, opt-in feature that talks to a provider **the user chooses**.

## Providers
| Kind | Request | Response |
|---|---|---|
| `custom` | `POST` the user's https endpoint (http only for `localhost`, `127.0.0.1`, `::1`), multipart field name configurable (default `file`), optional one extra header (name in prefs, **value in the Keychain**, account `upload.customHeader`) | Plain-text URL (first non-empty line) or a dotted JSON key path such as `data.link`; numeric path parts index arrays (`data.0.link`) |
| `imgur` | `POST https://api.imgur.com/3/image`, header `Authorization: Client-ID <id>`, multipart field `image`. The Client-ID is the **user's own** (Keychain account `upload.imgurClientID`); DittoMac ships none | JSON `data.link`; `data.deletehash` is kept for `delete` (`DELETE /3/image/<hash>`) |
| `zeroX0` | `POST https://0x0.st`, multipart field `file`, optional `expires=<hours>` and `secret=` (hard-to-guess URL), `User-Agent: DittoMac/<version>` | Plain-text URL. No delete support |

Uploading is **off** until a provider is chosen (`uploadProvider` unset). The user agent is `DittoMac/<version>` on every request.

## Validation and limits
| Rule | Value |
|---|---|
| Endpoint | https; http only for loopback; host required; no `user:pass@`; no fragment; no whitespace or control characters; ≤ 2048 characters |
| Returned link | https only, host required, no userinfo, ≤ 2048 characters, parses with `URLComponents`; otherwise `badResponse` |
| Image types | `image/png`, `image/jpeg`, `image/bmp` only |
| Filename | last path component, `[A-Za-z0-9._-]`, no leading dot, ≤ 48 characters of stem, extension forced to match the MIME type |
| Form field names | `[A-Za-z0-9_.-]{1,64}` (cannot inject headers into the multipart part) |
| Custom header | RFC 7230 token name; `Host`, `Content-Length`, `Content-Type`, `Cookie`, `User-Agent`, … refused; value without control characters, ≤ 4096 bytes |
| Request body | ≤ 25 MB (error beyond, nothing is sent) |
| Response body | ≤ 64 KB; the task is cancelled the moment a server sends more (also when `Content-Length` already says so) |
| Timeouts | 30 s idle timeout, 180 s for the whole transfer |
| Redirects | followed only to https URLs without userinfo. A different host is followed **without** the Authorization/custom header, and only when the redirect doesn't resend the image (307/308 to another host are refused); anything else (http, file, …) is refused and counts as a failed upload |
| Session | ephemeral configuration, no cookie storage, no URL cache, no credential storage; a fresh session per upload |
| History | last 200 uploads (url, provider, date, delete token) in `~/Library/Application Support/DittoMac/uploads.json`, mode 0600 in a 0700 folder, written atomically. The Imgur delete hash is a capability, so the file is private; `clearHistory()` empties it |

## Consent
`ImageUploader.ensureReady(state:completion:)`:
1. Not configured → opens Preferences › Screenshots and completes `false`.
2. Otherwise shows an `NSAlert`: "Uploading sends this image to *host*. Anyone who has the link can view it. DittoMac is not affiliated with *host*. Continue?" with a **Don't ask again for this host** checkbox. The host is stored in `uploadConsentHosts` only when the box is ticked and the user continues; without the tick the notice appears on every upload. "Reset notices" in the settings view clears the list.
3. `upload(...)` itself never prompts: callers must call `ensureReady` first. It refuses to send unless the host is in `uploadConsentHosts` or was confirmed in the notice just before (one upload per confirmation). The Test button in the settings view does, and uploads a generated 1×1 PNG.

## Share links (`ShareLinks`)
`url(for:link:title:)` for X, Facebook, Pinterest (`media` = the link), VK, Reddit, LinkedIn, WhatsApp, Telegram and Email; `similarImageSearch(link:)` is
`https://lens.google.com/uploadbyurl?url=…`. Every value is percent-encoded with the RFC 3986 *unreserved* set (so `&`, `=`, `#`, `+`, spaces and
non-ASCII are escaped) and placed with `URLComponents.percentEncodedQuery`. A link that is not https, has no host, has userinfo or exceeds 2048
characters returns `nil` for every network. `mailto:` is produced only for the Email button and is opened by `NSWorkspace` on the user's click; it is never fetched.
`https://x.com/intent/post` is X's current web intent (formerly `twitter.com/intent/tweet`).

## Integrator checklist
- Call `ensureReady` then `upload`; show `UploadError.errorDescription` on failure; open web-intent URLs with `NSWorkspace.shared.open`.
- Settings keys are in `Settings.uploadKeys` / `Settings.beautifyKeys`; add them to `Settings.allKeys` (not our file) if "Reset all settings" should clear them. Keychain items are removed by the Remove buttons only.
- ATS: `http://127.0.0.1` needs no Info.plist key; remote http would be blocked by ATS anyway.
