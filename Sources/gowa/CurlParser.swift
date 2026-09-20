import Foundation

struct CurlParseResult: Sendable {
    var method: String
    var url: String
    var params: [OCParam]
    var headers: [OCHeader]
    var bodyType: String?
    var bodyData: String
    var authKind: OAuthKind
    var followRedirects: Bool?
    var warnings: [String]
}

enum CurlParseError: LocalizedError {
    case empty
    case notACurlCommand
    case noURL

    var errorDescription: String? {
        switch self {
        case .empty: "Paste a curl command first"
        case .notACurlCommand: "This doesn't look like a curl command"
        case .noURL: "No URL found in the command"
        }
    }
}

enum CurlParser {
    // MARK: - Shell-ish tokenizer

    /// Split a pasted command into words, honoring single/double quotes,
    /// backslash escapes, and `\`-newline continuations.
    static func tokenize(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var hasWord = false
        let chars = Array(command)

        var index = 0
        while index < chars.count {
            let c = chars[index]

            if c == "\\", index + 1 < chars.count, !inSingle {
                let next = chars[index + 1]
                if next == "\n" {
                    index += 2
                    continue // line continuation
                }
                if inDouble || !inDouble {
                    current.append(next)
                    hasWord = true
                    index += 2
                    continue
                }
            }

            if c == "'" && !inDouble {
                inSingle.toggle()
                hasWord = true
                index += 1
                continue
            }
            if c == "\"" && !inSingle {
                inDouble.toggle()
                hasWord = true
                index += 1
                continue
            }
            if !inSingle && !inDouble && c.isWhitespace {
                if hasWord {
                    words.append(current)
                    current = ""
                    hasWord = false
                }
                index += 1
                continue
            }

            current.append(c)
            hasWord = true
            index += 1
        }
        if hasWord { words.append(current) }
        return words
    }

    // MARK: - Parse

    static func parse(_ command: String) throws -> CurlParseResult {
        let words = tokenize(command)
        guard !words.isEmpty else { throw CurlParseError.empty }
        guard words[0].lowercased() == "curl" else { throw CurlParseError.notACurlCommand }

        var method: String?
        var url: String?
        var headers: [(String, String)] = []
        var dataParts: [String] = []
        var formParts: [String] = []
        var basicAuth: (String, String)?
        var warnings: [String] = []
        var followRedirects: Bool?
        var getMode = false
        var jsonMode = false

        var index = 1
        while index < words.count {
            let word = words[index]
            let next: String? = index + 1 < words.count ? words[index + 1] : nil

            func take() -> String {
                let value = next ?? ""
                index += 1
                return value
            }

            switch word {
            case "-X", "--request":
                if let value = next { method = value.uppercased(); index += 1 }
            case "-H", "--header":
                let raw = take()
                if let colon = raw.firstIndex(of: ":") {
                    let name = raw[..<colon].trimmingCharacters(in: .whitespaces)
                    let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { headers.append((name, value)) }
                }
            case "-d", "--data", "--data-raw", "--data-ascii", "--data-binary":
                dataParts.append(take())
            case "--data-urlencode":
                dataParts.append(take())
                warnings.append("--data-urlencode is stored as form data; verify encoding")
            case "-F", "--form":
                formParts.append(take())
            case "-u", "--user":
                let raw = take()
                if let colon = raw.firstIndex(of: ":") {
                    basicAuth = (String(raw[..<colon]), String(raw[raw.index(after: colon)...]))
                } else {
                    basicAuth = (raw, "")
                }
            case "--url":
                url = take()
            case "-A", "--user-agent":
                headers.append(("User-Agent", take()))
            case "-e", "--referer":
                headers.append(("Referer", take()))
            case "-b", "--cookie":
                headers.append(("Cookie", take()))
            case "-L", "--location":
                followRedirects = true
            case "--json":
                jsonMode = true
                dataParts.append(take())
            case "-G", "--get":
                getMode = true
            case "-k", "--insecure", "--compressed", "-s", "--silent", "-i", "--include",
                 "-v", "--verbose", "-S", "--show-error", "--no-buffer", "-#", "--progress-bar",
                 "--location-trusted", "--raw":
                break // no effect in Gowa
            case let token where token.hasPrefix("-"):
                warnings.append("Flag \(token) is ignored")
            default:
                if word.hasPrefix("http://") || word.hasPrefix("https://"), url == nil {
                    url = word
                } else if word.hasPrefix("$") && word.contains("http"), url == nil {
                    warnings.append("Shell variable URL \(word) cannot be resolved — paste the literal URL")
                } else if url == nil {
                    url = word
                }
            }
            index += 1
        }

        guard var finalURL = url, finalURL.hasPrefix("http://") || finalURL.hasPrefix("https://") else {
            throw CurlParseError.noURL
        }

        // Split query params out of the URL.
        var params: [OCParam] = []
        if let components = URLComponents(string: finalURL), let query = components.queryItems, !query.isEmpty {
            for item in query {
                params.append(OCParam(
                    name: item.name,
                    value: item.value ?? "",
                    kind: "query",
                    disabled: false
                ))
            }
            var cleaned = components
            cleaned.queryItems = nil
            finalURL = cleaned.url?.absoluteString ?? finalURL
        }

        // Body assembly.
        var bodyData = ""
        var bodyType: String?
        if !formParts.isEmpty {
            bodyType = "multipart-form"
            bodyData = formParts.joined(separator: "\n")
            warnings.append("Multipart form fields are stored as raw lines; review the body")
        } else if !dataParts.isEmpty {
            bodyData = dataParts.joined(separator: getMode ? "&" : "\n")
            let contentType = headers.first { $0.0.lowercased() == "content-type" }?.1.lowercased() ?? ""
            let trimmed = bodyData.trimmingCharacters(in: .whitespacesAndNewlines)
            if contentType.contains("json") || jsonMode || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                bodyType = "json"
            } else if contentType.contains("x-www-form-urlencoded") {
                bodyType = "form-urlencoded"
            } else {
                bodyType = "text"
            }
        }

        if getMode, !bodyData.isEmpty, bodyType != "multipart-form" {
            for pair in bodyData.components(separatedBy: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let name = parts.first else { continue }
                params.append(OCParam(
                    name: String(name).removingPercentEncoding ?? String(name),
                    value: parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : "",
                    kind: "query",
                    disabled: false
                ))
            }
            bodyData = ""
            bodyType = nil
        }

        let effectiveMethod = (method ?? (getMode ? "GET" : (dataParts.isEmpty && formParts.isEmpty && !jsonMode ? "GET" : "POST"))).uppercased()

        let authKind: OAuthKind
        if let (username, password) = basicAuth {
            authKind = .basic(username: username, password: password)
        } else {
            authKind = .none
        }

        return CurlParseResult(
            method: effectiveMethod,
            url: finalURL,
            params: params,
            headers: headers.map { OCHeader(name: $0.0, value: $0.1, disabled: false) },
            bodyType: bodyData.isEmpty ? nil : bodyType,
            bodyData: bodyData,
            authKind: authKind,
            followRedirects: followRedirects,
            warnings: warnings
        )
    }
}
