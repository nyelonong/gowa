import Foundation

/// Renders an effective request as a runnable shell cURL command.
enum CurlBuilder {
    static func command(from request: AppState.EffectiveRequest) -> String {
        var parts: [String] = ["curl"]

        if request.method != "GET" {
            parts.append("-X \(request.method)")
        }

        parts.append(shellQuote(request.url))

        for (name, value) in request.headers {
            parts.append("-H \(shellQuote("\(name): \(value)"))")
        }

        if !request.body.isEmpty {
            parts.append("-d \(shellQuote(request.body))")
        }

        if let timeout = request.timeout, timeout > 0 {
            parts.append("--max-time \(timeout)")
        }

        if request.followRedirects {
            parts.append("-L")
        }

        var lines = [parts[0]]
        for part in parts.dropFirst() {
            lines.append("  \(part)")
        }
        return lines.joined(separator: " \\\n")
    }

    /// Single-quote a value for shell safety; embedded quotes close and
    /// re-open the quoting (`'` → `'\''`).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
