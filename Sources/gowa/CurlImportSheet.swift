import SwiftUI

/// Paste a curl command; preview what it becomes; add it to the collection.
struct CurlImportSheet: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var command = ""
    @State private var destination: Int = -1 // -1 = collection root
    @State private var parsed: CurlParseResult?
    @State private var parseError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Paste cURL")
                    .font(.headline)
                Spacer()
                Text("Creates a new request in \"\(app.document?.name ?? "collection")\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("cURL command")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $command)
                        .font(.system(.callout, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: 420)
    .frame(minHeight: 220)
                        .onAppear { command = NSPasteboard.general.string(forType: .string) ?? "" }
                }

                previewPane
            }
            .padding(16)

            Divider()

            HStack {
                Picker("Add to", selection: $destination) {
                    Text("Collection root").tag(-1)
                    ForEach(Array(app.folderOptions().enumerated()), id: \.offset) { index, option in
                        Text(option.label).tag(index)
                    }
                }
                .frame(width: 260)

                Spacer()

                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Request") { importParsed() }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsed == nil)
            }
            .padding(12)
        }
        .onChange(of: command) { _, newValue in
            reparse(newValue)
        }
    }

    private func reparse(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parsed = nil
            parseError = nil
            return
        }
        do {
            parsed = try CurlParser.parse(text)
            parseError = nil
        } catch {
            parsed = nil
            parseError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            if let error = parseError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)
            } else if let result = parsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(result.method)
                                .font(.callout.weight(.semibold).monospaced())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.blue, in: RoundedRectangle(cornerRadius: 5))
                            Text(result.url)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !result.params.isEmpty {
                            previewSection("Params", result.params.map { "\($0.name)=\($0.value)" })
                        }
                        if !result.headers.isEmpty {
                            previewSection("Headers", result.headers.map { "\($0.name): \($0.value)" })
                        }
                        if !result.bodyData.isEmpty {
                            previewSection("Body (\(result.bodyType ?? "text"))", [result.bodyData])
                        }
                        switch result.authKind {
                        case .basic(let username, _):
                            previewSection("Auth", ["Basic — username \(username)"])
                        default:
                            EmptyView()
                        }

                        ForEach(result.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("Paste a curl command — the parsed request preview appears here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func previewSection(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
        }
    }

    private func importParsed() {
        guard let result = parsed else { return }
        var snapshot = OCRequestSnapshot(
            name: defaultName(for: result),
            method: result.method,
            url: result.url,
            params: result.params,
            headers: result.headers,
            bodyType: result.bodyType,
            bodyData: result.bodyData,
            authKind: result.authKind,
            settings: OCSettings(followRedirects: result.followRedirects, timeout: nil),
            docs: nil
        )
        let parent: NodePath? = destination >= 0 ? app.folderOptions()[safe: destination]?.path : nil
        snapshot.name = uniqueName(snapshot.name, under: parent)
        app.addRequestFromCurl(snapshot, under: parent)
        dismiss()
    }

    private func defaultName(for result: CurlParseResult) -> String {
        guard let host = URL(string: result.url)?.host else { return result.method }
        return "\(result.method) \(host)"
    }

    private func uniqueName(_ base: String, under parent: NodePath?) -> String {
        let siblings = app.document?.enumerate()
            .filter { $0.path.count == (parent?.count ?? 0) + 1 && Array($0.path.dropLast()) == (parent ?? []) }
            .map(\.name) ?? []
        guard siblings.contains(base) else { return base }
        var n = 2
        while siblings.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
