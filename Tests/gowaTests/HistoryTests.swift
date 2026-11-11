import Foundation
import Testing
@testable import gowa

@MainActor
@Test("history redacts credential headers, trims bodies, and persists privately")
func historyRecording() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("gowa-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = HistoryStore(fileURL: file)
    store.record(HistoryEntry(
        method: "POST", url: " https://x.test/login ", body: "a", at: Date(), status: 200,
        requestHeaders: [.init(name: "Authorization", value: "Bearer secret"), .init(name: "Accept", value: "*/*")],
        responseHeaders: [.init(name: "Set-Cookie", value: "sid=1")],
        responseBody: String(repeating: "x", count: HistoryStore.maxBodyBytes + 10)
    ))
    let entry = try #require(HistoryStore(fileURL: file).entries.first)
    #expect(entry.url == "https://x.test/login")
    #expect(entry.requestHeaders?.map(\.value) == ["•••• (not saved)", "*/*"])
    #expect(entry.responseHeaders?.first?.value == "•••• (not saved)")
    #expect(entry.responseBody?.utf8.count == HistoryStore.maxBodyBytes)
    #expect(entry.responseTruncated == true)
    #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("secret"))
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test("older history files without the new fields still load")
func historyLegacyDecode() throws {
    let legacy = #"[{"id":"7E5B0A2E-1D7B-4C35-9C3C-1D7F7E7E7E7E","method":"GET","url":"https://x.test","body":"","at":0,"status":200}]"#
    let decoded = try JSONDecoder().decode([HistoryEntry].self, from: Data(legacy.utf8))
    #expect(decoded.first?.requestName == nil)
    #expect(decoded.first?.status == 200)
}

@Test("history redaction hides auth headers, auth query params, and secret values")
func historyRedaction() {
    let redaction = HistoryRedaction(headers: ["x-goog-api-key"], queries: ["key"], secrets: ["s3cr3t-value"])
    #expect(redaction.url("https://x.test/a?key=abc&q=s3cr3t-value") == "https://x.test/a?key=redacted&q=••••")
    #expect(redaction.header("X-Goog-Api-Key", "abc").value == HistoryRedaction.mask)
    #expect(redaction.header("X-Other", "Bearer s3cr3t-value").value == "Bearer ••••")
    #expect(redaction.text(#"{"pw":"s3cr3t-value"}"#) == #"{"pw":"••••"}"#)
}
