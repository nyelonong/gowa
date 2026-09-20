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

struct HTTPResult: Sendable {
    let url: URL
    let status: Int
    let headers: [(name: String, value: String)]
    let body: Data
    let elapsed: Duration
    let finalURL: URL

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
    var timeoutSeconds = 30

    func send(
        method: HTTPMethod,
        urlText: String,
        body: String,
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
        request.httpMethod = method.rawValue
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        for (name, value) in headers where !name.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if method.carriesBody, !body.isEmpty {
            request.httpBody = Data(body.utf8)
        }

        let usesSharedSession = followRedirects
        let session: URLSession
        if usesSharedSession {
            session = URLSession.shared
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = request.timeoutInterval
            let delegate = NoRedirectDelegate()
            session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        }
        defer { if !usesSharedSession { session.finishTasksAndInvalidate() } }

        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await session.data(for: request)
        let elapsed = start.duration(to: clock.now)

        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.invalidURL("no HTTP response")
        }

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
            finalURL: http.url ?? url
        )
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
