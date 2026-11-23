# Friends protocol (DittoMac secure clip sharing)

Implementation: `Sources/DittoCore/FriendsProtocol.swift` (pure; the app layer owns sockets). Tests: `Tests/DittoCoreTests/FriendsProtocolTests.swift`.

## Threat model
Attacker is on the same LAN: can connect to the port, sniff, modify, replay and reorder traffic, and open many connections. Attacker does not know the shared passphrase. Out of scope: a peer that knows the passphrase is trusted to send clips (it can still not read files, allocate unbounded memory, or make us connect anywhere). Offline guessing of a captured Hello MAC is slowed by PBKDF2 (600k) and the 12-char minimum, but a weak 12-char passphrase is still guessable; use a long random one.

## Handshake (protocol version 2; symmetric, 1 round trip, client = initiator)
1. Long-term key: `PBKDF2-HMAC-SHA256(passphrase NFC UTF-8, salt "DittoMac-Friends-v1", 600_000 iters) -> 32 B`. Constants are local; nothing about the KDF is on the wire. Cached per passphrase (keyed by SHA-256 of it).
2. Ephemeral key: every `FriendsSession` generates a fresh `Curve25519.KeyAgreement` (X25519) private key in `init`. `makeHello()` returns the same bytes if called twice on one session; the private key is set to nil once the session keys are derived and is never persisted or reused across sessions.
3. Each side sends Hello (the client first; the DittoMac server sends its Hello only after the client's verified, so a host that merely connects gets no MAC to brute-force offline): `"DMF1" | ver u8=2 | nonce[32] | ephPub[32] | nameLen u8 (<=64) | name | mac[32]`, `mac = HMAC(longTermKey, "DittoMac v2 hello" | role(1=client,2=server) | nonce | ephPub | nameLen | name)`. Role in the MAC blocks reflection; the ephemeral key in the MAC stops a MITM without the passphrase from substituting its own key. Hello is unframed; `FriendsHello.totalLength(prefix:)` tells the app how many bytes to read (max `FriendsProtocol.maxHelloBytes` = 166). Any version byte other than 2 (including v1 peers) fails with `unsupportedVersion` as soon as byte 5 arrives; there is no negotiation and so no downgrade.
4. Verify peer MAC in constant time (CryptoKit) before touching the public key. Failure -> `authenticationFailed`, drop. Then reject an all-zero (or our own reflected) public key, any key CryptoKit refuses, and an all-zero X25519 output (low-order points) -> `invalidPublicKey`.
5. Session keys: `dh = X25519(ownEph, peerEph)`, `psk = HMAC(longTermKey, "DittoMac v2 psk")`, then `HKDF-SHA256(ikm: dh | psk, salt: clientNonce | serverNonce | clientPub | serverPub, info: "DittoMac v2 c2s" / "DittoMac v2 s2c")`, one 32-byte key per direction. Fresh nonces and fresh ephemeral keys make every session's keys unique, so old sessions cannot be replayed. The PSK in the IKM means the keys also depend on the passphrase, so knowing only the DH output is not enough.
6. First encrypted frame each way must be `Confirm` (enforced by `seal` and `open`).

### Security properties of v2
- **Forward secrecy.** A passive sniffer who records a session and later learns or cracks the passphrase still cannot compute `dh` (both ephemeral private keys are gone), so recorded traffic stays confidential. Under v1 the session keys were a function of the passphrase and the public nonces only.
- **Active attacker without the passphrase** cannot complete a handshake or swap ephemeral keys (Hello MAC), so cannot MITM.
- **Remaining offline-guess risk.** Every Hello still carries `HMAC(longTermKey, ...)` over public data, so anyone who sees a Hello (sniffing a real session, or a client tricked into connecting to a spoofed peer address) can test passphrase guesses offline at PBKDF2-600k cost. Forward secrecy does not help once the passphrase is guessed *during* a live session (an attacker who knows the passphrase can MITM future sessions). Removing the offline guess entirely needs a PAKE (e.g. CPace or SPAKE2+ over the same transport); that is future work.

## Framing
`u32 BE length (<=16 MiB)` + ChaChaPoly combined (`nonce12 | ct | tag16`). Nonce = 4 zero bytes + u64 BE counter from 0 per direction; receiver demands exactly the expected counter (replay/reorder/drop rejected; state advances only after successful decrypt+decode). AAD = `"DMF1" | dir` (0 c2s, 1 s2c), so a frame cannot be reflected back. `FrameAccumulator` rejects an over-cap or under-minimum length as soon as the 4-byte prefix arrives, before buffering the body, and is poisoned afterwards (app must close the connection).

## Messages (tag u8, big-endian fixed-width ints, all lengths checked)
`1 Confirm`, `2 Clip`, `3 Ack`, `4 Bye`. Clip: `descLen u16 (<=4096) desc | srcLen u8 (<=64) src | fmtCount u8 (<=16) | { typeLen u8 (1..128) type [A-Za-z0-9.-]+ | dataLen u32 data }*`. Total data <= `maxClipDataBytes` = 16 MiB - 64 KiB (so a maximal clip fits one 16 MiB frame; the frame cap wins over "16 MiB of data"). Strings must be valid UTF-8; trailing bytes are an error. Strings from peers are display-only.

## Removed vs upstream Ditto
Default password `LetMeIn` (passphrase mandatory, >=12 chars; listener off by default is an app-layer duty); `REQUEST_FILES` and any file send/receive (no arbitrary file read, no UNC/NTLM leak); wire-supplied KDF rounds; unauthenticated AES-CBC (now AEAD, per-direction keys, counters); plaintext hash oracle; unbounded/peer-sized allocations; connect-back to peer-claimed hosts (no host/port field exists in any message); passphrase logging (errors carry no secrets).

## App-layer duties (not enforceable here)
Listener disabled by default; store passphrase in Keychain; limit concurrent/pending connections and add a handshake timeout (~5 s) and idle timeout; never connect to addresses a peer supplies; rate-limit failed hellos per source; run `deriveKey(passphrase:)` off the main thread; the server should drop the connection on any thrown `FriendsError`.

## Known limits
See also `docs/kb/security-review-port.md`. Hello MACs allow offline passphrase guessing (see above; a PAKE would remove this). Session keys are bound to the nonces and ephemeral keys but not to the full Hello transcript (device names are MAC'd separately per side). v1 and v2 peers cannot talk to each other; both sides must be upgraded together. Hello is not encrypted, so device names are visible to the LAN. Clip contents of up to ~16 MiB are held in memory per message.

## App integration

Implemented in `Sources/DittoMac/Services/FriendsService.swift` (+ `Keychain.swift`).

- `FriendsService(state:)` is `@MainActor` and calls `applySettings()` itself on init; call it again after changing `friendsEnabled`, `friendsPort` or `friendsDeviceName`. `setPassphrase(_:)` validates (>= 12 chars), stores it in Keychain (service `io.github.dittomac`, account `friends.passphrase`, `AfterFirstUnlockThisDeviceOnly`), drops the cached key and restarts.
- Listener starts only if `friendsEnabled` AND a passphrase exists. `statusText`: "Off", "Needs passphrase", "Starting…", "Listening on port N", "Error: …". Bonjour type `_dittomac._tcp`, name = device name.
- Layers: `FriendsLink` (one connection: hello -> confirm -> messages, 10 s handshake / 60 s idle timers, inbox of at most 2 queued messages, enforced on arrival), `FriendsEngine` (listener, accept policy, outbound jobs, private serial queue), `FriendsService` (main-actor store/pasteboard/UI work). PBKDF2 runs once on a detached task and is cached.
- Accept policy: remote must be 10/8, 172.16/12, 192.168/16, 169.254/16, 127/8, ::1, fc00::/7, fe80::/10 (incl. IPv4-mapped); max 4 server connections; >= 5 failed handshakes from one IP within 10 min blocks that IP for 10 min. Outbound links re-check the resolved remote address after connect.
- Receive: only `public.utf8-plain-text`, `public.rtf`, `public.html`, `public.png`, `public.tiff` are kept (`public.file-url` and anything else dropped), stored with `sourceApp = "friend:<authenticated peer name>"`, `clipsChanged` posted, optional auto-put via `paste.writeToPasteboard`, then the ack is sent. Peer strings are sanitised (control chars stripped, length-capped) and display-only.
- Send: connects only to the host/port saved in `Settings.friendsPeers` (looked up by peer id). Sends text/rtf/html/png formats only; clips over `maxClipDataBytes` are skipped. `sendToAutoPeers` never forwards clips whose sourceApp starts with `friend:` (no echo loops) and is silent on success.

### Copy buffers
`Sources/DittoMac/Services/CopyBuffers.swift`: hotkeys `buffer1..5.copy|paste|cut` registered via `state.hotkeys` (prefix `buffer`), reloaded on `.dittoHotkeysChanged`. Slot -> clip id map lives in UserDefaults `copyBuffers.slots`; slot clips use `sourceApp = "copybuffer"` and description `[Buffer n] <preview>`. Copy/cut snapshots the pasteboard, posts ⌘C/⌘X after 150 ms, polls `changeCount` (<= 1.5 s), stores the result and restores the original pasteboard (tagged internal, `ignoreChangeCount`). Paste writes the slot, posts ⌘V, restores after 0.75 s unless the pasteboard changed meanwhile.
