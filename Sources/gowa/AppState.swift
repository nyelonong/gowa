import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var url = ""
    var method: HTTPMethod = .GET
    var requestBody = ""
    var followRedirects = true

    var busy = false
    var result: HTTPResult?
    var errorText: String?

    private let client = HTTPClient()

    var canSend: Bool {
        !busy && !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() {
        guard canSend else { return }
        busy = true
        result = nil
        errorText = nil
        let method = method
        let urlText = url
        let body = requestBody
        let followRedirects = followRedirects

        Task {
            do {
                let client = HTTPClient(followRedirects: followRedirects)
                let response = try await client.send(
                    method: method,
                    urlText: urlText,
                    body: body,
                    headers: []
                )
                self.result = response
            } catch {
                self.errorText = error.localizedDescription
            }
            self.busy = false
        }
    }
}
