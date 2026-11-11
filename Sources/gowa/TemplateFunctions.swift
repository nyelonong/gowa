import CryptoKit
import Foundation

/// Built-in `{{$name}}` and `{{$name(args)}}` values, evaluated after
/// ordinary variables so arguments can contain `{{variables}}`.
enum TemplateFunctions {
    struct Function: Sendable {
        let name: String
        let signature: String
        let summary: String
    }

    static let catalog: [Function] = [
        Function(name: "uuid", signature: "$uuid", summary: "Random UUID"),
        Function(name: "timestamp", signature: "$timestamp", summary: "Unix time in seconds"),
        Function(name: "timestampMs", signature: "$timestampMs", summary: "Unix time in milliseconds"),
        Function(name: "isoTimestamp", signature: "$isoTimestamp", summary: "Current time, ISO 8601"),
        Function(name: "date", signature: "$date(yyyy-MM-dd)", summary: "Current time in a date format"),
        Function(name: "randomInt", signature: "$randomInt(0, 1000)", summary: "Random integer in a range"),
        Function(name: "randomString", signature: "$randomString(16)", summary: "Random letters and digits"),
        Function(name: "randomEmail", signature: "$randomEmail", summary: "Random email address"),
        Function(name: "randomBoolean", signature: "$randomBoolean", summary: "true or false"),
        Function(name: "base64", signature: "$base64(text)", summary: "Base64-encode text"),
        Function(name: "base64Decode", signature: "$base64Decode(text)", summary: "Base64-decode text"),
        Function(name: "urlEncode", signature: "$urlEncode(text)", summary: "Percent-encode text"),
        Function(name: "urlDecode", signature: "$urlDecode(text)", summary: "Percent-decode text"),
        Function(name: "md5", signature: "$md5(text)", summary: "MD5 hex digest"),
        Function(name: "sha1", signature: "$sha1(text)", summary: "SHA-1 hex digest"),
        Function(name: "sha256", signature: "$sha256(text)", summary: "SHA-256 hex digest"),
        Function(name: "sha512", signature: "$sha512(text)", summary: "SHA-512 hex digest"),
        Function(name: "hmacSha256", signature: "$hmacSha256(key, text)", summary: "HMAC-SHA256 hex digest"),
    ]

    private static let aliases = ["guid": "uuid", "randomUUID": "uuid"]

    static func isKnown(_ name: String) -> Bool {
        let resolved = aliases[name] ?? name
        return catalog.contains { $0.name == resolved }
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"\{\{\s*\$([A-Za-z][A-Za-z0-9]*)\s*(?:\((.*?)\))?\s*\}\}"#
    )

    /// Replaces every recognised function call; unknown names stay literal.
    static func render(_ template: String, now: Date = Date()) -> String {
        guard template.contains("{{$") || template.contains("{{ $") else { return template }
        let text = template as NSString
        var output = ""
        var cursor = 0
        for match in pattern.matches(in: template, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 1))
            let args = match.range(at: 2).location == NSNotFound ? [] : arguments(text.substring(with: match.range(at: 2)))
            output += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += evaluate(name, args, now: now) ?? text.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        output += text.substring(from: cursor)
        return output
    }

    static func evaluate(_ rawName: String, _ args: [String], now: Date = Date()) -> String? {
        let name = aliases[rawName] ?? rawName
        let first = args.first ?? ""
        switch name {
        case "uuid":
            return UUID().uuidString.lowercased()
        case "timestamp":
            return String(Int(now.timeIntervalSince1970))
        case "timestampMs":
            return String(Int64(now.timeIntervalSince1970 * 1000))
        case "isoTimestamp":
            return ISO8601DateFormatter().string(from: now)
        case "date":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = first.isEmpty ? "yyyy-MM-dd" : first
            return formatter.string(from: now)
        case "randomInt":
            let low = args.count > 0 ? Int(args[0]) ?? 0 : 0
            let high = args.count > 1 ? Int(args[1]) ?? 1000 : 1000
            return String(Int.random(in: min(low, high)...max(low, high)))
        case "randomString":
            let length = max(1, min(Int(first) ?? 16, 4096))
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            return String((0..<length).map { _ in alphabet.randomElement()! })
        case "randomEmail":
            return "user\(Int.random(in: 1000...999_999))@example.com"
        case "randomBoolean":
            return Bool.random() ? "true" : "false"
        case "base64":
            return Data(first.utf8).base64EncodedString()
        case "base64Decode":
            return Data(base64Encoded: first).flatMap { String(data: $0, encoding: .utf8) }
        case "urlEncode":
            return first.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed)
        case "urlDecode":
            return first.removingPercentEncoding
        case "md5":
            return hex(Insecure.MD5.hash(data: Data(first.utf8)))
        case "sha1":
            return hex(Insecure.SHA1.hash(data: Data(first.utf8)))
        case "sha256":
            return hex(SHA256.hash(data: Data(first.utf8)))
        case "sha512":
            return hex(SHA512.hash(data: Data(first.utf8)))
        case "hmacSha256":
            guard args.count == 2 else { return nil }
            let mac = HMAC<SHA256>.authenticationCode(for: Data(args[1].utf8), using: SymmetricKey(data: Data(args[0].utf8)))
            return Data(mac).map { String(format: "%02x", $0) }.joined()
        default:
            return nil
        }
    }

    /// Splits on top-level commas; double quotes keep commas and spaces literal.
    static func arguments(_ text: String) -> [String] {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        var quoted = false
        var wasQuoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                wasQuoted = true
            } else if character == ",", !quoted {
                result.append(wasQuoted ? current : current.trimmingCharacters(in: .whitespaces))
                current = ""
                wasQuoted = false
            } else if quoted || !(character == " " && current.isEmpty) {
                current.append(character)
            }
        }
        result.append(wasQuoted ? current : current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
}
