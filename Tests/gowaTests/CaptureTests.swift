import Foundation
import Testing
@testable import gowa

@MainActor
@Test("capture expressions evaluate JSON paths")
func evaluateCapture() throws {
    let body = Data(#"{"access_token": "eyJhbGci", "data": {"user": {"id": 42, "active": true}}, "items": ["a", "b"]}"#.utf8)

    #expect(OpenCollectionDocument.evaluateCapture("$.access_token", body: body) == "eyJhbGci")
    #expect(OpenCollectionDocument.evaluateCapture("$.data.user.id", body: body) == "42")
    #expect(OpenCollectionDocument.evaluateCapture("$.data.user.active", body: body) == "true")
    #expect(OpenCollectionDocument.evaluateCapture("$.items[1]", body: body) == "b")
    #expect(OpenCollectionDocument.evaluateCapture("$.items[0]", body: body) == "a")
    #expect(OpenCollectionDocument.evaluateCapture("$.missing.path", body: body) == nil)
    #expect(OpenCollectionDocument.evaluateCapture("not-json-path", body: body) == nil)
    #expect(OpenCollectionDocument.evaluateCapture("$.access_token", body: Data("not json".utf8)) == nil)
}

@MainActor
@Test("captures round-trip through YAML in spec shape")
func capturesRoundTrip() throws {
    let doc = OpenCollectionDocument.sample()
    _ = doc.addRequest(under: nil, snapshot: OCRequestSnapshot(
        name: "Login",
        method: "POST",
        url: "{{baseUrl}}/oauth/token",
        params: [],
        headers: [],
        bodyType: "json",
        bodyData: "{}",
        authKind: .none,
        settings: OCSettings(followRedirects: nil, timeout: nil),
        captures: [
            OCCapture(variableName: "token", expression: "$.access_token", scope: "runtime", disabled: false),
            OCCapture(variableName: "accountId", expression: "$.account_id", scope: "environment", disabled: false),
        ],
        docs: nil
    ))

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gowa-capture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("collection.yml")
    try doc.save(to: file)

    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("set-variable"))
    #expect(text.contains("jsonq"))
    #expect(text.contains("$.access_token"))
    #expect(text.contains("after-response"))
    #expect(text.contains("runtime"))

    let loaded = try OpenCollectionDocument.load(from: file)
    let snapshot = try #require(loaded.requestSnapshot(at: [0]))
    #expect(snapshot.captures.count == 2)
    #expect(snapshot.captures[0] == OCCapture(variableName: "token", expression: "$.access_token", scope: "runtime", disabled: false))
    #expect(snapshot.captures[1].scope == "environment")
}

@MainActor
@Test("captures edit without losing other runtime sections")
func capturesPreserveRuntime() throws {
    let yaml = """
    opencollection: "1.0.0"
    info:
      name: Preserved
    items:
      - info:
          name: Login
          type: http
        http:
          method: POST
          url: https://api.test/login
        runtime:
          variables:
          - name: attempt
            value: "1"
          scripts:
          - type: after-response
            script: console.log("done")
          actions:
          - type: set-variable
            phase: before-request
            selector:
              method: jsonq
              expression: $.now
            variable:
              name: startedAt
              scope: runtime
          assertions:
          - expression: res.status
            operator: eq
            value: "200"
    """
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gowa-cap-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("collection.yml")
    try yaml.write(to: file, atomically: true, encoding: .utf8)

    let doc = try OpenCollectionDocument.load(from: file)
    var snapshot = try #require(doc.requestSnapshot(at: [0]))
    #expect(snapshot.captures.isEmpty) // before-request action preserved but not executed

    snapshot.captures.append(OCCapture(variableName: "token", expression: "$.access_token", scope: "runtime", disabled: false))
    doc.updateRequest(at: [0], snapshot: snapshot)
    try doc.save(to: file)

    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("before-request")) // the preserved action survived
    #expect(text.contains("console.log")) // scripts intact
    #expect(text.contains("res.status")) // assertions intact
    #expect(text.contains("attempt")) // runtime variables intact
    #expect(text.contains("$.access_token")) // new capture written

    let reloaded = try OpenCollectionDocument.load(from: file)
    let final = try #require(reloaded.requestSnapshot(at: [0]))
    #expect(final.captures.count == 1) // before-request action still not a Gowa capture
}

@Test("session variables override environment values in interpolation")
func sessionPrecedence() {
    let merged = ["token": "env-value"].merging(["token": "session-token"]) { _, new in new }
    #expect(merged["token"] == "session-token")
}

@MainActor
@Test("assertion operators evaluate against responses")
func assertionEvaluation() throws {
    let body = Data(#"{"token": "abc123", "user": {"id": 7}}"#.utf8)
    let headers: [(name: String, value: String)] = [("Content-Type", "application/json")]
    let result = HTTPResult(
        url: URL(string: "https://api.test")!,
        status: 200,
        headers: headers,
        body: body,
        elapsed: .milliseconds(120),
        finalURL: URL(string: "https://api.test")!
    )

    func check(_ expression: String, _ op: String, _ value: String) -> Bool {
        OpenCollectionDocument.evaluateAssertion(
            OCAssertion(expression: expression, op: op, value: value, disabled: false),
            response: result
        ).pass
    }

    #expect(check("res.status", "eq", "200"))
    #expect(!check("res.status", "eq", "404"))
    #expect(check("res.status", "neq", "500"))
    #expect(check("res.body.token", "eq", "abc123"))
    #expect(check("res.body.token", "contains", "bc12"))
    #expect(check("res.body.user.id", "gt", "5"))
    #expect(check("res.body.user.id", "lt", "10"))
    #expect(check("res.body.user.id", "isNumber", ""))
    #expect(check("res.body.token", "isString", ""))
    #expect(check("res.headers.content-type", "contains", "json"))
    #expect(check("res.time", "lt", "5000"))
    #expect(check("res.body.nope", "exists", "") == false)
    #expect(check("res.body.nope", "notExists", ""))
    #expect(check("res.status", "unknown-op", "200") == false)
}

@MainActor
@Test("assertions round-trip and preserve runtime siblings")
func assertionsRoundTrip() throws {
    let doc = OpenCollectionDocument.sample()
    _ = doc.addRequest(under: nil, snapshot: OCRequestSnapshot(
        name: "Login",
        method: "POST",
        url: "https://api.test/login",
        params: [],
        headers: [],
        bodyType: nil,
        bodyData: "",
        authKind: .none,
        settings: OCSettings(followRedirects: nil, timeout: nil),
        captures: [],
        assertions: [OCAssertion(expression: "res.status", op: "eq", value: "200", disabled: false)],
        docs: nil
    ))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gowa-assert-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("collection.yml")
    try doc.save(to: file)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(text.contains("assertions"))
    #expect(text.contains("res.status"))

    let loaded = try OpenCollectionDocument.load(from: file)
    let snapshot = try #require(loaded.requestSnapshot(at: [0]))
    #expect(snapshot.assertions == [OCAssertion(expression: "res.status", op: "eq", value: "200", disabled: false)])
}
