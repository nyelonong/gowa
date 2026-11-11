import Foundation

struct SSEEvent: Sendable, Equatable, Identifiable {
    var id = UUID()
    var eventID: String?
    var event: String
    var data: String
    var receivedAt: Date

    static func == (a: Self, b: Self) -> Bool {
        a.eventID == b.eventID && a.event == b.event && a.data == b.data
    }
}

/// Incremental `text/event-stream` parser (WHATWG HTML §9.2): feed it bytes
/// as they arrive and it returns each completed event.
struct SSEParser {
    private var buffer = Data()
    private var dataLines: [String] = []
    private var eventName = ""
    private var lastEventID: String?
    private var sawField = false

    mutating func feed(_ chunk: Data, now: Date = Date()) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []
        while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            var lineData = buffer[buffer.startIndex..<newline]
            var next = buffer.index(after: newline)
            if buffer[newline] == 0x0D {
                // A lone CR at the end may be half of CRLF; wait for more.
                if next == buffer.endIndex { break }
                if buffer[next] == 0x0A { next = buffer.index(after: next) }
            }
            if lineData.first == 0xEF, lineData.starts(with: [0xEF, 0xBB, 0xBF]) { lineData = lineData.dropFirst(3) }
            let line = String(decoding: lineData, as: UTF8.self)
            buffer = Data(buffer[next...])
            if let event = process(line, now: now) { events.append(event) }
        }
        return events
    }

    private mutating func process(_ line: String, now: Date) -> SSEEvent? {
        if line.isEmpty {
            defer {
                dataLines = []
                eventName = ""
                sawField = false
            }
            guard sawField, !dataLines.isEmpty else { return nil }
            return SSEEvent(eventID: lastEventID, event: eventName.isEmpty ? "message" : eventName, data: dataLines.joined(separator: "\n"), receivedAt: now)
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        sawField = true
        switch field {
        case "data": dataLines.append(String(value))
        case "event": eventName = String(value)
        case "id": if !value.contains("\0") { lastEventID = String(value) }
        default: break
        }
        return nil
    }
}
