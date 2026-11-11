import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    struct Header: Codable, Equatable, Sendable {
        var name: String
        var value: String
    }

    var id = UUID()
    var method: String
    var url: String
    var body: String
    var at: Date
    var status: Int?
    var requestName: String?
    var collectionID: String?
    var nodeID: String?
    var requestHeaders: [Header]?
    var responseHeaders: [Header]?
    var responseBody: String?
    var responseTruncated: Bool?
    var elapsedMs: Double?
    var error: String?
}

/// Sent requests and their responses, newest first, in Application Support.
/// Credential headers are redacted and long bodies trimmed before saving.
@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []

    static let maxEntries = 300
    static let maxBodyBytes = 256 * 1024
    static let redactedHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "api-key", "x-auth-token",
    ]

    private let fileURL: URL?

    init(fileURL: URL? = HistoryStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    static var defaultFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Gowa", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    func record(_ entry: HistoryEntry) {
        var entry = entry
        entry.url = entry.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.url.isEmpty else { return }
        entry.requestHeaders = entry.requestHeaders.map(Self.redact)
        entry.responseHeaders = entry.responseHeaders.map(Self.redact)
        entry.body = Self.trim(entry.body).text
        if let body = entry.responseBody {
            let trimmed = Self.trim(body)
            entry.responseBody = trimmed.text
            entry.responseTruncated = trimmed.truncated ? true : nil
        }
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    func delete(_ id: HistoryEntry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    static func redact(_ headers: [HistoryEntry.Header]) -> [HistoryEntry.Header] {
        headers.map { header in
            redactedHeaders.contains(header.name.lowercased()) ? .init(name: header.name, value: "•••• (not saved)") : header
        }
    }

    static func trim(_ text: String) -> (text: String, truncated: Bool) {
        let utf8 = text.utf8
        guard utf8.count > maxBodyBytes else { return (text, false) }
        let prefix = String(decoding: utf8.prefix(maxBodyBytes), as: UTF8.self)
        return (prefix, true)
    }

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
