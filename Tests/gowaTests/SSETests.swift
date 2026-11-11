import Foundation
import Testing
@testable import gowa

@Test("SSE parser handles split chunks, CRLF, multi-line data, names, ids, and comments")
func sseParsing() {
    var parser = SSEParser()
    var events: [SSEEvent] = []
    let stream = ": keep-alive\r\nid: 1\r\nevent: update\r\ndata: {\"a\":\r\ndata: 1}\r\n\r\ndata: plain\n\nretry: 10\n\n"
    for chunk in stream.utf8.map({ Data([$0]) }) {
        events += parser.feed(chunk)
    }
    #expect(events.map(\.event) == ["update", "message"])
    #expect(events.map(\.data) == ["{\"a\":\n1}", "plain"])
    #expect(events.map(\.eventID) == ["1", "1"])
}

@Test("an event isn't emitted until its blank line arrives")
func ssePartial() {
    var parser = SSEParser()
    #expect(parser.feed(Data("data: x\n".utf8)).isEmpty)
    #expect(parser.feed(Data("\n".utf8)).map(\.data) == ["x"])
}
