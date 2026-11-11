import Foundation
import Testing
@testable import gowa

private func snapshot(_ type: String, method: String = "POST") -> OCRequestSnapshot {
    OCRequestSnapshot(
        name: "Body", method: method, url: "https://x.test", params: [], headers: [],
        bodyType: type, bodyData: "", authKind: .none,
        settings: OCSettings(followRedirects: nil, timeout: nil), docs: nil
    )
}

@MainActor
@Test("form fields encode as application/x-www-form-urlencoded with variables")
func formBodyEncoding() throws {
    var request = snapshot("form-urlencoded")
    request.formFields = [
        OCFormField(name: "q", value: "a b&{{who}}"),
        OCFormField(name: "off", value: "1", disabled: true),
    ]
    let payload = AppState.effectivePayload(from: request, variables: ["who": "me"], baseDirectory: nil)
    let encoded = try payload.encoded()
    #expect(String(data: encoded.data!, encoding: .utf8) == "q=a%20b%26me")
    #expect(encoded.contentType == "application/x-www-form-urlencoded")
}

@MainActor
@Test("multipart parts carry text and file bytes with a boundary")
func multipartBodyEncoding() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("hello".utf8).write(to: dir.appendingPathComponent("note.txt"))

    var request = snapshot("multipart-form")
    request.formFields = [
        OCFormField(name: "caption", value: "hi"),
        OCFormField(name: "doc", value: "note.txt", kind: "file"),
    ]
    let payload = AppState.effectivePayload(from: request, variables: [:], baseDirectory: dir)
    let encoded = try payload.encoded(boundary: "B")
    let text = String(data: encoded.data!, encoding: .utf8)!
    #expect(encoded.contentType == "multipart/form-data; boundary=B")
    #expect(text == "--B\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\nhi\r\n"
        + "--B\r\nContent-Disposition: form-data; name=\"doc\"; filename=\"note.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n"
        + "--B--\r\n")
}

@MainActor
@Test("a missing body file fails with its path")
func missingBodyFile() {
    var request = snapshot("file")
    request.filePath = "/nonexistent/gowa-test.bin"
    let payload = AppState.effectivePayload(from: request, variables: [:], baseDirectory: nil)
    #expect { try payload.encoded() } throws: { ($0 as? RequestBodyError) == .unreadableFile("/nonexistent/gowa-test.bin") }
}

@MainActor
@Test("GraphQL sends query and parsed variables as JSON, even with GET")
func graphqlPayload() throws {
    var request = snapshot("graphql", method: "GET")
    request.bodyData = "query { user(id: $id) { name } }"
    request.graphqlVariables = #"{"id": "{{id}}"}"#
    let payload = AppState.effectivePayload(from: request, variables: ["id": "7"], baseDirectory: nil)
    guard case .text(let json, let contentType) = payload else { Issue.record("expected text"); return }
    #expect(contentType == "application/json")
    #expect(json == #"{"query":"query { user(id: $id) { name } }","variables":{"id":"7"}}"#)
}

@MainActor
@Test("GraphQL requests save as graphql items and settings sit beside the protocol block")
func graphqlItemRoundTrip() {
    let doc = OpenCollectionDocument(root: ["items": []])
    var request = snapshot("json")
    request.settings.timeout = 5000
    let path = doc.addRequest(under: nil, snapshot: request)
    #expect((doc.root["items"] as? [[String: Any]])?[0]["settings"] as? [String: Int] == ["timeout": 5000])

    request.bodyType = "graphql"
    request.bodyData = "{ me { id } }"
    doc.updateRequest(at: path, snapshot: request)
    let item = (doc.root["items"] as? [[String: Any]])![0]
    #expect(item["http"] == nil)
    #expect((item["info"] as? [String: Any])?["type"] as? String == "graphql")
    #expect(((item["graphql"] as? [String: Any])?["body"] as? [String: Any])?["query"] as? String == "{ me { id } }")
    #expect(doc.requestSnapshot(at: path)?.isGraphQL == true)
    #expect(doc.requestSnapshot(at: path)?.settings.timeout == 5000)
    #expect(doc.enumerate()[0].kind == "graphql")
}

@MainActor
@Test("legacy string form data and http.settings still load")
func legacyBodyAndSettingsLoad() {
    let doc = OpenCollectionDocument(root: ["items": [[
        "info": ["name": "Old", "type": "http"],
        "http": [
            "method": "POST", "url": "https://x.test",
            "body": ["type": "form-urlencoded", "data": "a=1&b=two+words"],
            "settings": ["followRedirects": false],
        ],
    ]]])
    let request = doc.requestSnapshot(at: [0])
    #expect(request?.formFields == [OCFormField(name: "a", value: "1"), OCFormField(name: "b", value: "two words")])
    #expect(request?.settings.followRedirects == false)
}
