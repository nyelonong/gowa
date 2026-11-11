import Foundation
import Testing
@testable import gowa

@MainActor
@Test("websocket items round-trip and keep message variants and unknown keys")
func webSocketRoundTrip() {
    let doc = OpenCollectionDocument(root: ["items": [[
        "info": ["name": "Feed", "type": "websocket"],
        "websocket": [
            "url": "wss://x.test/feed",
            "message": [
                ["title": "hello", "selected": false, "message": ["type": "text", "data": "hi"]],
                ["title": "sub", "selected": true, "message": ["type": "json", "data": "{\"sub\":1}"]],
            ],
            "custom": "keep",
        ],
    ]]])
    var snapshot = doc.webSocketSnapshot(at: [0])!
    #expect(snapshot.message == "{\"sub\":1}")
    #expect(snapshot.authKind == .inherit)
    #expect(doc.enumerate()[0].kind == "websocket")
    #expect(doc.requestSnapshot(at: [0]) == nil)

    snapshot.message = "{\"sub\":2}"
    snapshot.headers = [OCHeader(name: "X", value: "1", disabled: false)]
    doc.updateWebSocket(at: [0], snapshot)
    let details = ((doc.root["items"] as? [[String: Any]])?[0]["websocket"] as? [String: Any])!
    #expect(details["custom"] as? String == "keep")
    #expect(((details["message"] as? [[String: Any]])?[0]["message"] as? [String: Any])?["data"] as? String == "hi")
    #expect(doc.webSocketSnapshot(at: [0])?.message == "{\"sub\":2}")
    #expect(doc.webSocketSnapshot(at: [0])?.headers.count == 1)
}

@MainActor
@Test("cookies for ws URLs are looked up under http(s)")
func webSocketCookieURL() {
    #expect(WebSocketConnection.httpURL(URL(string: "wss://x.test/a")!).absoluteString == "https://x.test/a")
    #expect(WebSocketConnection.httpURL(URL(string: "ws://x.test/a")!).absoluteString == "http://x.test/a")
}
