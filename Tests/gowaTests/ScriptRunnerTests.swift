import Foundation
import Testing
@testable import gowa

private let request = ScriptRequest(
    name: "Create", method: "POST", url: "{{base}}/items",
    headers: [OCHeader(name: "Accept", value: "application/json", disabled: false)],
    body: #"{"a":1}"#
)

private let response = HTTPResult(
    url: URL(string: "https://x.test/items")!, status: 201,
    headers: [(name: "Content-Type", value: "application/json")],
    body: Data(#"{"data":{"id":42,"tags":["a","b"]}}"#.utf8),
    elapsed: .milliseconds(120), finalURL: URL(string: "https://x.test/items")!
)

@MainActor
@Test("pre-request scripts edit the request and set variables")
func preRequestScript() {
    let outcome = ScriptRunner.run([OCScript(type: "before-request", code: """
        req.setHeader("X-Trace", bru.getVar("trace"));
        req.deleteHeader("accept");
        req.setUrl(req.getUrl() + "?v=2");
        const body = req.getBody(); body.b = 2; req.setBody(body);
        bru.setVar("stamp", "s1");
        bru.setEnvVar("region", "eu");
        console.log("sending", { n: 1 }, true, 2.5);
        """)], request: request, response: nil, variables: ["trace": "t-9"])
    #expect(outcome.error == nil)
    #expect(outcome.request?.headers == [OCHeader(name: "X-Trace", value: "t-9", disabled: false)])
    #expect(outcome.request?.url == "{{base}}/items?v=2")
    #expect(outcome.request?.body.contains(#""b": 2"#) == true)
    #expect(outcome.runtimeVariables == ["stamp": "s1"])
    #expect(outcome.environmentVariables == ["region": "eu"])
    #expect(outcome.logs == [ScriptLog(level: "log", message: #"sending {"n":1} true 2.5"#)])
}

@MainActor
@Test("tests and expect assertions report pass and failure messages")
func scriptTests() {
    let outcome = ScriptRunner.run([OCScript(type: "tests", code: """
        test("created", () => expect(res.status).to.equal(201));
        test("has id", () => expect(res.getBody().data).to.have.property("id", 42));
        test("path helper", () => expect(res("$.data.tags[1]")).to.equal("b"));
        test("deep equal", () => expect(res.body.data.tags).to.eql(["a", "b"]));
        test("negation", () => expect(res.status).not.to.be.below(200));
        test("fails", () => expect(res.getHeader("content-type")).to.include("xml"));
        bru.setVar("itemId", res.body.data.id);
        """)], request: nil, response: response, variables: [:])
    #expect(outcome.tests.map(\.passed) == [true, true, true, true, true, false])
    #expect(outcome.tests.last?.error == #"expected: "application/json" to include "xml""#)
    #expect(outcome.runtimeVariables["itemId"] == "42")
}

@MainActor
@Test("a thrown error stops later scripts and is reported")
func scriptErrorStops() {
    let outcome = ScriptRunner.run([
        OCScript(type: "before-request", code: "throw new Error('nope')"),
        OCScript(type: "before-request", code: "bru.setVar('never', '1')"),
    ], request: request, response: nil, variables: [:])
    #expect(outcome.error?.contains("nope") == true)
    #expect(outcome.runtimeVariables.isEmpty)
}

@MainActor
@Test("runaway scripts stop at the time limit")
func scriptTimeLimit() {
    let clock = ContinuousClock()
    let start = clock.now
    let outcome = ScriptRunner.run([OCScript(type: "tests", code: "while (true) {}")], request: nil, response: response, variables: [:], timeLimit: 0.3)
    #expect(outcome.error?.contains("terminated") == true)
    #expect(start.duration(to: clock.now) < .seconds(3))
}

@MainActor
@Test("scripts save under runtime.scripts and keep other script types")
func scriptsRoundTrip() {
    let doc = OpenCollectionDocument(root: ["items": [[
        "info": ["name": "R", "type": "http"],
        "http": ["method": "GET", "url": "https://x.test"],
        "runtime": ["scripts": [["type": "hooks", "code": "keep()"]]],
    ]]])
    var snapshot = doc.requestSnapshot(at: [0])!
    #expect(snapshot.scripts.isEmpty)
    snapshot.setScript("tests", "test('a', () => {})")
    doc.updateRequest(at: [0], snapshot: snapshot)
    let scripts = (((doc.root["items"] as? [[String: Any]])?[0]["runtime"] as? [String: Any])?["scripts"] as? [[String: Any]]) ?? []
    #expect(scripts.compactMap { $0["type"] as? String } == ["hooks", "tests"])
    #expect(doc.requestSnapshot(at: [0])?.script("tests") == "test('a', () => {})")
}
