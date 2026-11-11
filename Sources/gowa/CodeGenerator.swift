import Foundation

/// Client code for a resolved request, in several languages.
enum CodeGenerator {
    enum Language: String, CaseIterable, Identifiable, Sendable {
        case curl = "cURL"
        case httpie = "HTTPie"
        case javascript = "JavaScript (fetch)"
        case python = "Python (requests)"
        case go = "Go (net/http)"
        case swift = "Swift (URLSession)"

        var id: String { rawValue }
    }

    static func generate(_ request: AppState.EffectiveRequest, language: Language) -> String {
        switch language {
        case .curl: CurlBuilder.command(from: request)
        case .httpie: httpie(request)
        case .javascript: javascript(request)
        case .python: python(request)
        case .go: go(request)
        case .swift: swift(request)
        }
    }

    /// Double-quoted literal with backslash escapes (JS, Python, Go, Swift).
    /// Swift literal: like `quoted` but with Swift's `\u{…}` escape.
    static func swiftQuoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let s where s.value < 0x20: out += "\\u{\(String(s.value, radix: 16))}"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let s where s.value < 0x20: out += String(format: "\\u%04x", s.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func headers(_ request: AppState.EffectiveRequest, contentType: String?) -> [(String, String)] {
        var list = request.headers.map { ($0.name, $0.value) }
        if let contentType, request.header("Content-Type") == nil, !contentType.hasPrefix("multipart/") {
            list.append(("Content-Type", contentType))
        }
        return list
    }

    private static func defaultContentType(_ payload: EffectiveBody) -> String? {
        switch payload {
        case .none, .multipart: nil
        case .text(_, let type): type
        case .form: "application/x-www-form-urlencoded"
        case .file(let url, let type): type.isEmpty ? EffectiveBody.mimeType(for: url) : type
        }
    }

    // MARK: HTTPie

    private static func httpie(_ request: AppState.EffectiveRequest) -> String {
        var parts = ["http"]
        if case .multipart = request.payload { parts.append("--form") }
        if request.followRedirects { parts.append("--follow") }
        parts.append(request.method)
        parts.append(CurlBuilder.shellQuote(request.url))
        for (name, value) in headers(request, contentType: defaultContentType(request.payload)) {
            parts.append(CurlBuilder.shellQuote("\(name):\(value)"))
        }
        var input = ""
        switch request.payload {
        case .none: break
        case .text(let text, _): input = " <<< " + CurlBuilder.shellQuote(text)
        case .form(let pairs): input = " <<< " + CurlBuilder.shellQuote(EffectiveBody.urlEncoded(pairs))
        case .multipart(let fields):
            for field in fields {
                parts.append(CurlBuilder.shellQuote(field.file.map { "\(field.name)@\($0.path)" } ?? "\(field.name)=\(field.text ?? "")"))
            }
        case .file(let url, _): input = " < " + CurlBuilder.shellQuote(url.path)
        }
        return parts.joined(separator: " \\\n  ") + input
    }

    // MARK: JavaScript

    private static func javascript(_ request: AppState.EffectiveRequest) -> String {
        var lines: [String] = []
        var body: String?
        switch request.payload {
        case .none: break
        case .text(let text, _): body = quoted(text)
        case .form(let pairs): body = "new URLSearchParams(\(quoted(EffectiveBody.urlEncoded(pairs))))"
        case .multipart(let fields):
            lines.append("const form = new FormData();")
            for field in fields {
                if let file = field.file {
                    lines.append("form.append(\(quoted(field.name)), await (await fetch(\(quoted("file://" + file.path)))).blob(), \(quoted(file.lastPathComponent))); // load the file your way")
                } else {
                    lines.append("form.append(\(quoted(field.name)), \(quoted(field.text ?? "")));")
                }
            }
            lines.append("")
            body = "form"
        case .file(let url, _):
            lines.append("const file = await (await import(\"node:fs/promises\")).readFile(\(quoted(url.path)));")
            lines.append("")
            body = "file"
        }
        lines.append("const response = await fetch(\(quoted(request.url)), {")
        lines.append("  method: \(quoted(request.method)),")
        let headerList = headers(request, contentType: defaultContentType(request.payload))
        if !headerList.isEmpty {
            lines.append("  headers: {")
            for (name, value) in headerList { lines.append("    \(quoted(name)): \(quoted(value)),") }
            lines.append("  },")
        }
        if let body { lines.append("  body: \(body),") }
        if !request.followRedirects { lines.append("  redirect: \"manual\",") }
        lines.append("});")
        lines.append("console.log(response.status, await response.text());")
        return lines.joined(separator: "\n")
    }

    // MARK: Python

    private static func python(_ request: AppState.EffectiveRequest) -> String {
        var lines = ["import requests", ""]
        var arguments = [quoted(request.method), quoted(request.url)]
        let headerList = headers(request, contentType: defaultContentType(request.payload))
        if !headerList.isEmpty {
            lines.append("headers = {")
            for (name, value) in headerList { lines.append("    \(quoted(name)): \(quoted(value)),") }
            lines.append("}")
            arguments.append("headers=headers")
        }
        switch request.payload {
        case .none: break
        case .text(let text, _):
            lines.append("data = \(quoted(text))")
            arguments.append("data=data.encode()")
        case .form(let pairs):
            lines.append("data = {")
            for pair in pairs { lines.append("    \(quoted(pair.name)): \(quoted(pair.value)),") }
            lines.append("}")
            arguments.append("data=data")
        case .multipart(let fields):
            let texts = fields.filter { $0.file == nil }
            let files = fields.filter { $0.file != nil }
            if !texts.isEmpty {
                lines.append("data = {")
                for field in texts { lines.append("    \(quoted(field.name)): \(quoted(field.text ?? "")),") }
                lines.append("}")
                arguments.append("data=data")
            }
            if !files.isEmpty {
                lines.append("files = {")
                for field in files { lines.append("    \(quoted(field.name)): open(\(quoted(field.file!.path)), \"rb\"),") }
                lines.append("}")
                arguments.append("files=files")
            }
        case .file(let url, _):
            lines.append("data = open(\(quoted(url.path)), \"rb\")")
            arguments.append("data=data")
        }
        if !request.followRedirects { arguments.append("allow_redirects=False") }
        if let timeout = request.timeout, timeout > 0 { arguments.append("timeout=\(String(format: "%g", Double(timeout) / 1000))") }
        lines.append("")
        lines.append("response = requests.request(\(arguments.joined(separator: ", ")))")
        lines.append("print(response.status_code, response.text)")
        return lines.joined(separator: "\n")
    }

    // MARK: Go

    private static func go(_ request: AppState.EffectiveRequest) -> String {
        var imports: Set<String> = ["fmt", "io", "net/http"]
        var setup: [String] = []
        var bodyExpression = "nil"
        var contentTypeExpression: String?
        switch request.payload {
        case .none: break
        case .text(let text, _):
            imports.insert("strings")
            bodyExpression = "strings.NewReader(\(goRaw(text)))"
        case .form(let pairs):
            imports.insert("strings")
            bodyExpression = "strings.NewReader(\(quoted(EffectiveBody.urlEncoded(pairs))))"
        case .multipart(let fields):
            imports.formUnion(["bytes", "mime/multipart", "os"])
            setup.append("\tvar body bytes.Buffer")
            setup.append("\twriter := multipart.NewWriter(&body)")
            for field in fields {
                if let file = field.file {
                    setup.append("\tif data, err := os.ReadFile(\(quoted(file.path))); err == nil {")
                    setup.append("\t\tpart, _ := writer.CreateFormFile(\(quoted(field.name)), \(quoted(file.lastPathComponent)))")
                    setup.append("\t\tpart.Write(data)")
                    setup.append("\t}")
                } else {
                    setup.append("\twriter.WriteField(\(quoted(field.name)), \(quoted(field.text ?? "")))")
                }
            }
            setup.append("\twriter.Close()")
            setup.append("")
            bodyExpression = "&body"
            contentTypeExpression = "writer.FormDataContentType()"
        case .file(let url, _):
            imports.insert("os")
            setup.append("\tfile, err := os.Open(\(quoted(url.path)))")
            setup.append("\tif err != nil {")
            setup.append("\t\tpanic(err)")
            setup.append("\t}")
            setup.append("\tdefer file.Close()")
            setup.append("")
            bodyExpression = "file"
        }
        var lines = ["package main", "", "import ("]
        lines += imports.sorted().map { "\t\(quoted($0))" }
        lines += [")", "", "func main() {"]
        lines += setup
        lines.append("\treq, err := http.NewRequest(\(quoted(request.method)), \(quoted(request.url)), \(bodyExpression))")
        lines += ["\tif err != nil {", "\t\tpanic(err)", "\t}"]
        for (name, value) in headers(request, contentType: defaultContentType(request.payload)) {
            lines.append("\treq.Header.Set(\(quoted(name)), \(quoted(value)))")
        }
        if let contentTypeExpression { lines.append("\treq.Header.Set(\"Content-Type\", \(contentTypeExpression))") }
        lines.append("")
        if request.followRedirects {
            lines.append("\tclient := &http.Client{}")
        } else {
            lines.append("\tclient := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}")
        }
        lines += [
            "\tresp, err := client.Do(req)",
            "\tif err != nil {", "\t\tpanic(err)", "\t}",
            "\tdefer resp.Body.Close()",
            "\tout, _ := io.ReadAll(resp.Body)",
            "\tfmt.Println(resp.StatusCode, string(out))",
            "}",
        ]
        return lines.joined(separator: "\n")
    }

    /// Go raw string when possible (no backticks), else an escaped literal.
    private static func goRaw(_ text: String) -> String {
        text.contains("`") || text.unicodeScalars.contains("\r") ? quoted(text) : "`" + text + "`"
    }

    // MARK: Swift

    private static func swift(_ request: AppState.EffectiveRequest) -> String {
        var lines = ["import Foundation", ""]
        lines.append("var request = URLRequest(url: URL(string: \(swiftQuoted(request.url)))!)")
        lines.append("request.httpMethod = \(swiftQuoted(request.method))")
        for (name, value) in headers(request, contentType: defaultContentType(request.payload)) {
            lines.append("request.setValue(\(swiftQuoted(value)), forHTTPHeaderField: \(swiftQuoted(name)))")
        }
        switch request.payload {
        case .none: break
        case .text(let text, _):
            lines.append("request.httpBody = Data(\(swiftMultiline(text)).utf8)")
        case .form(let pairs):
            lines.append("request.httpBody = Data(\(swiftQuoted(EffectiveBody.urlEncoded(pairs))).utf8)")
        case .multipart(let fields):
            lines.append("let boundary = UUID().uuidString")
            lines.append("request.setValue(\"multipart/form-data; boundary=\\(boundary)\", forHTTPHeaderField: \"Content-Type\")")
            lines.append("var body = Data()")
            for field in fields {
                lines.append("body.append(Data(\"--\\(boundary)\\r\\n\".utf8))")
                if let file = field.file {
                    lines.append("body.append(Data(" + swiftQuoted("Content-Disposition: form-data; name=\"\(field.name)\"; filename=\"\(file.lastPathComponent)\"\r\n\r\n") + ".utf8))")
                    lines.append("body.append(try Data(contentsOf: URL(fileURLWithPath: \(swiftQuoted(file.path)))))")
                } else {
                    lines.append("body.append(Data(" + swiftQuoted("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n") + ".utf8))")
                    lines.append("body.append(Data(\(swiftQuoted(field.text ?? "")).utf8))")
                }
                lines.append("body.append(Data(\"\\r\\n\".utf8))")
            }
            lines.append("body.append(Data(\"--\\(boundary)--\\r\\n\".utf8))")
            lines.append("request.httpBody = body")
        case .file(let url, _):
            lines.append("request.httpBody = try Data(contentsOf: URL(fileURLWithPath: \(swiftQuoted(url.path))))")
        }
        if let timeout = request.timeout, timeout > 0 {
            lines.append("request.timeoutInterval = \(String(format: "%g", Double(timeout) / 1000))")
        }
        lines.append("")
        lines.append("let (data, response) = try await URLSession.shared.data(for: request)")
        lines.append("print((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))")
        return lines.joined(separator: "\n")
    }

    private static func swiftMultiline(_ text: String) -> String {
        guard text.contains("\n"), !text.contains("\"\"\""), !text.unicodeScalars.contains("\r"), !text.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }) else { return swiftQuoted(text) }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
        return "\"\"\"\n" + escaped + "\n\"\"\""
    }
}
