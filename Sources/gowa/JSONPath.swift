import Foundation

/// A practical JSONPath subset: `$`, `.key`, `['key']`, `[0]`, `[-1]`, `[*]`,
/// `.*`, `..key` (recursive), and `[start:end]` slices.
enum JSONPath {
    enum Step: Equatable {
        case key(String)
        case index(Int)
        case wildcard
        case slice(Int?, Int?)
        case recursive(String?)
    }

    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ expression: String) throws -> [Step] {
        let text = Array(expression.trimmingCharacters(in: .whitespaces))
        guard text.first == "$" else { throw ParseError(message: "A path starts with $, e.g. $.data[0].id") }
        var steps: [Step] = []
        var index = 1
        func readName() -> String {
            var name = ""
            while index < text.count, text[index] != ".", text[index] != "[" {
                name.append(text[index])
                index += 1
            }
            return name
        }
        while index < text.count {
            switch text[index] {
            case ".":
                if index + 1 < text.count, text[index + 1] == "." {
                    index += 2
                    if index < text.count, text[index] == "*" {
                        index += 1
                        steps.append(.recursive(nil))
                    } else if index < text.count, text[index] == "[" {
                        steps.append(.recursive(nil))
                    } else {
                        let name = readName()
                        guard !name.isEmpty else { throw ParseError(message: "Expected a name after ..") }
                        steps.append(.recursive(name))
                    }
                } else {
                    index += 1
                    if index < text.count, text[index] == "*" {
                        index += 1
                        steps.append(.wildcard)
                    } else {
                        let name = readName()
                        guard !name.isEmpty else { throw ParseError(message: "Expected a name after .") }
                        steps.append(.key(name))
                    }
                }
            case "[":
                guard let close = text[index...].firstIndex(of: "]") else { throw ParseError(message: "Missing ]") }
                let inner = String(text[(index + 1)..<close]).trimmingCharacters(in: .whitespaces)
                index = close + 1
                if inner == "*" {
                    steps.append(.wildcard)
                } else if (inner.hasPrefix("'") && inner.hasSuffix("'")) || (inner.hasPrefix("\"") && inner.hasSuffix("\"")), inner.count >= 2 {
                    steps.append(.key(String(inner.dropFirst().dropLast())))
                } else if inner.contains(":") {
                    let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    steps.append(.slice(Int(parts[0]), parts.count > 1 ? Int(parts[1]) : nil))
                } else if let number = Int(inner) {
                    steps.append(.index(number))
                } else {
                    throw ParseError(message: "Unsupported selector [\(inner)]")
                }
            default:
                throw ParseError(message: "Unexpected \"\(text[index])\"")
            }
        }
        return steps
    }

    static func evaluate(_ expression: String, on root: Any) throws -> [Any] {
        var current: [Any] = [root]
        for step in try parse(expression) {
            current = current.flatMap { apply(step, to: $0) }
        }
        return current
    }

    private static func apply(_ step: Step, to value: Any) -> [Any] {
        switch step {
        case .key(let name):
            return (value as? [String: Any])?[name].map { [$0] } ?? []
        case .index(let position):
            guard let array = value as? [Any] else { return [] }
            let resolved = position < 0 ? array.count + position : position
            return array.indices.contains(resolved) ? [array[resolved]] : []
        case .wildcard:
            if let array = value as? [Any] { return array }
            if let object = value as? [String: Any] { return object.keys.sorted().compactMap { object[$0] } }
            return []
        case .slice(let start, let end):
            guard let array = value as? [Any] else { return [] }
            let count = array.count
            func clamp(_ index: Int?, _ fallback: Int) -> Int {
                guard let index else { return fallback }
                return min(max(index < 0 ? count + index : index, 0), count)
            }
            let low = clamp(start, 0)
            let high = clamp(end, count)
            return low < high ? Array(array[low..<high]) : []
        case .recursive(let name):
            var results: [Any] = []
            func walk(_ node: Any) {
                if let object = node as? [String: Any] {
                    if let name, let match = object[name] { results.append(match) }
                    for key in object.keys.sorted() {
                        if name == nil { results.append(object[key]!) }
                        walk(object[key]!)
                    }
                } else if let array = node as? [Any] {
                    for element in array {
                        if name == nil { results.append(element) }
                        walk(element)
                    }
                }
            }
            if name == nil { results.append(value) }
            walk(value)
            return results
        }
    }

    /// Pretty JSON for the matches: a single value alone, several as an array.
    static func render(_ matches: [Any]) -> String {
        let value: Any = matches.count == 1 ? matches[0] : matches
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else {
            return "\(value)"
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum XPathFilter {
    static func evaluate(_ expression: String, xml: Data) throws -> String {
        let document = try XMLDocument(data: xml, options: [.nodePreserveWhitespace])
        let nodes = try document.nodes(forXPath: expression)
        return nodes.map { $0.xmlString(options: [.nodePrettyPrint]) }.joined(separator: "\n")
    }
}
