import Foundation

enum HTTPMethod: String, CaseIterable, Identifiable, Sendable {
    case GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS

    var id: String { rawValue }

    var carriesBody: Bool {
        switch self {
        case .POST, .PUT, .PATCH: true
        case .GET, .HEAD, .DELETE, .OPTIONS: false
        }
    }
}

struct TimingPhase: Sendable, Equatable {
    var name: String
    var duration: Duration
}

struct HTTPResult: Sendable {
    let url: URL
    let status: Int
    let headers: [(name: String, value: String)]
    let body: Data
    let elapsed: Duration
    let finalURL: URL
    var timings: [TimingPhase] = []
    var requestHeaders: [(name: String, value: String)] = []

    var statusPhrase: String {
        Self.phrase(for: status)
    }

    private static func phrase(for code: Int) -> String {
        switch code {
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "HTTP \(code)"
        }
    }
}

enum HTTPError: LocalizedError {
    case missingScheme
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .missingScheme:
            "URL must start with http:// or https://"
        case .invalidURL(let detail):
            "Invalid URL: \(detail)"
        }
    }
}

struct HTTPClient: Sendable {
    var followRedirects = true
    /// Seconds; 0 waits indefinitely.
    var timeout: TimeInterval = 30
    var network: NetworkOptions = .none

    func send(
        method: String,
        urlText: String,
        body: Data?,
        headers: [(name: String, value: String)]
    ) async throws -> HTTPResult {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            throw HTTPError.missingScheme
        }
        guard let url = URL(string: trimmed) else {
            throw HTTPError.invalidURL(trimmed)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        let timeout = timeout > 0 ? timeout : TimeInterval.greatestFiniteMagnitude
        request.timeoutInterval = timeout
        for (name, value) in headers where !name.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let jar = network.cookies, request.value(forHTTPHeaderField: "Cookie") == nil, let cookie = jar.header(for: url) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let body, !body.isEmpty {
            request.httpBody = body
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let proxy = network.proxyDictionary {
            config.connectionProxyDictionary = proxy
        }
        let delegate = TransferDelegate(followRedirects: followRedirects, network: network, explicitCookie: headers.contains { $0.name.caseInsensitiveCompare("Cookie") == .orderedSame })
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await session.data(for: request)
        let elapsed = start.duration(to: clock.now)

        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.invalidURL("no HTTP response")
        }
        network.cookies?.store(from: http, for: http.url ?? url)

        let responseHeaders: [(name: String, value: String)] = http.allHeaderFields
            .compactMap { key, value in
                guard let name = key as? String, let value = value as? String else { return nil }
                return (name, value)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

        return HTTPResult(
            url: url,
            status: http.statusCode,
            headers: responseHeaders,
            body: data,
            elapsed: elapsed,
            finalURL: http.url ?? url,
            timings: delegate.timings,
            requestHeaders: delegate.sentHeaders ?? request.allHTTPHeaderFields.map { $0.map { ($0.key, $0.value) } } ?? []
        )
    }
}

/// Redirects, cookies across redirects, TLS and client-certificate
/// challenges, proxy auth, and timing metrics for one request.
private final class TransferDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let followRedirects: Bool
    let network: NetworkOptions
    let explicitCookie: Bool
    private let lock = NSLock()
    private var collected: [TimingPhase] = []
    private var headersSent: [(name: String, value: String)]?

    init(followRedirects: Bool, network: NetworkOptions, explicitCookie: Bool) {
        self.followRedirects = followRedirects
        self.network = network
        self.explicitCookie = explicitCookie
    }

    var timings: [TimingPhase] { lock.withLock { collected } }
    var sentHeaders: [(name: String, value: String)]? { lock.withLock { headersSent } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard followRedirects else {
            completionHandler(nil)
            return
        }
        if let from = response.url {
            network.cookies?.store(from: response, for: from)
        }
        var next = request
        if !explicitCookie, let jar = network.cookies, let url = next.url {
            next.setValue(jar.header(for: url), forHTTPHeaderField: "Cookie")
        }
        completionHandler(next)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            if !network.verifyTLS, let trust = space.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            if let credential = network.identity(forHost: space.host, port: space.port) {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        default:
            if space.isProxy(), let credential = network.proxyCredential, challenge.previousFailureCount == 0 {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad }) ?? metrics.transactionMetrics.last else { return }
        func span(_ start: Date?, _ end: Date?) -> Duration? {
            guard let start, let end, end >= start else { return nil }
            return .microseconds(Int64(end.timeIntervalSince(start) * 1_000_000))
        }
        var phases: [TimingPhase] = []
        if metrics.redirectCount > 0, let first = metrics.transactionMetrics.first?.fetchStartDate, let fetch = last.fetchStartDate,
           let redirects = span(first, fetch) {
            phases.append(TimingPhase(name: "Redirects", duration: redirects))
        }
        if let dns = span(last.domainLookupStartDate, last.domainLookupEndDate) {
            phases.append(TimingPhase(name: "DNS lookup", duration: dns))
        }
        if let connect = span(last.connectStartDate, last.secureConnectionStartDate ?? last.connectEndDate) {
            phases.append(TimingPhase(name: "TCP connect", duration: connect))
        }
        if let tls = span(last.secureConnectionStartDate, last.secureConnectionEndDate) {
            phases.append(TimingPhase(name: "TLS handshake", duration: tls))
        }
        if let send = span(last.requestStartDate, last.requestEndDate) {
            phases.append(TimingPhase(name: "Request sent", duration: send))
        }
        if let wait = span(last.requestEndDate, last.responseStartDate) {
            phases.append(TimingPhase(name: "Waiting (TTFB)", duration: wait))
        }
        if let download = span(last.responseStartDate, last.responseEndDate) {
            phases.append(TimingPhase(name: "Download", duration: download))
        }
        let sent = last.request.allHTTPHeaderFields.map { $0.map { ($0.key, $0.value) }.sorted { $0.0.lowercased() < $1.0.lowercased() } }
        lock.withLock {
            collected = phases
            headersSent = sent
        }
    }
}
