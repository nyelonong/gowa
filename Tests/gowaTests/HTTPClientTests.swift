import Foundation
import Testing
@testable import gowa

@Test("json runs mark keys, strings, numbers, literals")
func jsonRuns() {
    let json = #"{"name": "gowa", "count": 3, "ok": true, "pi": -2.5}"#
    let runs = JSONHighlighter.runs(json)
    let ns = json as NSString
    let tokens = runs.map { (ns.substring(with: $0.range), $0.kind) }

    #expect(tokens.contains { $0 == ("\"name\"", .key) })
    #expect(tokens.contains { $0 == ("\"gowa\"", .string) })
    #expect(tokens.contains { $0 == ("\"count\"", .key) })
    #expect(tokens.contains { $0 == ("3", .number) })
    #expect(tokens.contains { $0 == ("-2.5", .number) })
    #expect(tokens.contains { $0 == ("true", .literal) })
    #expect(tokens.contains { $0 == (":", .punctuation) })
}

@Test("json runs preserve escaped quotes")
func jsonRunsEscapes() {
    let json = #"{"say": "a \"quoted\" word"}"#
    let runs = JSONHighlighter.runs(json)
    let ns = json as NSString
    let tokens = runs.map { (ns.substring(with: $0.range), $0.kind) }

    #expect(tokens.contains { $0 == ("\"say\"", .key) })
    #expect(tokens.contains { $0 == ("\"a \\\"quoted\\\" word\"", .string) })
}

@Test("attributed preserves full text")
func attributedText() {
    let json = #"{"a": [1, 2, "x"]}"#
    let attributed = JSONHighlighter.attributed(json, runs: JSONHighlighter.runs(json))
    #expect(attributed.string == json)
    #expect(attributed.length == (json as NSString).length)
}

@Test("json detection")
func jsonDetection() {
    let json = "{\"name\": \"gowa\", \"count\": 3, \"ok\": true}"
    #expect(JSONHighlighter.isJSON(json, contentType: nil))
    #expect(!JSONHighlighter.isJSON("plain text body", contentType: nil))
    #expect(JSONHighlighter.isJSON("anything", contentType: "application/json"))
}

@Test("pretty print formats and sorts")
func prettyPrint() {
    let formatted = JSONHighlighter.prettyPrint("{\"b\":1,\"a\":2}")
    #expect(formatted != nil)
    #expect(formatted!.contains("\"a\" : 2"))
    #expect(JSONHighlighter.prettyPrint("not json") == nil)
}

@Test("status phrases")
func statusPhrases() {
    #expect(HTTPResult(url: URL(string: "https://x.test")!, status: 200, headers: [], body: Data(), elapsed: .zero, finalURL: URL(string: "https://x.test")!).statusPhrase == "OK")
    #expect(HTTPResult(url: URL(string: "https://x.test")!, status: 404, headers: [], body: Data(), elapsed: .zero, finalURL: URL(string: "https://x.test")!).statusPhrase == "Not Found")
}

@Test("missing scheme rejected")
func missingScheme() async {
    let client = HTTPClient()
    do {
        _ = try await client.send(method: .GET, urlText: "example.com", body: "", headers: [])
        #expect(Bool(false), "expected error")
    } catch let error as HTTPError {
        #expect(error.errorDescription == "URL must start with http:// or https://")
    } catch {
        #expect(Bool(false), "unexpected error type: \(error)")
    }
}
