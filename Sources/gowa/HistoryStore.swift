import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var method: String
    var url: String
    var body: String
    var at: Date
    var status: Int?
}

@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []

    private static let maxEntries = 100

    private var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("Gowa", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    init() {
        load()
    }

    func record(method: HTTPMethod, url: String, body: String, status: Int?) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = HistoryEntry(method: method.rawValue, url: trimmed, body: body, at: Date(), status: status)
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        guard let fileURL,
              let data = try? JSONEncoder().encode(entries)
        else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
