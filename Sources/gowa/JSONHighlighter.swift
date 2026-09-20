import AppKit
import Foundation

enum JSONHighlighter {
    enum TokenKind: Int, Sendable {
        case key
        case string
        case number
        case literal
        case punctuation

        var color: NSColor {
            switch self {
            case .key: .systemPink
            case .string: .systemGreen
            case .number: .systemBlue
            case .literal: .systemPurple
            case .punctuation: .secondaryLabelColor
            }
        }
    }

    struct Run: Sendable {
        let range: NSRange
        let kind: TokenKind
    }

    static func isJSON(_ text: String, contentType: String?) -> Bool {
        if let contentType, contentType.lowercased().contains("json") {
            return true
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
    }

    static func prettyPrint(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let formatted = String(data: pretty, encoding: .utf8)
        else { return nil }
        return formatted
    }

    /// Tokenize JSON into color runs over UTF-16 offsets (NSRange-compatible).
    /// Single pass, O(n); no per-token string building.
    static func runs(_ text: String) -> [Run] {
        let units = Array(text.utf16)
        var result: [Run] = []
        result.reserveCapacity(units.count / 8)
        let quote: UInt16 = 0x22
        let backslash: UInt16 = 0x5C

        func push(_ kind: TokenKind, _ start: Int, _ end: Int) {
            result.append(Run(range: NSRange(location: start, length: end - start), kind: kind))
        }

        var i = 0
        while i < units.count {
            let unit = units[i]

            if unit == quote {
                let start = i
                i += 1
                while i < units.count {
                    let u = units[i]
                    if u == backslash, i + 1 < units.count {
                        i += 2
                        continue
                    }
                    i += 1
                    if u == quote { break }
                }
                var probe = i
                while probe < units.count,
                      units[probe] == 0x20 || units[probe] == 0x0A || units[probe] == 0x09 || units[probe] == 0x0D
                {
                    probe += 1
                }
                push(probe < units.count && units[probe] == 0x3A ? .key : .string, start, i)
                continue
            }

            if unit == 0x3A || unit == 0x2C || unit == 0x7B || unit == 0x7D || unit == 0x5B || unit == 0x5D {
                push(.punctuation, i, i + 1)
                i += 1
                continue
            }

            if isWordUnit(unit) {
                let start = i
                while i < units.count, isWordUnit(units[i]) {
                    i += 1
                }
                push(isJSONLiteral(units, start, i) ? .literal : .number, start, i)
                continue
            }

            i += 1
        }
        return result
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39)
            || (unit >= 0x41 && unit <= 0x5A)
            || (unit >= 0x61 && unit <= 0x7A)
            || unit == 0x2D || unit == 0x2B || unit == 0x2E
    }

    private static func isJSONLiteral(_ units: [UInt16], _ start: Int, _ end: Int) -> Bool {
        let length = end - start
        if length == 4 {
            return (units[start] == 0x74 && units[start + 1] == 0x72 && units[start + 2] == 0x75 && units[start + 3] == 0x65)
                || (units[start] == 0x6E && units[start + 1] == 0x75 && units[start + 2] == 0x6C && units[start + 3] == 0x6C)
        }
        if length == 5 {
            return units[start] == 0x66 && units[start + 1] == 0x61 && units[start + 2] == 0x6C
                && units[start + 3] == 0x73 && units[start + 4] == 0x65
        }
        return false
    }

    /// Build a display-ready attributed string: base label color + font, then
    /// one addAttribute call per run.
    static func attributed(_ text: String, runs: [Run]) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: (text as NSString).length)
        out.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: full)
        out.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        for run in runs {
            out.addAttribute(.foregroundColor, value: run.kind.color, range: run.range)
        }
        return out
    }
}
