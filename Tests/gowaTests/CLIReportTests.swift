import Foundation
import Testing
@testable import gowa

@MainActor
private func sampleDocument() -> OpenCollectionDocument {
    OpenCollectionDocument(root: [
        "info": ["name": "Shop"],
        "config": ["environments": [["name": "dev", "variables": []], ["name": "prod", "variables": []]]],
        "items": [
            [
                "info": ["name": "Users", "type": "folder"],
                "items": [
                    ["info": ["name": "List users", "type": "http"], "http": ["method": "get", "url": "{{base}}/users"]],
                    ["info": ["name": "Live", "type": "websocket"], "websocket": ["url": "wss://x/ws"]],
                ],
            ],
            ["info": ["name": "Health", "type": "http"], "http": ["method": "GET", "url": "{{base}}/health"]],
        ],
    ])
}

@Test("list JSON gives IDs, folder paths, kinds, and environments")
@MainActor
func listJSON() throws {
    let tree = CLIReport.tree(sampleDocument())
    #expect(tree["environments"] as? [String] == ["dev", "prod"])
    let items = try #require(tree["items"] as? [[String: Any]])
    #expect(items.map { $0["id"] as? String } == ["0", "0.0", "0.1", "1"])
    #expect(items[0]["kind"] as? String == "folder")
    #expect(items[1]["path"] as? String == "Users/List users")
    #expect(items[1]["method"] as? String == "GET")
    #expect(items[1]["url"] as? String == "{{base}}/users")
    #expect(items[1]["runnable"] as? Bool == true)
    #expect(items[2]["runnable"] as? Bool == false)
}

@Test("--id selects one request or every runnable request in a folder")
@MainActor
func selectByID() {
    let nodes = sampleDocument().enumerate()
    #expect(CLIReport.select(nodes, id: "0", filter: nil).map(\.id) == ["0.0"])
    #expect(CLIReport.select(nodes, id: "1", filter: nil).map(\.id) == ["1"])
    #expect(CLIReport.select(nodes, id: nil, filter: nil).map(\.id) == ["0.0", "1"])
    #expect(CLIReport.select(nodes, id: nil, filter: "Health").map(\.id) == ["1"])
    #expect(CLIReport.select(nodes, id: "0.0", filter: "Health").isEmpty)
}

@Test("run report carries status, headers, body, and check results")
func runReport() throws {
    let response = HTTPResult(
        url: URL(string: "https://api.test/users")!,
        status: 200,
        headers: [(name: "Set-Cookie", value: "a=1"), (name: "Set-Cookie", value: "b=2")],
        body: Data(#"{"ok":true}"#.utf8),
        elapsed: .milliseconds(42),
        finalURL: URL(string: "https://api.test/users")!
    )
    let outcome = ExecutionOutcome(
        effective: .init(method: "GET", url: "https://api.test/users?key=SECRET", headers: [(name: "Authorization", value: "Bearer SECRET")], payload: .none, followRedirects: true, timeout: nil),
        response: response,
        captures: [CaptureOutcome(name: "token", value: "SECRET", scope: "runtime")],
        assertions: [.init(expression: "res.body", op: "isJson", expected: nil, actual: String(repeating: "x", count: 10_000), pass: true, note: nil)],
        tests: [ScriptTestResult(name: "is ok", passed: true)]
    )
    let report = CLIReport.result(id: "0.0", location: "Users/List users", method: "GET", url: "{{base}}/users", outcome: outcome)
    #expect(report["status"] as? Int == 200)
    #expect(report["timeMs"] as? Int == 42)
    let body = try #require((report["response"] as? [String: Any])?["body"] as? [String: Any])
    #expect(body["text"] as? String == #"{"ok":true}"#)
    let headers = try #require((report["response"] as? [String: Any])?["headers"] as? [[String: String]])
    #expect(headers.count == 2)
    let actual = try #require((report["assertions"] as? [[String: Any]])?.first?["actual"] as? String)
    #expect(actual.count == CLIReport.actualLimit + 1)
    #expect(!CLIReport.encode(report).contains("SECRET"))
}

@Test("bodies are cut at the limit without splitting a character; binary becomes base64")
func bodyEncoding() {
    let text = CLIReport.body(Data("aé".utf8), limit: 2)
    #expect(text["text"] as? String == "a")
    #expect(text["truncated"] as? Bool == true)
    #expect(text["bytes"] as? Int == 3)

    let binary = CLIReport.body(Data([0xFF, 0x00, 0xFE]))
    #expect(binary["encoding"] as? String == "base64")
    #expect(binary["base64"] as? String == Data([0xFF, 0x00, 0xFE]).base64EncodedString())
}

@Test("argument parsing rejects unknown flags and missing values")
func parseArguments() throws {
    let options = try CLIMode.parse(["c.yml", "--json", "--id", "0.1"], valueFlags: ["--env", "--id", "--filter"], boolFlags: ["--json"])
    #expect(options.path == "c.yml")
    #expect(options.json)
    #expect(options.id == "0.1")
    #expect(throws: CLIMode.CLIError.self) { try CLIMode.parse(["c.yml", "--nope"], valueFlags: [], boolFlags: ["--json"]) }
    #expect(throws: CLIMode.CLIError.self) { try CLIMode.parse(["c.yml", "--env"], valueFlags: ["--env"], boolFlags: []) }
    #expect(try CLIMode.parse(["c.yml", "--filter", "--help"], valueFlags: ["--filter"], boolFlags: []).help == false)
    #expect(try CLIMode.parse(["c.yml", "-h"], valueFlags: [], boolFlags: []).help)
}

@Test("invalid URL errors do not quote the resolved URL")
func invalidURLRedacted() {
    let text = CLIReport.describe(HTTPError.invalidURL("http://exa mple.com/?k=SECRET"))
    #expect(!text.contains("SECRET"))
}

@Test("a 4-byte character cut at any offset never leaves broken text")
func bodyCutEmoji() {
    let data = Data("a😀b".utf8)
    for limit in 1...5 {
        let body = CLIReport.body(data, limit: limit)
        #expect(body["encoding"] as? String == "utf8")
        #expect(body["text"] as? String == (limit < 5 ? "a" : "a😀"))
    }
}
