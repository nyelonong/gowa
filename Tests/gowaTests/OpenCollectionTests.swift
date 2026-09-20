import Foundation
import Testing
@testable import gowa

@MainActor
@Test("sample collection round-trips through YAML")
func roundTrip() throws {
    let doc = OpenCollectionDocument.sample()
    let path = doc.addRequest(under: nil, snapshot: OCRequestSnapshot(
        name: "Get Orders",
        method: "GET",
        url: "{{baseUrl}}/orders",
        params: [OCParam(name: "limit", value: "10", kind: "query", disabled: false)],
        headers: [OCHeader(name: "Accept", value: "application/json", disabled: false)],
        bodyType: nil,
        bodyData: "",
        authKind: .bearer(token: "{{token}}"),
        settings: OCSettings(followRedirects: true, timeout: nil),
        docs: "Lists orders"
    ))
    let folderPath = doc.addFolder(under: nil, name: "Users")
    _ = doc.addRequest(under: folderPath, snapshot: OCRequestSnapshot(
        name: "Create User",
        method: "POST",
        url: "{{baseUrl}}/users",
        params: [],
        headers: [],
        bodyType: "json",
        bodyData: "{\"name\": \"Zaki\"}",
        authKind: .basic(username: "u", password: "p"),
        settings: OCSettings(followRedirects: nil, timeout: nil),
        docs: nil
    ))
    doc.environments = [
        OCEnvironmentSnapshot(name: "Production", variables: [
            OCVariable(name: "baseUrl", value: "https://echo.usebruno.com", secret: false, disabled: false),
            OCVariable(name: "token", value: "s3cret", secret: true, disabled: false),
        ])
    ]

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gowa-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("collection.yml")
    try doc.save(to: file)

    let loaded = try OpenCollectionDocument.load(from: file)
    #expect(loaded.name == "Sample Collection")
    #expect(loaded.root["opencollection"] as? String == "1.0.0")

    let nodes = loaded.enumerate()
    #expect(nodes.count == 3)
    #expect(nodes[0].name == "Get Orders" && !nodes[0].isFolder)
    #expect(nodes[1].name == "Users" && nodes[1].isFolder)
    #expect(nodes[2].name == "Create User")

    let snapshot = loaded.requestSnapshot(at: path)
    #expect(snapshot != nil)
    #expect(snapshot?.url == "{{baseUrl}}/orders")
    #expect(snapshot?.params == [OCParam(name: "limit", value: "10", kind: "query", disabled: false)])
    #expect(snapshot?.authKind == .bearer(token: "{{token}}"))
    #expect(snapshot?.settings.followRedirects == true)
    #expect(snapshot?.docs == "Lists orders")

    let userSnapshot = loaded.requestSnapshot(at: nodes[2].path)
    #expect(userSnapshot?.bodyType == "json")
    #expect(userSnapshot?.bodyData == "{\"name\": \"Zaki\"}")
    #expect(userSnapshot?.authKind == .basic(username: "u", password: "p"))

    #expect(loaded.environments.count == 1)
    #expect(loaded.environments[0].variables.first(where: { $0.name == "token" })?.secret == true)
    #expect(loaded.environments[0].variables.first(where: { $0.name == "baseUrl" })?.value == "https://echo.usebruno.com")
}

@MainActor
@Test("mutations: rename, duplicate, delete preserve siblings")
func mutations() throws {
    let doc = OpenCollectionDocument.sample()
    _ = doc.addRequest(under: nil, snapshot: sampleRequest("A"))
    let folder = doc.addFolder(under: nil, name: "Group")
    _ = doc.addRequest(under: folder, snapshot: sampleRequest("B1"))
    _ = doc.addRequest(under: folder, snapshot: sampleRequest("B2"))

    doc.rename(at: [0], to: "A renamed")
    #expect(doc.enumerate()[0].name == "A renamed")

    doc.duplicate(at: [1, 0])
    let names = doc.enumerate().map(\.name)
    #expect(names == ["A renamed", "Group", "B1", "B1", "B2"])

    doc.delete(at: [1, 1])
    #expect(doc.enumerate().map(\.name) == ["A renamed", "Group", "B1", "B2"])
}

@MainActor
@Test("unknown spec sections survive a round-trip")
func preservation() throws {
    let yaml = """
    opencollection: "1.0.0"
    info:
      name: Preserved
    items:
      - info:
          name: Get
          type: http
          seq: 1
        http:
          method: GET
          url: https://example.com
          auth:
            type: oauth2
            grantType: client_credentials
            accessTokenUrl: https://auth.example.com/token
        docs: Original docs
    extensions:
      custom: keep me
    """
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gowa-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("collection.yml")
    try yaml.write(to: file, atomically: true, encoding: .utf8)

    let doc = try OpenCollectionDocument.load(from: file)
    let path: NodePath = [0]
    var snapshot = try #require(doc.requestSnapshot(at: path))
    #expect(snapshot.authKind == .preserved)

    snapshot.url = "https://example.com/changed"
    doc.updateRequest(at: path, snapshot: snapshot)
    try doc.save(to: file)

    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("oauth2"))
    #expect(text.contains("accessTokenUrl"))
    #expect(text.contains("client_credentials"))
    #expect(text.contains("https://example.com/changed"))
    #expect(text.contains("Original docs"))
    #expect(text.contains("keep me"))
}

@Test("interpolation replaces known variables only")
func interpolation() {
    let out = OpenCollectionDocument.interpolate(
        "{{baseUrl}}/users/{{userId}}?missing={{nope}}",
        ["baseUrl": "https://api.test", "userId": "42"]
    )
    #expect(out == "https://api.test/users/42?missing={{nope}}")
}

private func sampleRequest(_ name: String) -> OCRequestSnapshot {
    OCRequestSnapshot(
        name: name,
        method: "GET",
        url: "https://example.com",
        params: [],
        headers: [],
        bodyType: nil,
        bodyData: "",
        authKind: .none,
        settings: OCSettings(followRedirects: nil, timeout: nil),
        docs: nil
    )
}
