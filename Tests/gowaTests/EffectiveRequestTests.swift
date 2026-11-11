import Foundation
import Testing
@testable import gowa

@MainActor
@Test("effective request interpolates and folds query params")
func effectiveRequest() {
    let snapshot = OCRequestSnapshot(
        name: "Get Orders",
        method: "GET",
        url: "{{baseUrl}}/orders",
        params: [
            OCParam(name: "limit", value: "{{limit}}", kind: "query", disabled: false),
            OCParam(name: "secret", value: "{{apiKey}}", kind: "query", disabled: true),
            OCParam(name: "", value: "ignored", kind: "query", disabled: false),
        ],
        headers: [
            OCHeader(name: "Accept", value: "application/json", disabled: false),
            OCHeader(name: "X-Drop", value: "me", disabled: true),
        ],
        bodyType: nil,
        bodyData: "",
        authKind: .none,
        settings: OCSettings(followRedirects: false, timeout: nil),
        docs: nil
    )

    let effective = AppState.effectiveRequest(
        from: snapshot,
        variables: ["baseUrl": "https://api.test", "limit": "5", "apiKey": "k"]
    )

    #expect(effective.url == "https://api.test/orders?limit=5")
    #expect(effective.headers.count == 1)
    #expect(effective.headers[0].name == "Accept" && effective.headers[0].value == "application/json")
    #expect(effective.body == "")
    #expect(!effective.followRedirects)
}

@MainActor
@Test("auth kinds apply at send time")
func authKinds() {
    let base = OCRequestSnapshot(
        name: "r",
        method: "GET",
        url: "https://api.test",
        params: [],
        headers: [],
        bodyType: nil,
        bodyData: "",
        authKind: .none,
        settings: OCSettings(followRedirects: nil, timeout: nil),
        docs: nil
    )

    var snapshot = base
    snapshot.authKind = .basic(username: "u", password: "p")
    var effective = AppState.effectiveRequest(from: snapshot, variables: [:])
    let expectedBasic = Data("u:p".utf8).base64EncodedString()
    #expect(effective.headers.contains { $0.name == "Authorization" && $0.value == "Basic \(expectedBasic)" })

    snapshot.authKind = .bearer(token: "{{token}}")
    effective = AppState.effectiveRequest(from: snapshot, variables: ["token": "abc"])
    #expect(effective.headers.contains { $0.name == "Authorization" && $0.value == "Bearer abc" })

    snapshot.authKind = .apiKey(key: "X-Key", value: "v", placement: "header")
    effective = AppState.effectiveRequest(from: snapshot, variables: [:])
    #expect(effective.headers.contains { $0.name == "X-Key" && $0.value == "v" })

    snapshot.authKind = .apiKey(key: "key", value: "v", placement: "query")
    effective = AppState.effectiveRequest(from: snapshot, variables: [:])
    #expect(!effective.headers.contains { $0.name == "key" })
    #expect(effective.url.contains("key=v"))
}

@MainActor
@Test("body methods interpolate body; GET drops it")
func bodyInterpolation() {
    var snapshot = OCRequestSnapshot(
        name: "r",
        method: "POST",
        url: "https://api.test",
        params: [],
        headers: [],
        bodyType: "json",
        bodyData: "{\"token\": \"{{token}}\"}",
        authKind: .none,
        settings: OCSettings(followRedirects: nil, timeout: nil),
        docs: nil
    )
    let effective = AppState.effectiveRequest(from: snapshot, variables: ["token": "t1"])
    #expect(effective.body == "{\"token\": \"t1\"}")

    snapshot.method = "GET"
    let get = AppState.effectiveRequest(from: snapshot, variables: ["token": "t1"])
    #expect(get.body == "")
}

@MainActor
@Test("path params fill :name segments and leave the port and unset params alone")
func pathParams() {
    let snapshot = OCRequestSnapshot(
        name: "r",
        method: "GET",
        url: "{{baseUrl}}/accounts/:account/objects/:level/:id?expand=1",
        params: [
            OCParam(name: "account", value: "{{account}}", kind: "path", disabled: false),
            OCParam(name: "level", value: "ad set", kind: "path", disabled: false),
            OCParam(name: "id", value: "", kind: "path", disabled: false),
            OCParam(name: "unused", value: "x", kind: "path", disabled: true),
        ],
        headers: [],
        bodyType: nil,
        bodyData: "",
        authKind: .none,
        settings: OCSettings(followRedirects: nil, timeout: nil),
        docs: nil
    )

    let effective = AppState.effectiveRequest(
        from: snapshot,
        variables: ["baseUrl": "http://localhost:3000", "account": "act_1/2"]
    )

    #expect(effective.url == "http://localhost:3000/accounts/act_1%2F2/objects/ad%20set/:id?expand=1")
}

@MainActor
@Test("document effective request folds in folder auth and headers")
func documentEffectiveRequestInherits() throws {
    let doc = OpenCollectionDocument.sample()
    let folder = doc.addFolder(under: nil, name: "Dashboard")
    var items = try #require(doc.root["items"] as? [[String: Any]])
    items[folder[0]]["request"] = [
        "auth": ["type": "bearer", "token": "{{token}}"],
        "headers": [["name": "Access_token", "value": "{{token}}"]],
    ]
    doc.root["items"] = items
    let path = doc.addRequest(under: folder, snapshot: OCRequestSnapshot(
        name: "Stats",
        method: "GET",
        url: "https://api.test/stats",
        params: [],
        headers: [],
        bodyType: nil,
        bodyData: "",
        authKind: .inherit,
        settings: OCSettings(followRedirects: nil, timeout: nil),
        docs: nil
    ))
    let snapshot = try #require(doc.requestSnapshot(at: path))

    let effective = doc.effectiveRequest(at: path, from: snapshot, variables: ["token": "t"])

    #expect(effective.headers.contains { $0.name == "Access_token" && $0.value == "t" })
    #expect(effective.headers.contains { $0.name == "Authorization" && $0.value == "Bearer t" })
}
