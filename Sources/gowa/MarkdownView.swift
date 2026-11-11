import SwiftUI

/// Small Markdown renderer for request and folder docs: headings, lists,
/// quotes, fenced code, rules, and inline styling and links.
struct MarkdownView: View {
    let markdown: String

    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
        case numbered(String, String)
        case quote(String)
        case code(String)
        case rule
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.isEmpty {
                flush()
            } else if let level = line.firstIndex(where: { $0 != "#" }).map({ line.distance(from: line.startIndex, to: $0) }),
                      (1...6).contains(level), line.dropFirst(level).hasPrefix(" ") {
                flush()
                blocks.append(.heading(level, String(line.dropFirst(level + 1))))
            } else if line == "---" || line == "***" {
                flush()
                blocks.append(.rule)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.numbered(String(line[..<dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            inline(text)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(text)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                inline(text)
            }
        case .quote(let text):
            inline(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 3) }
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    private func inline(_ text: String) -> Text {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Text(attributed)
    }
}

/// Preview or edit Markdown docs.
struct DocsEditor: View {
    let text: String
    let onChange: (String) -> Void
    @State private var editing: Bool?

    var body: some View {
        let isEditing = editing ?? text.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isEditing ? "Markdown, saved in the collection file" : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isEditing ? "Preview" : "Edit") { editing = !isEditing }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            if isEditing {
                CodeEditor(text: Binding(get: { text }, set: { onChange($0) }), highlightsJSON: false)
                    .background(Theme.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.hairline))
                    .frame(minHeight: 200, maxHeight: .infinity)
            } else {
                ScrollView {
                    MarkdownView(markdown: text)
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}
