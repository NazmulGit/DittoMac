import Testing
import Foundation
@testable import DittoCore

@Suite struct UploadRulesTests {
    @Test func endpointTable() {
        let ok = ["https://example.com/upload", "https://example.com:8443/u?x=1", "http://127.0.0.1:8080/up", "http://localhost/up",
                  "http://[::1]:9/up", "HTTPS://EXAMPLE.COM/x"]
        let bad = ["", "   ", "http://example.com/up", "ftp://example.com/up", "file:///etc/passwd", "javascript:alert(1)",
                   "https://user:pw@example.com/up", "https://user@example.com/up", "https:///nohost", "https://", "example.com/up",
                   "https://exa mple.com/up", "https://example.com/up\nX: y", "https://example.com/up#frag",
                   "http://127.0.0.1.evil.com/up", "http://localhost.evil.com/up", "https://example.com/" + String(repeating: "a", count: 2100)]
        for s in ok { #expect(UploadURLRules.validateEndpoint(s) != nil, "\(s)") }
        for s in bad { #expect(UploadURLRules.validateEndpoint(s) == nil, "\(s.prefix(60))") }
    }

    @Test func linkTable() {
        let ok = ["https://i.imgur.com/abc.png", "https://0x0.st/AbC1.png", "  https://example.com/a  "]
        let bad = ["", "http://i.imgur.com/abc.png", "http://127.0.0.1/a", "javascript:alert(1)", "data:text/html,x", "https://u:p@example.com/a",
                   "https://", "https://example.com/a b", "not a url", "https://example.com/" + String(repeating: "a", count: 2100)]
        for s in ok { #expect(UploadURLRules.validateLink(s) != nil, "\(s)") }
        for s in bad { #expect(UploadURLRules.validateLink(s) == nil, "\(s.prefix(60))") }
    }

    @Test func redirectPolicy() {
        let from = URL(string: "https://api.example.com/upload")!
        #expect(RedirectPolicy.decide(from: from, to: URL(string: "https://api.example.com/v2/upload")) == .follow)
        #expect(RedirectPolicy.decide(from: from, to: URL(string: "https://cdn.example.net/x")) == .followStrippingCredentials)
        #expect(RedirectPolicy.decide(from: from, to: URL(string: "http://api.example.com/x")) == .refuse)
        #expect(RedirectPolicy.decide(from: from, to: URL(string: "http://127.0.0.1/x")) == .refuse)
        #expect(RedirectPolicy.decide(from: from, to: URL(string: "file:///etc/passwd")) == .refuse)
        #expect(RedirectPolicy.decide(from: from, to: URL(string: "https://u:p@api.example.com/x")) == .refuse)
        #expect(RedirectPolicy.decide(from: from, to: nil) == .refuse)
        // A loopback http test endpoint can still not bounce to plain http.
        #expect(RedirectPolicy.decide(from: URL(string: "http://127.0.0.1:1/u"), to: URL(string: "http://127.0.0.1:1/v")) == .refuse)
    }
}

@Suite struct MultipartTests {
    @Test func filenameSanitising() {
        let png = "image/png"
        #expect(MultipartForm.sanitizeFilename("shot.png", mimeType: png) == "shot.png")
        #expect(MultipartForm.sanitizeFilename("../../etc/passwd", mimeType: png) == "passwd.png")
        #expect(MultipartForm.sanitizeFilename("C:\\Users\\me\\a b.jpg", mimeType: "image/jpeg") == "a_b.jpg")
        #expect(MultipartForm.sanitizeFilename("a\"b\r\nX-Evil: 1.png", mimeType: png) == "a_b__X-Evil__1.png")
        #expect(MultipartForm.sanitizeFilename("", mimeType: png) == "screenshot.png")
        #expect(MultipartForm.sanitizeFilename("...", mimeType: png) == "screenshot.png")
        #expect(MultipartForm.sanitizeFilename(".hidden", mimeType: png) == "hidden.png")
        #expect(MultipartForm.sanitizeFilename("日本語.png", mimeType: png) == "screenshot.png")
        #expect(MultipartForm.sanitizeFilename("x.exe", mimeType: "image/bmp") == "x.bmp")
        #expect(MultipartForm.sanitizeFilename(String(repeating: "a", count: 500) + ".png", mimeType: png).count == 52)
    }

    @Test func bodyStructure() throws {
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])
        let b = "DittoMac-0123456789abcdef"
        let body = try #require(MultipartForm.build(boundary: b, fields: [("expires", "24"), ("secret", "")], fileField: "file",
                                                    filename: "../x y.png", mimeType: "image/png", data: payload))
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.hasPrefix("--\(b)\r\nContent-Disposition: form-data; name=\"expires\"\r\n\r\n24\r\n"))
        #expect(text.contains("name=\"secret\"\r\n\r\n\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"x_y.png\"\r\nContent-Type: image/png\r\n\r\n"))
        #expect(text.hasSuffix("\r\n--\(b)--\r\n"))
        #expect(body.range(of: payload) != nil)
        #expect(text.components(separatedBy: "--\(b)").count == 5)   // 3 parts + closing + leading ""
    }

    @Test func refusesBadInputs() {
        let d = Data([1])
        #expect(MultipartForm.build(boundary: "DittoMac-0123456789", fields: [], fileField: "file", filename: "a", mimeType: "image/gif", data: d) == nil)
        #expect(MultipartForm.build(boundary: "DittoMac-0123456789", fields: [], fileField: "file", filename: "a", mimeType: "text/html", data: d) == nil)
        #expect(MultipartForm.build(boundary: "DittoMac-0123456789", fields: [], fileField: "fi\"le", filename: "a", mimeType: "image/png", data: d) == nil)
        #expect(MultipartForm.build(boundary: "DittoMac-0123456789", fields: [("a\r\nb", "x")], fileField: "file", filename: "a", mimeType: "image/png", data: d) == nil)
        #expect(MultipartForm.build(boundary: "DittoMac-0123456789", fields: [("a", "x\r\ny")], fileField: "file", filename: "a", mimeType: "image/png", data: d) == nil)
        #expect(MultipartForm.build(boundary: "bad boundary\r\n", fields: [], fileField: "file", filename: "a", mimeType: "image/png", data: d) == nil)
    }

    @Test func boundariesAreRandomAndValid() {
        let set = Set((0..<50).map { _ in MultipartForm.randomBoundary() })
        #expect(set.count == 50)
        for b in set { #expect(b.range(of: "^DittoMac-[0-9a-f]{32}$", options: .regularExpression) != nil) }
    }

    @Test func mimeAllowList() {
        #expect(MultipartForm.allowedMimeTypes == ["image/png", "image/jpeg", "image/bmp"])
    }
}

@Suite struct ResponseParsingTests {
    func data(_ s: String) -> Data { Data(s.utf8) }

    @Test func keyPathExtraction() {
        let j = data(#"{"data":{"link":"https://i.imgur.com/a.png","deletehash":"abc123","n":5,"list":[{"u":"https://x.example/1"},"s"]},"success":true}"#)
        #expect(UploadResponse.string(inJSON: j, keyPath: "data.link") == "https://i.imgur.com/a.png")
        #expect(UploadResponse.string(inJSON: j, keyPath: "data.list.0.u") == "https://x.example/1")
        #expect(UploadResponse.string(inJSON: j, keyPath: "data.list.1") == "s")
        #expect(UploadResponse.string(inJSON: j, keyPath: "data.missing") == nil)
        #expect(UploadResponse.string(inJSON: j, keyPath: "data.n") == nil)          // number, not string
        #expect(UploadResponse.string(inJSON: j, keyPath: "success") == nil)         // bool
        #expect(UploadResponse.string(inJSON: j, keyPath: "data") == nil)            // object
        #expect(UploadResponse.string(inJSON: j, keyPath: "data.list.9") == nil)
        #expect(UploadResponse.string(inJSON: j, keyPath: "data.list.-1") == nil)
        #expect(UploadResponse.string(inJSON: j, keyPath: "data.link.deeper") == nil)
        #expect(UploadResponse.string(inJSON: j, keyPath: "") == nil)
        #expect(UploadResponse.string(inJSON: j, keyPath: "data..link") == nil)
        #expect(UploadResponse.string(inJSON: j, keyPath: ".data") == nil)
        #expect(UploadResponse.string(inJSON: data("not json"), keyPath: "a") == nil)
        #expect(UploadResponse.string(inJSON: data("[\"https://a.example/x\"]"), keyPath: "0") == "https://a.example/x")
        #expect(UploadResponse.string(inJSON: data(#"{"a":null}"#), keyPath: "a") == nil)
    }

    @Test func hugeAndDeepInputs() {
        let deepPath = (0..<40).map { "k\($0)" }.joined(separator: ".")
        #expect(UploadResponse.string(inJSON: data("{}"), keyPath: deepPath) == nil)
        let big = data(#"{"a":""# + String(repeating: "x", count: UploadLimits.maxResponseBytes) + #""}"#)
        #expect(UploadResponse.string(inJSON: big, keyPath: "a") == nil)
        let nested = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        #expect(UploadResponse.string(inJSON: data(nested), keyPath: "0") == nil)
    }

    @Test func plainTextFirstLine() {
        #expect(UploadResponse.firstLine(of: data("https://0x0.st/AbC.png\n")) == "https://0x0.st/AbC.png")
        #expect(UploadResponse.firstLine(of: data("\r\n  https://a.example/x \r\nmore")) == "https://a.example/x")
        #expect(UploadResponse.firstLine(of: data("")) == nil)
        #expect(UploadResponse.firstLine(of: Data([0xFF, 0xFE])) == nil)
    }

    @Test func cappedBuffer() {
        var b = CappedBuffer(limit: 10)
        let r1 = b.append(Data(count: 6)), r2 = b.append(Data(count: 4))
        #expect(r1 && r2 && !b.exceeded && b.data.count == 10)
        let r3 = b.append(Data(count: 1))
        #expect(!r3 && b.exceeded && b.data.count == 10)
        let r4 = b.append(Data())
        #expect(!r4)
        var d = CappedBuffer()
        let r5 = d.append(Data(count: 64 * 1024 + 1))
        #expect(d.limit == 64 * 1024 && !r5)
    }
}

@Suite struct PlannerTests {
    func cfg(_ k: UploadProviderKind) -> UploadConfig { var c = UploadConfig(kind: k); c.userAgent = "DittoMac/1.2.0"; return c }
    func plan(_ c: UploadConfig) throws -> UploadPlan { try c.planResult().get() }

    @Test func imgur() throws {
        var c = cfg(.imgur)
        #expect(UploadPlanner.plan(c) == .failure(.notConfigured))
        c.imgurClientID = "abc123DEF"
        let p = try plan(c)
        #expect(p.url.absoluteString == "https://api.imgur.com/3/image" && p.fieldName == "image")
        #expect(p.headers["Authorization"] == "Client-ID abc123DEF" && p.headers["User-Agent"] == "DittoMac/1.2.0")
        #expect(p.format == .json(linkPath: "data.link", deletePath: "data.deletehash") && p.host == "api.imgur.com")
        c.imgurClientID = "abc\r\nX: 1"
        if case .failure(.invalidConfiguration) = UploadPlanner.plan(c) {} else { Issue.record("bad client id accepted") }
    }

    @Test func zeroX0() throws {
        var c = cfg(.zeroX0)
        var p = try plan(c)
        #expect(p.url.absoluteString == "https://0x0.st" && p.fieldName == "file" && p.extraFields.isEmpty)
        #expect(p.headers["User-Agent"] == "DittoMac/1.2.0" && p.format == .plainText)
        c.zeroExpiresHours = 24; c.zeroSecret = true
        p = try plan(c)
        #expect(p.extraFields.map { "\($0.0)=\($0.1)" } == ["expires=24", "secret="])
        c.zeroExpiresHours = 10_000_000
        #expect(try plan(c).extraFields.first?.1 == "8760")
    }

    @Test func custom() throws {
        var c = cfg(.custom)
        #expect(UploadPlanner.plan(c) == .failure(.notConfigured))
        c.endpoint = "http://example.com/up"
        #expect(UploadPlanner.plan(c) == .failure(.invalidEndpoint))
        c.endpoint = "https://files.example.com/up"
        var p = try plan(c)
        #expect(p.fieldName == "file" && p.format == .plainText && p.headers == ["User-Agent": "DittoMac/1.2.0"])
        c.fieldName = "img"; c.responseKeyPath = "data.link"; c.headerName = "Authorization"; c.headerValue = "Bearer t0k"
        p = try plan(c)
        #expect(p.fieldName == "img" && p.format == .json(linkPath: "data.link", deletePath: nil))
        #expect(p.headers["Authorization"] == "Bearer t0k" && p.secretHeaderNames == ["Authorization"])
        for bad in ["Host", "content-length", "Content-Type", "Cookie", "User-Agent", "Bad Name", "X:Y", ""] {
            c.headerName = bad
            if case .success = UploadPlanner.plan(c) { Issue.record("header \(bad) accepted") }
        }
        c.headerName = "X-Key"; c.headerValue = "a\r\nInjected: 1"
        if case .success = UploadPlanner.plan(c) { Issue.record("CRLF header accepted") }
        c.headerValue = "ok"; c.fieldName = "a\"b"
        if case .success = UploadPlanner.plan(c) { Issue.record("bad field accepted") }
    }

    @Test func parsing() {
        let imgur = UploadPlan.Format.json(linkPath: "data.link", deletePath: "data.deletehash")
        let ok = Data(#"{"data":{"link":"https://i.imgur.com/a.png","deletehash":"Zx9"},"success":true}"#.utf8)
        #expect(UploadPlanner.parse(body: ok, format: imgur) == UploadOutcome(link: URL(string: "https://i.imgur.com/a.png")!, deleteToken: "Zx9"))
        let evilHash = Data(#"{"data":{"link":"https://i.imgur.com/a.png","deletehash":"../../x"}}"#.utf8)
        #expect(UploadPlanner.parse(body: evilHash, format: imgur)?.deleteToken == nil)
        #expect(UploadPlanner.parse(body: Data(#"{"data":{"link":"http://i.imgur.com/a.png"}}"#.utf8), format: imgur) == nil)
        #expect(UploadPlanner.parse(body: Data(#"{"data":{"link":"javascript:alert(1)"}}"#.utf8), format: imgur) == nil)
        #expect(UploadPlanner.parse(body: Data("https://0x0.st/a.png\n".utf8), format: .plainText)?.link.absoluteString == "https://0x0.st/a.png")
        #expect(UploadPlanner.parse(body: Data("<html>error</html>".utf8), format: .plainText) == nil)
        #expect(UploadPlanner.parse(body: Data("http://0x0.st/a.png".utf8), format: .plainText) == nil)
        #expect(UploadPlanner.imgurDeleteURL(deleteToken: "Zx9")?.absoluteString == "https://api.imgur.com/3/image/Zx9")
        #expect(UploadPlanner.imgurDeleteURL(deleteToken: "../x") == nil)
    }
}

extension UploadConfig { func planResult() -> Result<UploadPlan, UploadFailure> { UploadPlanner.plan(self) } }

@Suite struct HistoryTests {
    struct Entry: Codable, Equatable { var url: String; var date: Date }

    @Test func persistsTrimsAndLocksDownPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dm-up-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sub/uploads.json")
        #expect(UploadHistoryFile.load(Entry.self, from: file).isEmpty)
        let items = (0..<250).map { Entry(url: "https://x.example/\($0)", date: Date(timeIntervalSince1970: Double($0 * 60))) }
        #expect(UploadHistoryFile.save(items, to: file))
        let back = UploadHistoryFile.load(Entry.self, from: file)
        #expect(back.count == 200 && back.first == items.first && back.last == items[199])
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let dattrs = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        #expect((dattrs[.posixPermissions] as? Int) == 0o700)
        #expect(UploadHistoryFile.save([Entry](), to: file))
        #expect(UploadHistoryFile.load(Entry.self, from: file).isEmpty)
        // Corrupt file → empty, no crash.
        try Data("{not json".utf8).write(to: file)
        #expect(UploadHistoryFile.load(Entry.self, from: file).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }
}

@Suite struct UploadSettingsTests {
    func make() -> Settings { Settings(defaults: UserDefaults(suiteName: "test-up-\(UUID())")!) }
    @Test func defaultsAndRoundTrip() {
        let s = make()
        #expect(s.uploadProvider == nil && s.uploadEndpoint == "" && s.uploadFieldName == "file" && s.uploadResponseKey == "")
        #expect(s.uploadZeroExpiresHours == 0 && s.uploadZeroSecret && s.uploadConsentHosts.isEmpty)
        s.uploadProvider = .imgur; #expect(s.uploadProvider == .imgur)
        s.uploadProvider = nil; #expect(s.uploadProvider == nil)
        s.uploadZeroExpiresHours = 99_999_999; #expect(s.uploadZeroExpiresHours == 8760)
        s.uploadConsentHosts = ["API.imgur.com", "0x0.st", "0x0.st"]
        #expect(s.uploadConsentHosts == ["0x0.st", "api.imgur.com"] && s.hasUploadConsent(host: "API.IMGUR.COM") && !s.hasUploadConsent(host: "evil.example"))
        #expect(!s.beautifyAutoApply)
        s.beautifyAutoApply = true; #expect(s.beautifyAutoApply)
        s.beautifyDefaultStyleJSON = Data("{}".utf8); #expect(s.beautifyDefaultStyleJSON == Data("{}".utf8))
        #expect(Settings.uploadKeys.contains("uploadProvider") && Settings.beautifyKeys.contains("beautifyAutoApply"))
    }
}

// MARK: - Integration: real UploadEngine/URLSession against a throwaway server bound to 127.0.0.1 ONLY.

private let serverScript = #"""
import http.server, json, os, sys, time, base64
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def _body(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(n) if n else b""
    def _send(self, code, body, ctype="text/plain", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers()
        try: self.wfile.write(body)
        except Exception: pass
    def _record(self, body):
        with open(os.path.join(out, "log.jsonl"), "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "headers": dict(self.headers),
                                "len": len(body), "head": base64.b64encode(body[:600]).decode(),
                                "all": base64.b64encode(body).decode() if len(body) < 70000 else ""}) + "\n")
    def do_POST(self):
        body = self._body(); self._record(body)
        p = self.path
        if p.startswith("/text"): self._send(200, b"https://example.invalid/i/abc.png\n")
        elif p.startswith("/json"): self._send(200, json.dumps({"data": {"link": "https://example.invalid/i/j.png", "deletehash": "Dh123"}}).encode(), "application/json")
        elif p.startswith("/big"): self._send(200, b"x" * 200000)
        elif p.startswith("/redir"): self._send(302, b"", extra={"Location": "http://127.0.0.1:1/never"})
        elif p.startswith("/500"): self._send(500, b"boom")
        elif p.startswith("/slow"): time.sleep(4); self._send(200, b"https://example.invalid/slow\n")
        elif p.startswith("/badlink"): self._send(200, b"http://example.invalid/insecure\n")
        else: self._send(404, b"nope")
    def do_DELETE(self):
        self._record(b""); self._send(200, b"{}")
class S(http.server.ThreadingHTTPServer):
    daemon_threads = True
srv = S(("127.0.0.1", 0), H)
open(os.path.join(out, "port"), "w").write(str(srv.server_address[1]))
srv.serve_forever()
"""#

private final class TestServer: @unchecked Sendable {
    let dir: URL
    let process: Process
    let port: Int
    init?() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return nil }
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dm-srv-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)) != nil else { return nil }
        let script = d.appendingPathComponent("server.py")
        guard (try? serverScript.write(to: script, atomically: true, encoding: .utf8)) != nil else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", script.path, d.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { try? FileManager.default.removeItem(at: d); return nil }
        var found: Int?
        for _ in 0..<100 {
            if let s = try? String(contentsOf: d.appendingPathComponent("port"), encoding: .utf8), let n = Int(s) { found = n; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let port = found else { p.terminate(); try? FileManager.default.removeItem(at: d); return nil }
        self.dir = d; self.process = p; self.port = port
    }
    deinit { process.terminate(); try? FileManager.default.removeItem(at: dir) }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }
    func log() -> [[String: Any]] {
        guard let s = try? String(contentsOf: dir.appendingPathComponent("log.jsonl"), encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
}

private func pngBytes(extra: Int = 0) -> Data {
    var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    d.append(Data((0..<(64 + extra)).map { UInt8($0 & 0xFF) }))
    return d
}

private func run(_ engine: UploadEngine, _ plan: UploadPlan, _ data: Data, mime: String = "image/png",
                 progress: (@Sendable (Double) -> Void)? = nil) async -> Result<UploadOutcome, UploadFailure> {
    await withCheckedContinuation { cont in
        engine.upload(plan: plan, data: data, filename: "Screen Shot.png", mimeType: mime, progress: progress) { cont.resume(returning: $0) }
    }
}

private func customPlan(_ server: TestServer, _ path: String, key: String = "", header: Bool = false) throws -> UploadPlan {
    var c = UploadConfig(kind: .custom)
    c.endpoint = server.url(path); c.fieldName = "pic"; c.responseKeyPath = key; c.userAgent = "DittoMac/test"
    if header { c.headerName = "Authorization"; c.headerValue = "Bearer secret-token" }
    return try UploadPlanner.plan(c).get()
}

@Suite(.serialized) struct UploadIntegrationTests {
    @Test func uploadsPlainTextAndSendsExpectedRequest() async throws {
        guard let server = TestServer() else { return }   // python3 / loopback unavailable: skip
        let png = pngBytes(extra: 40_000)
        let progressSeen = ProgressBox()
        let result = await run(UploadEngine(), try customPlan(server, "/text", header: true), png) { progressSeen.add($0) }
        let out = try result.get()
        #expect(out.link.absoluteString == "https://example.invalid/i/abc.png" && out.deleteToken == nil)
        #expect(progressSeen.peak > 0.99)
        let entry = try #require(server.log().first)
        let h = Dictionary(uniqueKeysWithValues: (entry["headers"] as! [String: String]).map { ($0.key.lowercased(), $0.value) })
        #expect(entry["method"] as? String == "POST")
        #expect(h["authorization"] == "Bearer secret-token" && h["user-agent"] == "DittoMac/test")
        #expect(h["cookie"] == nil)
        #expect(h["content-type"]?.hasPrefix("multipart/form-data; boundary=DittoMac-") == true)
        let all = Data(base64Encoded: entry["all"] as! String)!
        let text = String(decoding: all.prefix(400), as: UTF8.self)
        #expect(text.contains("name=\"pic\"; filename=\"Screen_Shot.png\"") && text.contains("Content-Type: image/png"))
        #expect(all.range(of: png) != nil)
    }

    @Test func parsesJSONAndKeepsDeleteTokenKeyPath() async throws {
        guard let server = TestServer() else { return }
        var c = UploadConfig(kind: .custom)
        c.endpoint = server.url("/json"); c.responseKeyPath = "data.link"
        let out = try await run(UploadEngine(), try UploadPlanner.plan(c).get(), pngBytes()).get()
        #expect(out.link.absoluteString == "https://example.invalid/i/j.png")
        // Same body through the Imgur format yields the delete hash.
        var plan = try UploadPlanner.plan(c).get()
        plan.format = .json(linkPath: "data.link", deletePath: "data.deletehash")
        #expect(try await run(UploadEngine(), plan, pngBytes()).get().deleteToken == "Dh123")
    }

    @Test func failureModes() async throws {
        guard let server = TestServer() else { return }
        let e = UploadEngine()
        #expect(await run(e, try customPlan(server, "/big"), pngBytes()) == .failure(.badResponse))      // 200 KB > 64 KB cap
        #expect(await run(e, try customPlan(server, "/500"), pngBytes()) == .failure(.server(500)))
        #expect(await run(e, try customPlan(server, "/redir"), pngBytes()) == .failure(.badResponse))   // redirect to http refused
        #expect(await run(e, try customPlan(server, "/badlink"), pngBytes()) == .failure(.badResponse)) // http link rejected
        #expect(await run(e, try customPlan(server, "/json", key: "data.missing"), pngBytes()) == .failure(.badResponse))
        #expect(await run(e, try customPlan(server, "/text"), pngBytes(), mime: "image/gif") == .failure(.unsupportedType))
        #expect(await run(e, try customPlan(server, "/text"), Data(count: UploadLimits.maxRequestBytes + 1)) == .failure(.tooLarge))
        #expect(await run(e, try customPlan(server, "/text"), Data()) == .failure(.badResponse))
        // Nothing reached the server for the rejected requests.
        let paths = server.log().compactMap { $0["path"] as? String }
        #expect(!paths.contains("/text"))
    }

    @Test func cancelStopsTheTask() async throws {
        guard let server = TestServer() else { return }
        let plan = try customPlan(server, "/slow")
        let result: Result<UploadOutcome, UploadFailure> = await withCheckedContinuation { cont in
            let h = UploadEngine().upload(plan: plan, data: pngBytes(), filename: "a.png", mimeType: "image/png", progress: nil) { cont.resume(returning: $0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { h?.cancel() }
        }
        #expect(result == .failure(.cancelled))
    }

    @Test func refusesNonLoopbackHTTPEndpointsBeforeConnecting() async throws {
        var plan = UploadPlan(url: URL(string: "http://203.0.113.9/up")!, headers: [:], secretHeaderNames: [], fieldName: "file",
                              extraFields: [], format: .plainText, kind: .custom)
        #expect(await run(UploadEngine(), plan, pngBytes()) == .failure(.invalidEndpoint))
        plan.url = URL(string: "https://u:p@example.com/up")!
        #expect(await run(UploadEngine(), plan, pngBytes()) == .failure(.invalidEndpoint))
    }

    @Test func deleteSendsDELETE() async throws {
        guard let server = TestServer() else { return }
        let ok: Bool = await withCheckedContinuation { cont in
            UploadEngine().delete(url: URL(string: server.url("/3/image/Dh123"))!, headers: ["Authorization": "Client-ID abc"]) { cont.resume(returning: $0) }
        }
        #expect(ok)
        #expect(server.log().first?["method"] as? String == "DELETE")
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock(); private var m = 0.0
    func add(_ v: Double) { lock.lock(); m = Swift.max(m, v); lock.unlock() }
    var peak: Double { lock.lock(); defer { lock.unlock() }; return m }
}
