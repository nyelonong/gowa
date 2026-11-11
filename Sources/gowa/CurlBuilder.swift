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
        // curl's own default for --data is form-encoded; state what Gowa sends.
        if request.header("Content-Type") == nil {
            switch request.payload {
            case .text(_, let type):
                parts.append("-H \(shellQuote("Content-Type: \(type)"))")
            case .file(let url, let type):
                parts.append("-H \(shellQuote("Content-Type: \(type.isEmpty ? EffectiveBody.mimeType(for: url) : type)"))")
            case .none, .form, .multipart:
                break
            }
        }

        switch request.payload {
        case .none:
            break
        case .text(let text, _):
            parts.append("--data-raw \(shellQuote(text))")
        case .form(let pairs):
            for pair in pairs {
                parts.append("--data-urlencode \(shellQuote("\(pair.name)=\(pair.value)"))")
            }
        case .multipart(let fields):
            for field in fields {
                if let file = field.file {
                    let type = field.contentType.isEmpty ? "" : ";type=\(field.contentType)"
                    parts.append("-F \(shellQuote("\(field.name)=@\(file.path)\(type)"))")
                } else {
                    parts.append("--form-string \(shellQuote("\(field.name)=\(field.text ?? "")"))")
                }
            }
        case .file(let url, _):
            parts.append("--data-binary \(shellQuote("@" + url.path))")
        }

        if let timeout = request.timeout, timeout > 0 {
            parts.append("--max-time \(String(format: "%g", Double(timeout) / 1000))")
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
