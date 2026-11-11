import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Network

/// Spec OAuth 2.0 auth (`type: oauth2`). Values may contain `{{variables}}`;
/// keep client secrets and passwords in secret environment variables.
struct OCOAuth2: Equatable, Sendable {
    enum Flow: String, CaseIterable, Sendable {
        case clientCredentials = "client_credentials"
        case password = "resource_owner_password_credentials"
        case authorizationCode = "authorization_code"
        case implicit = "implicit"

        var title: String {
            switch self {
            case .clientCredentials: "Client Credentials"
            case .password: "Password"
            case .authorizationCode: "Authorization Code"
            case .implicit: "Implicit"
            }
        }

        var usesBrowser: Bool { self == .authorizationCode || self == .implicit }
    }

    var flow: Flow = .clientCredentials
    var authorizationUrl = ""
    var accessTokenUrl = ""
    var refreshTokenUrl = ""
    var callbackUrl = "http://127.0.0.1:8765/callback"
    var clientId = ""
    var clientSecret = ""
    var credentialsPlacement = "basic_auth_header" // "basic_auth_header" | "body"
    var scope = ""
    var username = ""
    var password = ""
    var pkceEnabled = true
    var pkceMethod = "S256"
    var tokenHeader = "Authorization" // empty when the token goes in the query
    var tokenQuery = ""
    var tokenSource = "access_token" // "access_token" | "id_token"
    var tokenId = ""
    var autoFetch = true
    var autoRefresh = true

    init() {}

    init?(_ dict: [String: Any]) {
        guard let raw = dict["flow"] as? String, let flow = Flow(rawValue: raw) else { return nil }
        self.flow = flow
        authorizationUrl = dict["authorizationUrl"] as? String ?? ""
        accessTokenUrl = dict["accessTokenUrl"] as? String ?? ""
        refreshTokenUrl = dict["refreshTokenUrl"] as? String ?? ""
        callbackUrl = dict["callbackUrl"] as? String ?? callbackUrl
        let credentials = dict["credentials"] as? [String: Any] ?? [:]
        clientId = credentials["clientId"] as? String ?? ""
        clientSecret = credentials["clientSecret"] as? String ?? ""
        credentialsPlacement = credentials["placement"] as? String ?? credentialsPlacement
        scope = dict["scope"] as? String ?? ""
        let owner = dict["resourceOwner"] as? [String: Any] ?? [:]
        username = owner["username"] as? String ?? ""
        password = owner["password"] as? String ?? ""
        let pkce = dict["pkce"] as? [String: Any] ?? [:]
        pkceEnabled = !(pkce["disabled"] as? Bool ?? false)
        pkceMethod = pkce["method"] as? String ?? "S256"
        let tokenConfig = dict["tokenConfig"] as? [String: Any] ?? [:]
        tokenId = tokenConfig["id"] as? String ?? ""
        tokenSource = tokenConfig["source"] as? String ?? "access_token"
        if let placement = tokenConfig["placement"] as? [String: Any] {
            tokenHeader = placement["header"] as? String ?? ""
            tokenQuery = placement["query"] as? String ?? ""
        }
        let settings = dict["settings"] as? [String: Any] ?? [:]
        autoFetch = settings["autoFetchToken"] as? Bool ?? true
        autoRefresh = settings["autoRefreshToken"] as? Bool ?? true
    }

    /// Writes Gowa-edited keys over `existing`, keeping keys Gowa doesn't edit
    /// (such as `additionalParameters`).
    func dict(merging existing: [String: Any]) -> [String: Any] {
        var dict = existing["type"] as? String == "oauth2" ? existing : [:]
        for key in ["authorizationUrl", "refreshTokenUrl", "callbackUrl", "state", "pkce", "resourceOwner", "accessTokenUrl"] {
            dict.removeValue(forKey: key)
        }
        dict["type"] = "oauth2"
        dict["flow"] = flow.rawValue
        if flow != .implicit { dict["accessTokenUrl"] = accessTokenUrl }
        if flow.usesBrowser {
            dict["authorizationUrl"] = authorizationUrl
            dict["callbackUrl"] = callbackUrl
        }
        if !refreshTokenUrl.isEmpty, flow != .implicit { dict["refreshTokenUrl"] = refreshTokenUrl }
        var credentials: [String: Any] = ["clientId": clientId]
        if flow != .implicit {
            credentials["clientSecret"] = clientSecret
            credentials["placement"] = credentialsPlacement
        }
        dict["credentials"] = credentials
        dict["scope"] = scope
        if flow == .password { dict["resourceOwner"] = ["username": username, "password": password] }
        if flow == .authorizationCode { dict["pkce"] = ["disabled": !pkceEnabled, "method": pkceMethod] }
        var tokenConfig = dict["tokenConfig"] as? [String: Any] ?? [:]
        tokenConfig["placement"] = tokenQuery.isEmpty ? ["header": tokenHeader.isEmpty ? "Authorization" : tokenHeader] : ["query": tokenQuery]
        tokenConfig["source"] = tokenSource
        if !tokenId.isEmpty { tokenConfig["id"] = tokenId }
        dict["tokenConfig"] = tokenConfig
        dict["settings"] = ["autoFetchToken": autoFetch, "autoRefreshToken": autoRefresh]
        return dict
    }

    func interpolated(_ variables: [String: String]) -> OCOAuth2 {
        var copy = self
        let value = { OpenCollectionDocument.interpolate($0, variables) }
        copy.authorizationUrl = value(authorizationUrl)
        copy.accessTokenUrl = value(accessTokenUrl)
        copy.refreshTokenUrl = value(refreshTokenUrl)
        copy.callbackUrl = value(callbackUrl)
        copy.clientId = value(clientId)
        copy.clientSecret = value(clientSecret)
        copy.scope = value(scope)
        copy.username = value(username)
        copy.password = value(password)
        return copy
    }

    /// Keychain identity for the cached token: the spec token id, or the
    /// fields that decide which token a server issues.
    var cacheKey: String {
        if !tokenId.isEmpty { return "oauth2.\(tokenId)" }
        let identity = [flow.rawValue, accessTokenUrl, authorizationUrl, clientId, scope, username].joined(separator: "\n")
        return "oauth2." + SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

struct OAuth2Token: Codable, Equatable, Sendable {
    var accessToken: String
    var tokenType: String?
    var refreshToken: String?
    var idToken: String?
    var expiresAt: Date?
    var scope: String?

    func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.addingTimeInterval(-30) <= now
    }

    func value(source: String) -> String {
        source == "id_token" ? (idToken ?? accessToken) : accessToken
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> OAuth2Token {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Some servers answer form-encoded.
            let text = String(data: data, encoding: .utf8) ?? ""
            let fields = Dictionary(text.split(separator: "&").map { pair -> (String, String) in
                let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                return (parts[0], parts.count > 1 ? parts[1] : "")
            }, uniquingKeysWith: { first, _ in first })
            return try parse(fields: fields, now: now)
        }
        var fields: [String: String] = [:]
        for (key, value) in object {
            if let text = value as? String { fields[key] = text } else if let number = value as? NSNumber { fields[key] = number.stringValue }
        }
        return try parse(fields: fields, now: now)
    }

    static func parse(fields: [String: String], now: Date = Date()) throws -> OAuth2Token {
        if let error = fields["error"] {
            throw OAuth2Error.server(error, fields["error_description"])
        }
        guard let access = fields["access_token"], !access.isEmpty else {
            throw OAuth2Error.noAccessToken
        }
        return OAuth2Token(
            accessToken: access,
            tokenType: fields["token_type"],
            refreshToken: fields["refresh_token"],
            idToken: fields["id_token"],
            expiresAt: fields["expires_in"].flatMap(Double.init).map { now.addingTimeInterval($0) },
            scope: fields["scope"]
        )
    }
}

enum OAuth2Error: LocalizedError, Equatable {
    case missing(String)
    case server(String, String?)
    case noAccessToken
    case stateMismatch
    case authorizationDenied(String)
    case callbackTimedOut
    case callbackUnsupported(String)
    case cancelled
    case noToken

    var errorDescription: String? {
        switch self {
        case .missing(let field): "OAuth 2.0: \(field) is required"
        case .server(let code, let detail): "OAuth 2.0 server error: \(code)\(detail.map { " — \($0)" } ?? "")"
        case .noAccessToken: "OAuth 2.0: the token response had no access_token"
        case .stateMismatch: "OAuth 2.0: the callback's state didn't match; the response was ignored"
        case .authorizationDenied(let reason): "OAuth 2.0 authorization failed: \(reason)"
        case .callbackTimedOut: "OAuth 2.0: no browser callback within 5 minutes"
        case .callbackUnsupported(let url): "OAuth 2.0: can't listen for the callback \(url). Use http://127.0.0.1:<port>/path, an https URL, or a custom scheme."
        case .cancelled: "OAuth 2.0 sign-in was cancelled"
        case .noToken: "OAuth 2.0: no token yet. Open the Auth tab and choose Get New Token."
        }
    }
}

/// Fetches, caches (Keychain), and refreshes OAuth 2.0 tokens.
@MainActor
final class OAuth2Client {
    let accountPrefix: String

    init(collectionID: String) {
        accountPrefix = collectionID
    }

    func cachedToken(for config: OCOAuth2) -> OAuth2Token? {
        guard let text = Keychain.value(account: account(config)),
              let token = try? JSONDecoder().decode(OAuth2Token.self, from: Data(text.utf8))
        else { return nil }
        return token
    }

    func clear(_ config: OCOAuth2) {
        Keychain.removeValue(account: account(config))
    }

    /// A usable token: cached, refreshed, or newly fetched as the settings allow.
    func token(for config: OCOAuth2, interactive: Bool) async throws -> OAuth2Token {
        if let cached = cachedToken(for: config) {
            if !cached.isExpired() { return cached }
            if config.autoRefresh, let refresh = cached.refreshToken, !refresh.isEmpty,
               let refreshed = try? await self.refresh(config, refreshToken: refresh) {
                return refreshed
            }
        }
        guard config.autoFetch || interactive else { throw OAuth2Error.noToken }
        return try await fetch(config)
    }

    func fetch(_ config: OCOAuth2) async throws -> OAuth2Token {
        let token: OAuth2Token
        switch config.flow {
        case .clientCredentials:
            token = try await requestToken(config, fields: ["grant_type": "client_credentials"])
        case .password:
            guard !config.username.isEmpty else { throw OAuth2Error.missing("Username") }
            token = try await requestToken(config, fields: ["grant_type": "password", "username": config.username, "password": config.password])
        case .authorizationCode:
            token = try await authorizationCode(config)
        case .implicit:
            token = try await implicit(config)
        }
        save(token, for: config)
        return token
    }

    func refresh(_ config: OCOAuth2, refreshToken: String) async throws -> OAuth2Token {
        var token = try await requestToken(
            config,
            fields: ["grant_type": "refresh_token", "refresh_token": refreshToken],
            url: config.refreshTokenUrl.isEmpty ? config.accessTokenUrl : config.refreshTokenUrl
        )
        if token.refreshToken == nil { token.refreshToken = refreshToken }
        save(token, for: config)
        return token
    }

    private func account(_ config: OCOAuth2) -> String {
        "\(accountPrefix).\(config.cacheKey)"
    }

    private func save(_ token: OAuth2Token, for config: OCOAuth2) {
        guard let data = try? JSONEncoder().encode(token), let text = String(data: data, encoding: .utf8) else { return }
        Keychain.setValue(text, account: account(config))
    }

    // MARK: Token endpoint

    static func tokenRequest(_ config: OCOAuth2, fields: [String: String], url: String? = nil) throws -> URLRequest {
        let endpoint = url ?? config.accessTokenUrl
        guard let tokenURL = URL(string: endpoint), tokenURL.scheme?.hasPrefix("http") == true else {
            throw OAuth2Error.missing("Access token URL")
        }
        var fields = fields
        if !config.scope.isEmpty, fields["grant_type"] != "authorization_code" { fields["scope"] = config.scope }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if config.credentialsPlacement == "body" || config.clientSecret.isEmpty {
            fields["client_id"] = config.clientId
            if !config.clientSecret.isEmpty { fields["client_secret"] = config.clientSecret }
        } else {
            let encode = { ($0 as String).addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0 }
            let basic = Data("\(encode(config.clientId)):\(encode(config.clientSecret))".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        let pairs = fields.sorted { $0.key < $1.key }.map { EffectiveBody.KVPair(name: $0.key, value: $0.value) }
        request.httpBody = Data(EffectiveBody.urlEncoded(pairs).utf8)
        return request
    }

    private func requestToken(_ config: OCOAuth2, fields: [String: String], url: String? = nil) async throws -> OAuth2Token {
        let request = try Self.tokenRequest(config, fields: fields, url: url)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode),
           (try? OAuth2Token.parse(data)) == nil {
            let detail = String(data: data.prefix(300), encoding: .utf8)
            throw OAuth2Error.server("HTTP \(http.statusCode)", detail)
        }
        return try OAuth2Token.parse(data)
    }

    // MARK: Browser flows

    static func authorizationURL(_ config: OCOAuth2, responseType: String, state: String, challenge: String?) throws -> URL {
        guard var components = URLComponents(string: config.authorizationUrl), components.scheme?.hasPrefix("http") == true else {
            throw OAuth2Error.missing("Authorization URL")
        }
        guard !config.clientId.isEmpty else { throw OAuth2Error.missing("Client ID") }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "response_type", value: responseType))
        items.append(URLQueryItem(name: "client_id", value: config.clientId))
        items.append(URLQueryItem(name: "redirect_uri", value: config.callbackUrl))
        if !config.scope.isEmpty { items.append(URLQueryItem(name: "scope", value: config.scope)) }
        items.append(URLQueryItem(name: "state", value: state))
        if let challenge {
            items.append(URLQueryItem(name: "code_challenge", value: challenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: config.pkceMethod))
        }
        components.queryItems = items
        guard let url = components.url else { throw OAuth2Error.missing("Authorization URL") }
        return url
    }

    static func randomURLSafe(_ bytes: Int = 32) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func challenge(for verifier: String, method: String) -> String {
        method == "plain" ? verifier : base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private func authorizationCode(_ config: OCOAuth2) async throws -> OAuth2Token {
        let state = Self.randomURLSafe(16)
        let verifier = config.pkceEnabled ? Self.randomURLSafe(32) : nil
        let url = try Self.authorizationURL(
            config,
            responseType: "code",
            state: state,
            challenge: verifier.map { Self.challenge(for: $0, method: config.pkceMethod) }
        )
        let callback = try await BrowserCallback.capture(authorizationURL: url, callbackURL: config.callbackUrl)
        let fields = Self.callbackFields(callback)
        guard fields["state"] == state else { throw OAuth2Error.stateMismatch }
        if let error = fields["error"] { throw OAuth2Error.authorizationDenied(fields["error_description"] ?? error) }
        guard let code = fields["code"] else { throw OAuth2Error.authorizationDenied("no code in the callback") }
        var tokenFields = ["grant_type": "authorization_code", "code": code, "redirect_uri": config.callbackUrl]
        if let verifier { tokenFields["code_verifier"] = verifier }
        return try await requestToken(config, fields: tokenFields)
    }

    private func implicit(_ config: OCOAuth2) async throws -> OAuth2Token {
        let state = Self.randomURLSafe(16)
        let url = try Self.authorizationURL(config, responseType: "token", state: state, challenge: nil)
        if BrowserCallback.isLoopback(config.callbackUrl) {
            throw OAuth2Error.callbackUnsupported("\(config.callbackUrl) — the implicit flow returns the token in the URL fragment, which a loopback listener never receives")
        }
        let callback = try await BrowserCallback.capture(authorizationURL: url, callbackURL: config.callbackUrl)
        let fields = Self.callbackFields(callback)
        guard fields["state"] == state else { throw OAuth2Error.stateMismatch }
        if let error = fields["error"] { throw OAuth2Error.authorizationDenied(fields["error_description"] ?? error) }
        return try OAuth2Token.parse(fields: fields)
    }

    /// Query and fragment parameters of a callback URL.
    static func callbackFields(_ url: URL) -> [String: String] {
        var fields: [String: String] = [:]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        for item in components?.queryItems ?? [] { fields[item.name] = item.value ?? "" }
        if let fragment = components?.fragment {
            var fragmentComponents = URLComponents()
            fragmentComponents.query = fragment
            for item in fragmentComponents.queryItems ?? [] { fields[item.name] = item.value ?? "" }
        }
        return fields
    }
}

/// Opens the authorization page and waits for the redirect: a one-shot
/// loopback listener for `http://127.0.0.1:<port>/…` (or localhost), or an
/// ASWebAuthenticationSession for https and custom-scheme callbacks.
@MainActor
enum BrowserCallback {
    static func isLoopback(_ callback: String) -> Bool {
        guard let url = URL(string: callback), url.scheme == "http" else { return false }
        return ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? "")
    }

    static func capture(authorizationURL: URL, callbackURL: String) async throws -> URL {
        guard let callback = URL(string: callbackURL), let scheme = callback.scheme else {
            throw OAuth2Error.missing("Callback URL")
        }
        if isLoopback(callbackURL) {
            return try await LoopbackListener.capture(authorizationURL: authorizationURL, callback: callback)
        }
        let target: ASWebAuthenticationSession.Callback
        if scheme == "https", let host = callback.host {
            target = .https(host: host, path: callback.path.isEmpty ? "/" : callback.path)
        } else if scheme != "http" {
            target = .customScheme(scheme)
        } else {
            throw OAuth2Error.callbackUnsupported(callbackURL)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authorizationURL, callback: target) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: OAuth2Error.cancelled)
                } else {
                    continuation.resume(throwing: error ?? OAuth2Error.cancelled)
                }
            }
            session.presentationContextProvider = PresentationAnchor.shared
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
        static let shared = PresentationAnchor()
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
            MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
        }
    }
}

/// Accepts exactly one HTTP request on the callback port, answers it with a
/// short page, and hands back the full callback URL.
enum LoopbackListener {
    static func capture(authorizationURL: URL, callback: URL, timeout: Duration = .seconds(300)) async throws -> URL {
        guard let port = NWEndpoint.Port(rawValue: UInt16(callback.port ?? 80)) else {
            throw OAuth2Error.callbackUnsupported(callback.absoluteString)
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: port)
        let expectedPath = callback.path.isEmpty ? "/" : callback.path
        let box = ResumeOnce<URL>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                box.continuation = continuation
                if Task.isCancelled {
                    box.resume(.failure(OAuth2Error.cancelled))
                    return
                }
                listener.newConnectionHandler = { connection in
                    connection.start(queue: .global())
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
                        let requestLine = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                        let parts = requestLine.split(separator: " ")
                        let target = parts.count > 1 ? String(parts[1]) : ""
                        let full = URL(string: "http://127.0.0.1:\(port.rawValue)\(target)")
                        let matches = full.map { $0.path == expectedPath } ?? false
                        let page = matches
                            ? "<html><body style=\"font-family:-apple-system;padding:40px\"><h2>Signed in</h2><p>You can close this tab and return to Gowa.</p></body></html>"
                            : "<html><body>Not found</body></html>"
                        let response = "HTTP/1.1 \(matches ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                        if matches, let full {
                            listener.cancel()
                            box.resume(.success(full))
                        }
                    }
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        Task { @MainActor in NSWorkspace.shared.open(authorizationURL) }
                    case .failed(let error):
                        box.resume(.failure(error))
                    default:
                        break
                    }
                }
                listener.start(queue: .global())
                Task {
                    try? await Task.sleep(for: timeout)
                    listener.cancel()
                    box.resume(.failure(OAuth2Error.callbackTimedOut))
                }
            }
        } onCancel: {
            listener.cancel()
            box.resume(.failure(OAuth2Error.cancelled))
        }
    }
}

final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<Value, Error>?

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
