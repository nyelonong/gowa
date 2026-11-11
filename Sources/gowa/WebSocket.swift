import Foundation
import Observation

/// Spec `websocket` item: URL, headers, auth, and the message to send.
struct OCWebSocketSnapshot: Equatable, Sendable {
    var name: String
    var url: String
    var headers: [OCHeader] = []
    var authKind: OAuthKind = .inherit
    var messageType = "json" // "text" | "json" | "xml" | "binary"
    var message = ""
    var docs: String?

    /// The parts an HTTP upgrade request shares, for interpolation and auth.
    var upgradeRequest: OCRequestSnapshot {
        OCRequestSnapshot(
            name: name, method: "GET", url: url, params: [], headers: headers,
            bodyType: nil, bodyData: "", authKind: authKind,
            settings: OCSettings(followRedirects: nil, timeout: nil), docs: nil
        )
    }
}

extension OpenCollectionDocument {
    func webSocketSnapshot(at path: NodePath) -> OCWebSocketSnapshot? {
        guard let item = item(at: path), let details = item["websocket"] as? [String: Any] else { return nil }
        let info = item["info"] as? [String: Any] ?? [:]
        let message = Self.selectedVariant(details["message"], key: "message") ?? [:]
        return OCWebSocketSnapshot(
            name: info["name"] as? String ?? "Untitled",
            url: details["url"] as? String ?? "",
            headers: (details["headers"] as? [[String: Any]] ?? []).map {
                OCHeader(name: $0["name"] as? String ?? "", value: $0["value"] as? String ?? "", disabled: $0["disabled"] as? Bool ?? false)
            },
            authKind: (details["auth"] as? [String: Any]).map(readAuthDict) ?? .inherit,
            messageType: message["type"] as? String ?? "json",
            message: message["data"] as? String ?? "",
            docs: Self.readDocs(item["docs"])
        )
    }

    func updateWebSocket(at path: NodePath, _ snapshot: OCWebSocketSnapshot) {
        guard var item = item(at: path) else { return }
        var info = item["info"] as? [String: Any] ?? [:]
        info["name"] = snapshot.name
        info["type"] = "websocket"
        item["info"] = info
        item["websocket"] = Self.webSocketDetails(snapshot, existing: item["websocket"] as? [String: Any] ?? [:], authDict: authDict)
        if let docs = snapshot.docs, !docs.isEmpty { item["docs"] = docs } else { item.removeValue(forKey: "docs") }
        write(item, at: path)
    }

    func addWebSocket(under parent: NodePath?, _ snapshot: OCWebSocketSnapshot) -> NodePath {
        append([
            "info": ["name": snapshot.name, "type": "websocket"],
            "websocket": Self.webSocketDetails(snapshot, existing: [:], authDict: authDict),
        ], under: parent)
    }

    private static func webSocketDetails(
        _ snapshot: OCWebSocketSnapshot,
        existing: [String: Any],
        authDict: (OAuthKind, [String: Any]?) -> [String: Any]?
    ) -> [String: Any] {
        var details = existing
        details["url"] = snapshot.url
        if snapshot.headers.isEmpty {
            details.removeValue(forKey: "headers")
        } else {
            details["headers"] = snapshot.headers.map { ["name": $0.name, "value": $0.value, "disabled": $0.disabled] }
        }
        let message: [String: Any] = ["type": snapshot.messageType, "data": snapshot.message]
        if var variants = details["message"] as? [[String: Any]], !variants.isEmpty {
            let index = variants.firstIndex { $0["selected"] as? Bool == true } ?? 0
            variants[index]["message"] = message
            details["message"] = variants
        } else {
            details["message"] = message
        }
        if let auth = authDict(snapshot.authKind, details["auth"] as? [String: Any]) { details["auth"] = auth }
        return details
    }
}

struct WebSocketMessage: Identifiable, Sendable, Equatable {
    enum Direction: Sendable { case sent, received, info, error }

    var id = UUID()
    var direction: Direction
    var text: String
    var byteCount: Int
    var isBinary = false
    var at = Date()
}

/// One live WebSocket connection, owned by AppState and closed when the
/// selection or collection changes.
@MainActor
@Observable
final class WebSocketConnection {
    enum State: Equatable {
        case idle, connecting, open
        case closed(String)
    }

    private(set) var state: State = .idle
    private(set) var messages: [WebSocketMessage] = []
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    static let messageLimit = 2000

    var isOpen: Bool { state == .open }

    func connect(url: URL, headers: [(name: String, value: String)], network: NetworkOptions, timeout: TimeInterval) {
        disconnect(reason: nil)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (name, value) in headers where !name.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let jar = network.cookies, request.value(forHTTPHeaderField: "Cookie") == nil, let cookie = jar.header(for: Self.httpURL(url)) {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        if let proxy = network.proxyDictionary { config.connectionProxyDictionary = proxy }
        let delegate = WebSocketDelegate(network: network) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 << 20
        self.session = session
        self.task = task
        state = .connecting
        append(.init(direction: .info, text: "Connecting to \(url.absoluteString)…", byteCount: 0))
        task.resume()
        receiveLoop = Task { [weak self] in await self?.receive(on: task) }
    }

    func send(_ text: String, binary: Bool) {
        guard let task, state == .open else { return }
        let message: URLSessionWebSocketTask.Message
        var byteCount = text.utf8.count
        if binary {
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                append(.init(direction: .error, text: "Binary messages are written as base64; this isn't valid base64.", byteCount: 0))
                return
            }
            message = .data(data)
            byteCount = data.count
        } else {
            message = .string(text)
        }
        append(.init(direction: .sent, text: binary ? "<\(byteCount) bytes>" : text, byteCount: byteCount, isBinary: binary))
        task.send(message) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.append(.init(direction: .error, text: "Send failed: \(error.localizedDescription)", byteCount: 0)) }
        }
    }

    func disconnect(reason: String? = "Disconnected") {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if let reason, state != .idle, !(state.isClosed) {
            state = .closed(reason)
            append(.init(direction: .info, text: reason, byteCount: 0))
        }
    }

    func clear() {
        messages.removeAll()
    }

    private func receive(on task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard self.task === task else { return }
                switch message {
                case .string(let text):
                    append(.init(direction: .received, text: text, byteCount: text.utf8.count))
                case .data(let data):
                    let text = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
                    append(.init(direction: .received, text: text, byteCount: data.count, isBinary: true))
                @unknown default:
                    break
                }
            } catch {
                guard self.task === task else { return }
                if state != .idle, !state.isClosed {
                    let reason = task.closeCode == .invalid ? error.localizedDescription : Self.describe(task.closeCode, task.closeReason)
                    state = .closed(reason)
                    append(.init(direction: task.closeCode == .invalid ? .error : .info, text: reason, byteCount: 0))
                }
                return
            }
        }
    }

    private func handle(_ event: WebSocketDelegate.Event) {
        switch event {
        case .opened(let proto):
            guard state == .connecting else { return }
            state = .open
            append(.init(direction: .info, text: "Connected" + (proto.map { " (protocol \($0))" } ?? ""), byteCount: 0))
        case .closed(let code, let reason):
            guard !state.isClosed else { return }
            let text = Self.describe(code, reason)
            state = .closed(text)
            append(.init(direction: .info, text: text, byteCount: 0))
        }
    }

    private func append(_ message: WebSocketMessage) {
        messages.append(message)
        if messages.count > Self.messageLimit { messages.removeFirst(messages.count - Self.messageLimit) }
    }

    static func describe(_ code: URLSessionWebSocketTask.CloseCode, _ reason: Data?) -> String {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
        return "Closed (\(code.rawValue))" + (text.map { ": \($0)" } ?? "")
    }

    /// Cookies are stored against http(s) URLs.
    static func httpURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = url.scheme == "wss" ? "https" : "http"
        return components?.url ?? url
    }
}

extension WebSocketConnection.State {
    var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }
}

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum Event {
        case opened(String?)
        case closed(URLSessionWebSocketTask.CloseCode, Data?)
    }

    let network: NetworkOptions
    let onEvent: @Sendable (Event) -> Void

    init(network: NetworkOptions, onEvent: @escaping @Sendable (Event) -> Void) {
        self.network = network
        self.onEvent = onEvent
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onEvent(.opened(`protocol`))
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onEvent(.closed(closeCode, reason))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust where !network.verifyTLS:
            completionHandler(.useCredential, space.serverTrust.map(URLCredential.init(trust:)))
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
}
