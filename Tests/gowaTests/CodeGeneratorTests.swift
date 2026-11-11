import Foundation
import Testing
@testable import gowa

private let jsonPost = AppState.EffectiveRequest(
    method: "POST",
    url: "https://api.test/items?q=a b",
    headers: [(name: "Authorization", value: "Bearer t\"k")],
    payload: .text("{\"name\": \"it's\"}\n", contentType: "application/json"),
    followRedirects: false,
    timeout: 5000
)

@Test("every language keeps method, URL, headers, body, and default content type")
func generatedCodeContents() {
    for language in CodeGenerator.Language.allCases {
        let code = CodeGenerator.generate(jsonPost, language: language)
        #expect(code.contains("api.test/items"), "\(language)")
        #expect(code.contains("POST"), "\(language)")
        #expect(code.contains("Authorization"), "\(language)")
        #expect(code.contains("application/json"), "\(language)")
        #expect(code.contains("name"), "\(language)")
    }
}

@Test("string literals escape quotes, backslashes, and control characters")
func generatedQuoting() {
    #expect(CodeGenerator.quoted("a\"b\\c\nd\u{1}") == #""a\"b\\c\nd\u0001""#)
    let python = CodeGenerator.generate(jsonPost, language: .python)
    #expect(python.contains(#""Authorization": "Bearer t\"k""#))
    #expect(python.contains("allow_redirects=False"))
    #expect(python.contains("timeout=5"))
}

@Test("multipart bodies use each language's form API")
func generatedMultipart() {
    let request = AppState.EffectiveRequest(
        method: "POST", url: "https://api.test/upload", headers: [],
        payload: .multipart([
            MultipartPart(name: "note", text: "hi", file: nil, contentType: ""),
            MultipartPart(name: "doc", text: nil, file: URL(fileURLWithPath: "/tmp/a.txt"), contentType: ""),
        ]),
        followRedirects: true, timeout: nil
    )
    #expect(CodeGenerator.generate(request, language: .python).contains(#""doc": open("/tmp/a.txt", "rb")"#))
    #expect(CodeGenerator.generate(request, language: .go).contains("writer.CreateFormFile(\"doc\", \"a.txt\")"))
    #expect(CodeGenerator.generate(request, language: .javascript).contains("form.append(\"note\", \"hi\");"))
    #expect(CodeGenerator.generate(request, language: .httpie).contains("'doc@/tmp/a.txt'"))
}
