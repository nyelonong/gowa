import SwiftUI

enum JSONHighlighter {
    private static let keyColor = Color(nsColor: .systemPink)
    private static let stringColor = Color(nsColor: .systemGreen)
    private static let numberColor = Color(nsColor: .systemBlue)
    private static let literalColor = Color(nsColor: .systemPurple)
    private static let punctuationColor = Color(nsColor: .secondaryLabelColor)

    static func isJSON(_ text: String, contentType: String?) -> Bool {
        if let contentType, contentType.lowercased().contains("json") {
            return true
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
    }

    static func highlight(_ text: String) -> AttributedString {
        var result = AttributedString()
        let chars = Array(text)
        var i = 0

        func append(_ token: String, _ color: Color?) {
            var container = AttributeContainer()
            if let color { container.foregroundColor = color }
            result.append(AttributedString(token, attributes: container))
        }

        while i < chars.count {
            let c = chars[i]

            if c == "\"" {
                var token = ""
                var j = i
                while j < chars.count {
                    token.append(chars[j])
                    if chars[j] == "\\", j + 1 < chars.count {
                        token.append(chars[j + 1])
                        j += 2
                        continue
                    }
                    j += 1
                    if chars[j - 1] == "\"" { break }
                }
                i = j
                var probe = i
                while probe < chars.count,
                      chars[probe] == " " || chars[probe] == "\n" || chars[probe] == "\t" || chars[probe] == "\r"
                {
                    probe += 1
                }
                let isKey = probe < chars.count && chars[probe] == ":"
                append(token, isKey ? keyColor : stringColor)
                continue
            }

            if ":,{}[]".contains(c) {
                append(String(c), punctuationColor)
                i += 1
                continue
            }

            if c.isLetter || c.isNumber || "-+.".contains(c) {
                var word = ""
                var j = i
                while j < chars.count,
                      chars[j].isLetter || chars[j].isNumber || "-+.".contains(chars[j])
                {
                    word.append(chars[j])
                    j += 1
                }
                i = j
                let color: Color = switch word {
                case "true", "false", "null": literalColor
                default: numberColor
                }
                append(word, color)
                continue
            }

            append(String(c), nil)
            i += 1
        }
        return result
    }

    static func prettyPrint(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let formatted = String(data: pretty, encoding: .utf8)
        else { return nil }
        return formatted
    }
}
