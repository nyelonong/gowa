import Foundation

/// Per-collection cookies. Gowa sets the `Cookie` header itself (instead of
/// URLSession's shared store) so collections never leak cookies into each
/// other and every stored cookie can be shown and deleted.
final class CookieJar: @unchecked Sendable {
    private let lock = NSLock()
    private var cookies: [HTTPCookie] = []
    private let fileURL: URL?
    var onChange: (@Sendable () -> Void)?

    /// `fileURL` nil keeps cookies in memory only (the CLI, unsaved collections).
    init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    static func forCollection(id: String) -> CookieJar {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("Gowa/cookies", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let safeID = id.replacingOccurrences(of: "/", with: "_")
        return CookieJar(fileURL: dir?.appendingPathComponent("\(safeID).json"))
    }

    var all: [HTTPCookie] {
        lock.withLock { pruneExpired(); return cookies }
    }

    /// The `Cookie` header value for a request URL, or nil when nothing matches.
    func header(for url: URL) -> String? {
        let matching = lock.withLock {
            pruneExpired()
            return cookies.filter { Self.matches($0, url: url) }
                .sorted { $0.path.count > $1.path.count }
        }
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func store(from response: HTTPURLResponse, for url: URL) {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let name = entry.key as? String, let value = entry.value as? String { result[name] = value }
        }
        let received = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !received.isEmpty else { return }
        lock.withLock {
            for cookie in received {
                cookies.removeAll { Self.sameIdentity($0, cookie) }
                if let expires = cookie.expiresDate, expires <= Date() { continue }
                cookies.append(cookie)
            }
        }
        changed()
    }

    func delete(_ cookie: HTTPCookie) {
        lock.withLock { cookies.removeAll { Self.sameIdentity($0, cookie) } }
        changed()
    }

    func deleteAll(domain: String? = nil) {
        lock.withLock {
            if let domain {
                cookies.removeAll { $0.domain == domain }
            } else {
                cookies.removeAll()
            }
        }
        changed()
    }

    static func matches(_ cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        if let expires = cookie.expiresDate, expires <= Date() { return false }
        let domain = cookie.domain.lowercased()
        let domainMatches = domain.hasPrefix(".")
            ? host == String(domain.dropFirst()) || host.hasSuffix(domain)
            : host == domain
        guard domainMatches else { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        return requestPath == cookiePath
            || (requestPath.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).hasPrefix("/")))
    }

    private static func sameIdentity(_ a: HTTPCookie, _ b: HTTPCookie) -> Bool {
        a.name == b.name && a.domain.lowercased() == b.domain.lowercased() && a.path == b.path
    }

    private func pruneExpired() {
        let now = Date()
        cookies.removeAll { $0.expiresDate.map { $0 <= now } ?? false }
    }

    private func changed() {
        save()
        onChange?()
    }

    // MARK: Persistence

    /// Only cookies with an expiry date persist; session cookies end with the app.
    private struct Stored: Codable {
        var name, value, domain, path: String
        var expires: Date
        var secure, httpOnly: Bool
        var sameSite: String?
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Stored].self, from: data)
        else { return }
        cookies = stored.compactMap { entry in
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: entry.name, .value: entry.value, .domain: entry.domain,
                .path: entry.path, .expires: entry.expires,
            ]
            if entry.secure { properties[.secure] = "TRUE" }
            if entry.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite = entry.sameSite { properties[.sameSitePolicy] = sameSite }
            return HTTPCookie(properties: properties)
        }
        pruneExpired()
    }

    private func save() {
        guard let fileURL else { return }
        let stored = lock.withLock {
            cookies.compactMap { cookie -> Stored? in
                guard let expires = cookie.expiresDate else { return nil }
                return Stored(
                    name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                    expires: expires, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly,
                    sameSite: cookie.sameSitePolicy?.rawValue
                )
            }
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
