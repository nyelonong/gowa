import Foundation
import Observation

struct HeaderField: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var value = ""
}

@MainActor
@Observable
final class AppState {
    var url = ""
    var method: HTTPMethod = .GET
    var requestBody = ""
    var followRedirects = true
    var requestHeaders: [HeaderField] = []

    var busy = false
    var result: HTTPResult?
    var errorText: String?

    let history = HistoryStore()

    var canSend: Bool {
        !busy && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var activeHeaders: [(name: String, value: String)] {
        requestHeaders
            .map { (name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value) }
            .filter { !$0.name.isEmpty }
    }

    func send() {
        guard canSend else { return }
        busy = true
        result = nil
        errorText = nil
        let method = method
        let urlText = url
        let body = requestBody
        let headers = activeHeaders
        let followRedirects = followRedirects

        Task {
            do {
                let client = HTTPClient(followRedirects: followRedirects)
                let response = try await client.send(
                    method: method,
                    urlText: urlText,
                    body: body,
                    headers: headers
                )
                self.result = response
                self.history.record(method: method, url: urlText, body: body, status: response.status)
            } catch {
                self.errorText = error.localizedDescription
                self.history.record(method: method, url: urlText, body: body, status: nil)
            }
            self.busy = false
        }
    }

    func restore(_ entry: HistoryEntry) {
        guard let method = HTTPMethod(rawValue: entry.method) else { return }
        self.method = method
        self.url = entry.url
        self.requestBody = entry.body
        self.result = nil
        self.errorText = nil
    }

    func addHeader() {
        requestHeaders.append(HeaderField())
    }

    func removeHeader(_ field: HeaderField) {
        requestHeaders.removeAll { $0.id == field.id }
    }
}
