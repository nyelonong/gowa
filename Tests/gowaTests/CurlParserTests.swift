import Foundation
import Testing
@testable import gowa

@Test("tokenizer handles quotes, escapes, and line continuations")
func tokenizer() {
    let command = """
    curl -H 'A: it''s' \\
      -H "B: say \\"hi\\"" \\
      https://api.test
    """
    let words = CurlParser.tokenize(command)
    #expect(words.contains("A: it's") == false) // '' inside single quotes is two quotes, not escape — shell-accurate
    #expect(words.contains("B: say \"hi\""))
    #expect(words.contains("https://api.test"))
    #expect(words.count == 6) // curl, -H, A: its, -H, B: say "hi", url
}

@Test("simple GET with query params")
func simpleGet() throws {
    let result = try CurlParser.parse("curl 'https://api.test/users?page=2&limit=10'")
    #expect(result.method == "GET")
    #expect(result.url == "https://api.test/users")
    #expect(result.params.count == 2)
    #expect(result.params.contains { $0.name == "page" && $0.value == "2" && $0.kind == "query" })
}

@Test("POST JSON with headers and body")
func postJSON() throws {
    let result = try CurlParser.parse("""
    curl -X POST https://api.test/users \\
      -H 'Content-Type: application/json' \\
      -H 'Authorization: Bearer abc' \\
      -d '{"name": "Zaki"}'
    """)
    #expect(result.method == "POST")
    #expect(result.bodyType == "json")
    #expect(result.bodyData.contains("\"name\": \"Zaki\""))
    #expect(result.headers.contains { $0.name == "Authorization" && $0.value == "Bearer abc" })
    #expect(result.authKind == .none)
}

@Test("basic auth from -u; method inferred POST from -d")
func basicAuthAndInferredPost() throws {
    let result = try CurlParser.parse("curl -u alice:s3cret -d 'x=1' https://api.test/login")
    #expect(result.method == "POST")
    #expect(result.authKind == .basic(username: "alice", password: "s3cret"))
    #expect(result.bodyType == "text")
}

@Test("-G moves form data into query params")
func getMode() throws {
    let result = try CurlParser.parse("curl -G -d 'q=zig lang' https://api.test/search")
    #expect(result.method == "GET")
    #expect(result.bodyData.isEmpty)
    #expect(result.params.contains { $0.name == "q" && $0.value == "zig lang" })
}

@Test("--json implies POST with json body")
func jsonFlag() throws {
    let result = try CurlParser.parse(#"curl --json '{"a":1}' https://api.test/things"#)
    #expect(result.method == "POST")
    #expect(result.bodyType == "json")
    #expect(result.bodyData.contains(#""a":1"#))
}

@Test("multipart -F produces a warning and raw body")
func multipart() throws {
    let result = try CurlParser.parse("curl -F file=@photo.jpg -F caption=hi https://api.test/upload")
    #expect(result.method == "POST")
    #expect(result.bodyType == "multipart-form")
    #expect(!result.warnings.isEmpty)
}

@Test("non-curl and urlless input errors")
func errors() {
    #expect { try CurlParser.parse("") } throws: { ($0 as? CurlParseError) == .empty }
    #expect { try CurlParser.parse("wget https://api.test") } throws: { ($0 as? CurlParseError) == .notACurlCommand }
    #expect { try CurlParser.parse("curl -H 'x: y'") } throws: { ($0 as? CurlParseError) == .noURL }
}

@Test("user agent and unknown flags")
func flags() throws {
    let result = try CurlParser.parse("curl -A GowaBot --weird-flag https://api.test")
    #expect(result.headers.contains { $0.name == "User-Agent" && $0.value == "GowaBot" })
    #expect(result.warnings.contains { $0.contains("--weird-flag") })
}
