// UploadEngine.swift — the URLSession side of uploads, kept in DittoCore (Foundation only) so the real network code
// path is covered by tests against a 127.0.0.1 server. Ephemeral session, no cookies, no cache, 30 s timeout,
// 64 KB response cap, redirects only to https, progress + cancel.
import Foundation

public final class UploadHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    fileprivate func attach(_ t: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        task = t
        if cancelled { t.cancel() }
    }
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

public final class UploadEngine: @unchecked Sendable {
    public init() {}

    /// `completion` runs on a background queue.
    @discardableResult
    public func upload(plan: UploadPlan, data: Data, filename: String, mimeType: String,
                       progress: (@Sendable (Double) -> Void)?,
                       completion: @escaping @Sendable (Result<UploadOutcome, UploadFailure>) -> Void) -> UploadHandle? {
        guard MultipartForm.allowedMimeTypes.contains(mimeType.lowercased()) else { completion(.failure(.unsupportedType)); return nil }
        guard !data.isEmpty, data.count <= UploadLimits.maxRequestBytes else { completion(.failure(data.isEmpty ? .badResponse : .tooLarge)); return nil }
        guard UploadURLRules.validateEndpoint(plan.url.absoluteString) != nil else { completion(.failure(.invalidEndpoint)); return nil }
        let boundary = MultipartForm.randomBoundary()
        guard let body = MultipartForm.build(boundary: boundary, fields: plan.extraFields, fileField: plan.fieldName,
                                             filename: filename, mimeType: mimeType, data: data) else {
            completion(.failure(.invalidConfiguration("The upload form could not be built."))); return nil
        }
        guard body.count <= UploadLimits.maxRequestBytes else { completion(.failure(.tooLarge)); return nil }

        var req = URLRequest(url: plan.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: UploadLimits.timeout)
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        for (k, v) in plan.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let delegate = Delegate(secretHeaders: plan.secretHeaderNames, progress: progress) { result in
            switch result {
            case .failure(let f): completion(.failure(f))
            case .success(let body):
                if let outcome = UploadPlanner.parse(body: body, format: plan.format) { completion(.success(outcome)) }
                else { completion(.failure(.badResponse)) }
            }
        }
        let session = Self.makeSession(delegate: delegate)
        let task = session.uploadTask(with: req, from: body)
        let handle = UploadHandle()
        handle.attach(task)
        task.resume()
        session.finishTasksAndInvalidate()
        return handle
    }

    /// Imgur anonymous delete. completion(true) on HTTP 2xx.
    @discardableResult
    public func delete(url: URL, headers: [String: String], completion: @escaping @Sendable (Bool) -> Void) -> UploadHandle? {
        guard UploadURLRules.validateEndpoint(url.absoluteString) != nil else { completion(false); return nil }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: UploadLimits.timeout)
        req.httpMethod = "DELETE"
        req.httpShouldHandleCookies = false
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let delegate = Delegate(secretHeaders: Array(headers.keys.filter { $0.lowercased() != "user-agent" }), progress: nil) { r in
            if case .success = r { completion(true) } else { completion(false) }
        }
        let session = Self.makeSession(delegate: delegate)
        let task = session.dataTask(with: req)
        let handle = UploadHandle()
        handle.attach(task)
        task.resume()
        session.finishTasksAndInvalidate()
        return handle
    }

    static func makeSession(delegate: URLSessionDelegate) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = UploadLimits.timeout
        cfg.timeoutIntervalForResource = 180
        cfg.waitsForConnectivity = false
        cfg.urlCredentialStorage = nil
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .userInitiated
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: q)
    }

    private final class Delegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        private var buffer = CappedBuffer()
        private var status = 0
        private var capped = false
        private let secretHeaders: [String]
        private let progress: (@Sendable (Double) -> Void)?
        private let finish: (Result<Data, UploadFailure>) -> Void
        private var finished = false

        init(secretHeaders: [String], progress: (@Sendable (Double) -> Void)?, finish: @escaping (Result<Data, UploadFailure>) -> Void) {
            self.secretHeaders = secretHeaders; self.progress = progress; self.finish = finish
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                        totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            progress?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            switch RedirectPolicy.decide(from: task.originalRequest?.url, to: request.url, method: request.httpMethod) {
            case .refuse: completionHandler(nil)
            case .follow: completionHandler(request)
            case .followStrippingCredentials:
                var r = request
                for h in secretHeaders { r.setValue(nil, forHTTPHeaderField: h) }
                r.setValue(nil, forHTTPHeaderField: "Authorization")
                completionHandler(r)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if response.expectedContentLength > Int64(UploadLimits.maxResponseBytes) { capped = true; completionHandler(.cancel); return }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            if !buffer.append(data) { capped = true; dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard !finished else { return }
            finished = true
            if capped { finish(.failure(.badResponse)); return }
            if let error {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { finish(.failure(.cancelled)) }
                else { finish(.failure(.network(Self.describe(ns)))) }
                return
            }
            if (300...399).contains(status) { finish(.failure(.badResponse)); return }   // redirect we refused
            guard (200...299).contains(status) else { finish(.failure(.server(status))); return }
            finish(.success(buffer.data))
        }

        static func describe(_ e: NSError) -> String {
            switch e.code {
            case NSURLErrorTimedOut: return "The server did not answer within 30 seconds."
            case NSURLErrorNotConnectedToInternet: return "You appear to be offline."
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "Could not connect to the server."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
                return "The server's certificate could not be verified."
            default: return e.localizedDescription
            }
        }
    }
}
