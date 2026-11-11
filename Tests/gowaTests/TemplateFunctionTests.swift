import Foundation
import Testing
@testable import gowa

@Test("functions render after variables, so arguments can use variables")
func templateFunctionsUseVariables() {
    let text = OpenCollectionDocument.interpolate("Basic {{$base64({{user}}:{{pass}})}}", ["user": "alice", "pass": "pw"])
    #expect(text == "Basic YWxpY2U6cHc=")
}

@Test("digests, encodings, and fixed-time values are exact")
func templateFunctionValues() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(TemplateFunctions.render("{{$sha256(abc)}}") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(TemplateFunctions.render("{{$md5(abc)}}") == "900150983cd24fb0d6963f7d28e17f72")
    #expect(TemplateFunctions.render("{{$hmacSha256(key, \"The quick brown fox jumps over the lazy dog\")}}")
        == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
    #expect(TemplateFunctions.render("{{$urlEncode(a b&c)}}") == "a%20b%26c")
    #expect(TemplateFunctions.render("t={{$timestamp}}", now: now) == "t=1700000000")
    #expect(TemplateFunctions.render("{{$isoTimestamp}}", now: now) == "2023-11-14T22:13:20Z")
}

@Test("random functions respect their bounds and unknown names stay literal")
func templateFunctionRandomAndUnknown() {
    for _ in 0..<50 {
        let value = Int(TemplateFunctions.render("{{$randomInt(5, 7)}}"))!
        #expect((5...7).contains(value))
    }
    #expect(TemplateFunctions.render("{{$randomString(12)}}").count == 12)
    #expect(UUID(uuidString: TemplateFunctions.render("{{$guid}}")) != nil)
    #expect(TemplateFunctions.render("{{$nope}} {{plain}}") == "{{$nope}} {{plain}}")
}
