import Foundation
import Testing
@testable import gowa

@Test("json highlighter marks keys, strings, literals")
func jsonHighlighter() {
    let json = "{\"name\": \"gowa\", \"count\": 3, \"ok\": true}"
    let attributed = JSONHighlighter.highlight(json)
    let plain = String(attributed.characters)
    #expect(plain == json)
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
