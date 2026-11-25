// FriendsService.swift — LAN clip sharing over Network.framework, driving DittoCore.FriendsProtocol.
//
// Layering:
//   FriendsLink    one NWConnection + FriendsSession (hello -> confirm -> messages), timeouts, inbox. Runs on the net queue.
//                  The client speaks first; the server sends its Hello only after the client's Hello verified.
//   FriendsEngine  listener (Bonjour), accept policy (LAN-only, <=4 conns, per-IP rate limit), client jobs. Net queue.
//   FriendsService @MainActor facade (FriendsServicing): settings, Keychain passphrase, store/UI/pasteboard work.
//
// Security properties (see docs/kb/security-review-upstream.md): off by default, passphrase required, only
// private/link-local/loopback peers accepted, outbound connects only to hosts saved in Settings, no file transfer,
// received formats filtered to a fixed allow-list, all allocation sizes capped by FriendsProtocol, no secret logging.

import AppKit
import CryptoKit
import DittoCore
import Foundation
import Network

// MARK: - Helpers

struct FriendsNetError: Error, LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum FriendsNet {
    /// Raw address bytes (4 or 16) of an IP endpoint; nil for hostnames / non-IP endpoints.
    static func ipBytes(_ ep: NWEndpoint?) -> [UInt8]? {
        guard case let .hostPort(host, _)? = ep else { return nil }
        switch host {
        case .ipv4(let a): return [UInt8](a.rawValue)
        case .ipv6(let a): return [UInt8](a.rawValue)
        default: return nil
        }
    }

    /// 10/8, 172.16/12, 192.168/16, 169.254/16, 127/8, ::1, fc00::/7, fe80::/10 (and IPv4-mapped forms of those).
    static func isLocalNetwork(_ b: [UInt8]) -> Bool {
        if b.count == 4 {
            switch (b[0], b[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16 ... 31): return true
            default: return false
            }
        }
        guard b.count == 16 else { return false }
        if b[0 ..< 15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }          // ::1
        if b[0] & 0xFE == 0xFC { return true }                                        // fc00::/7
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true }                        // fe80::/10
        if b[0 ..< 10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {    // ::ffff:a.b.c.d
            return isLocalNetwork(Array(b[12 ..< 16]))
        }
        return false
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    /// Strip control/format characters and bound length — peer strings are display-only.
    static func sanitize(_ s: String, maxChars: Int) -> String {
        let cleaned = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
        var out = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > maxChars { out = String(out.prefix(maxChars)) }
        return out
    }

    static func truncate(_ s: String, bytes n: Int) -> String {
        var out = "", used = 0
        for ch in s {
            let c = ch.utf8.count
            if used + c > n { break }
            out.append(ch); used += c
        }
        return out
    }
}

// MARK: - Link (one connection)

final class FriendsLink: @unchecked Sendable {
    enum Phase { case hello, confirm, active, closed }

    static let handshakeTimeout: TimeInterval = 10
    static let idleTimeout: TimeInterval = 60
    /// The protocol is lock-step (one clip, wait for ack), so a well-behaved peer never has more than one
    /// message queued; anything beyond this is a flood and the link is dropped.
    static let maxInbox = 2

    let conn: NWConnection
    let session: FriendsSession
    let role: FriendsRole
    let q: DispatchQueue
    private(set) var phase = Phase.hello
    private(set) var peerName = ""

    var onEstablished: ((FriendsLink) -> Void)?
    var onMessage: ((FriendsLink, FriendsMessage, @escaping () -> Void) -> Void)?
    /// (link, wasStillHandshaking, reason)
    var onClosed: ((FriendsLink, Bool, String) -> Void)?

    private var helloBuf = Data()
    private var ownHello = Data()
    private let acc = FrameAccumulator()
    private var timer: DispatchWorkItem?
    private var inbox = [FriendsMessage]()
    private var busy = false

    init(conn: NWConnection, role: FriendsRole, key: SymmetricKey, deviceName: String, queue: DispatchQueue) {
        self.conn = conn
        self.role = role
        self.q = queue
        self.session = FriendsSession(role: role, key: key, deviceName: deviceName)
    }

    func start() {
        arm(Self.handshakeTimeout)
        conn.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready: self.ready()
            case .failed: self.close("connection failed")
            case .waiting: break
            case .cancelled: self.close("connection closed")
            default: break
            }
        }
        conn.start(queue: q)
    }

    private func ready() {
        guard phase == .hello else { return }
        // Re-verify the resolved remote address (covers hostnames chosen for outbound connections).
        let remote = conn.currentPath?.remoteEndpoint ?? conn.endpoint
        guard let ip = FriendsNet.ipBytes(remote), FriendsNet.isLocalNetwork(ip) else {
            close("peer is not on the local network"); return
        }
        ownHello = session.makeHello()
        // The server answers only after the client's Hello MAC verified, so an unauthenticated LAN host
        // that merely connects never receives a fresh HMAC to brute-force the passphrase offline.
        if role == .client { sendRaw(ownHello) }
        receiveLoop()
    }

    private func sendRaw(_ data: Data) {
        conn.send(content: data, completion: .contentProcessed { [weak self] err in
            if err != nil { self?.close("send failed") }
        })
    }

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, err in
            guard let self = self, self.phase != .closed else { return }
            if let data = data, !data.isEmpty { self.ingest(data) }
            guard self.phase != .closed else { return }
            if err != nil || complete {
                self.close(self.phase == .active ? "" : "peer closed during handshake")
                return
            }
            self.receiveLoop()
        }
    }

    private func ingest(_ data: Data) {
        do {
            var rest = data
            if phase == .hello {
                helloBuf.append(data)
                guard let total = try FriendsHello.totalLength(prefix: helloBuf), helloBuf.count >= total else { return }
                let hello = Data(helloBuf.prefix(total))
                rest = Data(helloBuf.dropFirst(total))
                helloBuf = Data()
                peerName = FriendsNet.sanitize(try session.receiveHello(hello), maxChars: 64)
                if role == .server { sendRaw(ownHello) }
                ownHello = Data()
                phase = .confirm
                send(.confirm)
            }
            if phase == .confirm || phase == .active {
                for frame in try acc.append(rest) {
                    guard phase != .closed else { return }
                    let msg = try session.open(frame: frame)
                    if phase == .confirm {
                        phase = .active          // session guarantees this first message is .confirm
                        arm(Self.idleTimeout)
                        onEstablished?(self)
                    } else {
                        inbox.append(msg)
                        // Enforced here, not only in pump(): pump() returns early while busy.
                        if inbox.count > Self.maxInbox { close("too many pending messages"); return }
                    }
                }
                if phase == .active { arm(Self.idleTimeout) }
                pump()
            }
        } catch {
            close("protocol error")
        }
    }

    private func pump() {
        guard !busy, phase == .active, !inbox.isEmpty else { return }
        guard inbox.count <= Self.maxInbox else { close("too many pending messages"); return }
        let m = inbox.removeFirst()
        busy = true
        onMessage?(self, m) { [weak self] in
            self?.q.async { self?.busy = false; self?.pump() }
        }
    }

    func send(_ msg: FriendsMessage, then: (() -> Void)? = nil) {
        guard phase != .closed else { return }
        do {
            let frame = try session.seal(msg)
            conn.send(content: frame, completion: .contentProcessed { [weak self] err in
                if err != nil { self?.close("send failed") } else { then?() }
            })
        } catch {
            close("could not encode message")
        }
    }

    private func arm(_ seconds: TimeInterval) {
        timer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.close("timed out") }
        timer = item
        q.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func close(_ reason: String) {
        guard phase != .closed else { return }
        let handshaking = phase == .hello || phase == .confirm
        phase = .closed
        timer?.cancel(); timer = nil
        conn.stateUpdateHandler = nil
        conn.cancel()
        let cb = onClosed
        onClosed = nil; onMessage = nil; onEstablished = nil
        inbox.removeAll()
        cb?(self, handshaking, reason)
    }
}

// MARK: - Engine (listener + outbound jobs)

final class FriendsEngine: @unchecked Sendable {
    static let maxServerConnections = 4
    static let failureLimit = 5
    static let failureWindow: TimeInterval = 600
    static let blockDuration: TimeInterval = 600

    let q = DispatchQueue(label: "io.github.dittomac.friends.net")
    var onStatus: (@Sendable (String, Bool) -> Void)?
    var onClip: (@Sendable (FriendsClip, String, @escaping @Sendable (Bool) -> Void) -> Void)?

    private var listener: NWListener?
    private var servers = [ObjectIdentifier: FriendsLink]()
    private var clients = [ObjectIdentifier: FriendsLink]()
    private var failures = [String: [Date]]()
    private var blocked = [String: Date]()

    // MARK: listener

    func start(port: Int, deviceName: String, key: SymmetricKey) {
        q.async { [self] in
            stopLocked()
            guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { onStatus?("Error: bad port", false); return }
            let l: NWListener
            do { l = try NWListener(using: .tcp, on: p) } catch {
                onStatus?("Error: \(error.localizedDescription)", false); return
            }
            let svcName = FriendsNet.truncate(FriendsNet.sanitize(deviceName, maxChars: 63), bytes: 63)
            l.service = NWListener.Service(name: svcName.isEmpty ? nil : svcName, type: "_dittomac._tcp")
            l.stateUpdateHandler = { [weak self, weak l] st in
                guard let self = self, let l = l, self.listener === l else { return }
                switch st {
                case .ready: self.onStatus?("Listening on port \(port)", true)
                case .failed(let e):
                    self.onStatus?("Error: \(e.localizedDescription)", false)
                    l.cancel()
                    self.listener = nil
                case .waiting(let e): self.onStatus?("Waiting: \(e.localizedDescription)", false)
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn, key: key, deviceName: deviceName) }
            listener = l
            l.start(queue: q)
        }
    }

    func stop() { q.async { [self] in stopLocked() } }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        for l in Array(servers.values) { l.close("stopped") }
        for l in Array(clients.values) { l.close("stopped") }
    }

    // MARK: accept policy

    private func accept(_ conn: NWConnection, key: SymmetricKey, deviceName: String) {
        guard let ip = FriendsNet.ipBytes(conn.endpoint), FriendsNet.isLocalNetwork(ip) else { conn.cancel(); return }
        let ipKey = FriendsNet.hex(ip)
        let now = Date()
        if let until = blocked[ipKey] {
            if until > now { conn.cancel(); return }
            blocked[ipKey] = nil
        }
        guard servers.count < Self.maxServerConnections else { conn.cancel(); return }

        let link = FriendsLink(conn: conn, role: .server, key: key, deviceName: deviceName, queue: q)
        let id = ObjectIdentifier(link)
        servers[id] = link
        link.onClosed = { [weak self] _, handshaking, _ in
            guard let self = self else { return }
            self.servers[id] = nil
            if handshaking { self.recordFailure(ipKey) }
        }
        link.onMessage = { [weak self] link, msg, done in
            switch msg {
            case .clip(let clip):
                guard let onClip = self?.onClip else { link.close("no handler"); done(); return }
                onClip(clip, link.peerName) { ok in
                    link.q.async {
                        if ok { link.send(.ack) } else { link.close("rejected") }
                        done()
                    }
                }
            case .bye:
                link.close("")
                done()
            default:
                link.close("unexpected message")
                done()
            }
        }
        link.start()
    }

    private func recordFailure(_ ip: String) {
        let now = Date()
        if failures.count > 1024 { failures.removeAll() }
        if blocked.count > 1024 { blocked = blocked.filter { $0.value > now } }
        var arr = (failures[ip] ?? []).filter { now.timeIntervalSince($0) < Self.failureWindow }
        arr.append(now)
        if arr.count >= Self.failureLimit {
            blocked[ip] = now.addingTimeInterval(Self.blockDuration)
            failures[ip] = nil
        } else {
            failures[ip] = arr
        }
    }

    // MARK: outbound

    private final class Job {
        var clips: [FriendsClip]
        var index = 0
        var finished = false
        let completion: (Result<Int, FriendsNetError>) -> Void
        init(clips: [FriendsClip], completion: @escaping (Result<Int, FriendsNetError>) -> Void) {
            self.clips = clips; self.completion = completion
        }
        func finish(_ r: Result<Int, FriendsNetError>) {
            guard !finished else { return }
            finished = true
            completion(r)
        }
    }

    /// Connects to `host:port` (taken from Settings by the caller), sends `clips`, waits for one ack each.
    /// `completion` is invoked on the net queue.
    func sendClips(host: String, port: Int, key: SymmetricKey, deviceName: String, clips: [FriendsClip],
                   completion: @escaping @Sendable (Result<Int, FriendsNetError>) -> Void) {
        q.async { [self] in
            guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port >= 1024, !host.isEmpty else {
                completion(.failure(FriendsNetError("invalid peer address"))); return
            }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            let link = FriendsLink(conn: conn, role: .client, key: key, deviceName: deviceName, queue: q)
            let id = ObjectIdentifier(link)
            clients[id] = link
            let job = Job(clips: clips, completion: completion)

            func next(_ link: FriendsLink) {
                if job.index < job.clips.count {
                    link.send(.clip(job.clips[job.index]))
                } else {
                    let n = job.clips.count
                    link.send(.bye) { job.finish(.success(n)); link.close("") }
                }
            }
            link.onEstablished = { link in next(link) }
            link.onMessage = { link, msg, done in
                if case .ack = msg { job.index += 1; next(link) } else { link.close("unexpected message") }
                done()
            }
            link.onClosed = { [weak self] _, handshaking, reason in
                self?.clients[id] = nil
                if !job.finished {
                    let why = handshaking ? "handshake failed (check passphrase and address)" : (reason.isEmpty ? "connection closed" : reason)
                    job.finish(.failure(FriendsNetError(why)))
                }
            }
            link.start()
        }
    }
}

// MARK: - Service

@MainActor
final class FriendsService: FriendsServicing {
    static let passphraseAccount = "friends.passphrase"
    static let allowedTypes: Set<String> = [ClipUTI.plainText, ClipUTI.rtf, ClipUTI.html, ClipUTI.png, ClipUTI.tiff]
    static let sendableTypes: [String] = [ClipUTI.plainText, ClipUTI.rtf, ClipUTI.html, ClipUTI.png]

    private let state: AppState
    private let engine = FriendsEngine()
    private(set) var isRunning = false
    private(set) var statusText = "Off"

    private var passphraseLoaded = false
    private var passphrase: String?
    private var cachedKey: SymmetricKey?
    private var generation = 0
    private var appliedConfig: String?
    private var settingsObserver: NSObjectProtocol?
    private var settingsDebounce: Task<Void, Never>?

    private var currentConfig: String {
        let s = state.settings
        return "\(s.friendsEnabled)|\(s.friendsPort)|\(s.friendsDeviceName)"
    }

    init(state: AppState) {
        self.state = state
        engine.onStatus = { [weak self] text, running in
            Task { @MainActor in self?.setStatus(text, running: running) }
        }
        engine.onClip = { [weak self] clip, name, done in
            Task { @MainActor in done(self?.receive(clip: clip, from: name) ?? false) }
        }
        applySettings()
        // Restart the listener only when enabled/port/deviceName actually changed (debounced: the port field
        // posts on every keystroke).
        settingsObserver = NotificationCenter.default.addObserver(forName: .dittoSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.settingsMayHaveChanged() }
        }
    }

    deinit {
        if let o = settingsObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func settingsMayHaveChanged() {
        guard currentConfig != appliedConfig else { return }
        settingsDebounce?.cancel()
        settingsDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self, self.currentConfig != self.appliedConfig else { return }
            self.applySettings()
        }
    }

    var hasPassphrase: Bool { passphraseLoaded ? passphrase != nil : Keychain.has(account: Self.passphraseAccount) }

    private func loadPassphrase() -> String? {
        if !passphraseLoaded {
            passphrase = Keychain.get(account: Self.passphraseAccount)
            passphraseLoaded = true
        }
        return passphrase
    }

    private func setStatus(_ text: String, running: Bool) {
        statusText = text
        isRunning = running
    }

    func setPassphrase(_ passphrase: String) throws {
        guard FriendsProtocol.validatePassphrase(passphrase) else { throw FriendsError.invalidPassphrase }
        try Keychain.set(passphrase, account: Self.passphraseAccount)
        self.passphrase = passphrase
        passphraseLoaded = true
        cachedKey = nil
        applySettings()
    }

    /// PBKDF2 off the main thread, cached until the passphrase changes.
    private func key() async -> SymmetricKey? {
        if let k = cachedKey { return k }
        guard let p = loadPassphrase() else { return nil }
        let k = await Task.detached(priority: .userInitiated) { FriendsProtocol.deriveKey(passphrase: p) }.value
        if loadPassphrase() == p { cachedKey = k }
        return k
    }

    func applySettings() {
        settingsDebounce?.cancel()
        appliedConfig = currentConfig
        generation += 1
        let gen = generation
        engine.stop()
        let s = state.settings
        guard s.friendsEnabled else { setStatus("Off", running: false); return }
        guard hasPassphrase else { setStatus("Needs passphrase", running: false); return }
        setStatus("Starting…", running: false)
        let port = s.friendsPort
        let name = s.friendsDeviceName
        Task {
            guard let k = await self.key(), gen == self.generation else { return }
            self.engine.start(port: port, deviceName: name, key: k)
        }
    }

    // MARK: receive (main actor)

    private func receive(clip: FriendsClip, from peerName: String) -> Bool {
        var seen = Set<String>()
        var formats = [ClipFormat]()
        for f in clip.formats where Self.allowedTypes.contains(f.type) && !f.data.isEmpty && seen.insert(f.type).inserted {
            formats.append(ClipFormat(type: f.type, data: f.data))
        }
        guard !formats.isEmpty else { return true }          // nothing acceptable (e.g. file URLs): ack and drop
        let name = peerName.isEmpty ? "friend" : peerName

        var desc = FriendsNet.sanitize(clip.description, maxChars: 500)
        if desc.isEmpty, let t = formats.first(where: { $0.type == ClipUTI.plainText }), let s = String(data: t.data, encoding: .utf8) {
            desc = FriendsNet.sanitize(String(s.prefix(500)), maxChars: 500)
        }
        if desc.isEmpty { desc = "Clip from \(name)" }

        do {
            _ = try state.store.addClip(formats: formats, description: desc, sourceApp: "friend:\(name)")
        } catch {
            return false
        }
        state.clipsChanged()
        if state.settings.friendsAutoPutOnClipboard { state.paste.writeToPasteboard(formats) }
        state.message("Received clip from \(name)")
        return true
    }

    // MARK: send (main actor)

    func send(clipIDs: [Int64], to peer: FriendPeer) { send(clipIDs: clipIDs, to: peer, silent: false) }

    func sendToAutoPeers(clipID: Int64) {
        guard state.settings.friendsEnabled, hasPassphrase else { return }
        if let c = try? state.store.clip(id: clipID), c.sourceApp.hasPrefix("friend:") || c.isLocked { return }   // never echo received clips
        for peer in state.settings.friendsPeers where peer.sendAllCopies {
            send(clipIDs: [clipID], to: peer, silent: true)
        }
    }

    private func send(clipIDs: [Int64], to peerArg: FriendPeer, silent: Bool) {
        let s = state.settings
        // Always use the address stored in Settings, never one supplied by the caller's copy of the struct.
        let peer = s.friendsPeers.first(where: { $0.id == peerArg.id }) ?? peerArg
        guard s.friendsEnabled else { if !silent { state.message("Friends is turned off") }; return }
        guard hasPassphrase else { if !silent { state.message("Set a Friends passphrase first") }; return }
        guard s.friendsPeers.contains(where: { $0.id == peer.id }) else { if !silent { state.message("Unknown friend") }; return }

        let sourceName = FriendsNet.truncate(s.friendsDeviceName, bytes: FriendsProtocol.maxDeviceNameBytes)
        var clips = [FriendsClip]()
        var skipped = 0
        for id in clipIDs {
            // Locked notes never leave this Mac (while unlocked the store would return plaintext).
            guard let c = try? state.store.clip(id: id), !c.isGroup, !c.isLocked, let all = try? state.store.formats(clipID: id) else { skipped += 1; continue }
            var formats = [FriendsFormat]()
            var total = 0
            var seen = Set<String>()
            for f in all where Self.sendableTypes.contains(f.type) && !f.data.isEmpty && seen.insert(f.type).inserted {
                formats.append(FriendsFormat(type: f.type, data: f.data))
                total += f.data.count
            }
            guard !formats.isEmpty, total <= FriendsProtocol.maxClipDataBytes else { skipped += 1; continue }
            let desc = FriendsNet.truncate(FriendsNet.sanitize(c.text, maxChars: 500), bytes: FriendsProtocol.maxDescriptionBytes)
            clips.append(FriendsClip(description: desc, sourceDevice: sourceName, formats: formats))
        }
        guard !clips.isEmpty else {
            if !silent { state.message(skipped > 0 ? "Nothing sendable (unsupported or over 16 MiB)" : "Nothing to send") }
            return
        }

        let name = FriendsNet.sanitize(peer.name, maxChars: 64)
        let count = clips.count
        let deviceName = s.friendsDeviceName
        let job = clips
        Task {
            guard let k = await self.key() else { return }
            self.engine.sendClips(host: peer.host, port: peer.port, key: k, deviceName: deviceName, clips: job) { result in
                Task { @MainActor in
                    switch result {
                    case .success:
                        if !silent {
                            let extra = skipped > 0 ? " (\(skipped) skipped)" : ""
                            self.state.message("Sent \(count) clip\(count == 1 ? "" : "s") to \(name)\(extra)")
                        }
                    case .failure(let e):
                        self.state.message("Could not send to \(name): \(e.message)")
                    }
                }
            }
        }
    }
}
