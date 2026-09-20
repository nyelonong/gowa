import Foundation
import Testing
@testable import gowa

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
