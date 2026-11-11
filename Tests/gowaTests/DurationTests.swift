import Foundation
import Testing
@testable import gowa

@Test("durations convert to whole milliseconds")
func durationMilliseconds() {
    #expect(Duration.milliseconds(347).milliseconds == 347)
    #expect(Duration.seconds(2).millisecondsText == "2000 ms")
}

@Test("res.time check compares response time in milliseconds")
func responseTimeCheck() {
    let response = HTTPResult(
        url: URL(string: "https://example.com")!,
        status: 200,
        headers: [],
        body: Data(),
        elapsed: .milliseconds(250),
        finalURL: URL(string: "https://example.com")!
    )
    let outcome = OpenCollectionDocument.evaluateAssertion(
        OCAssertion(expression: "res.time", op: "lt", value: "500", disabled: false),
        response: response
    )
    #expect(outcome.actual == "250")
    #expect(outcome.pass)
}
