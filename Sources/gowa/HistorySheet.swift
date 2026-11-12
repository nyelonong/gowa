import SwiftUI

/// Past sends with their responses: filter, inspect, reopen, or restore.
struct HistorySheet: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var onlyThisCollection = true
    @State private var selection: HistoryEntry.ID?
    @State private var tab = Tab.response

    enum Tab: String, CaseIterable, Identifiable {
        case response = "Response"
        case request = "Request"
        var id: String { rawValue }
    }

    private var entries: [HistoryEntry] {
        app.history.entries.filter { entry in
            (!onlyThisCollection || entry.collectionID == nil || entry.collectionID == app.document?.documentID)
                && (filter.isEmpty || PaletteSearch.score(filter, "\(entry.method) \(entry.requestName ?? "") \(entry.url)") != nil)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("History").font(.headline)
                TextField("Filter by name, method, or URL", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Toggle("This collection only", isOn: $onlyThisCollection)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Clear All", role: .destructive) { app.history.clear() }
                    .disabled(app.history.entries.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            HSplitView {
                list
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 460)
                detail
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            Text("Authorization, cookie, and API key headers are never saved. Bodies over 256 KB are trimmed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(minWidth: 1000, minHeight: 600)
        .onAppear { selection = selection ?? entries.first?.id }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(entries) { entry in
                HStack(spacing: 8) {
                    MethodBadge(kind: "http", method: entry.method)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.requestName ?? entry.url)
                            .lineLimit(1)
                        Text(entry.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(entry.status.map(String.init) ?? "failed")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(statusColor(entry.status))
                        Text(entry.at.formatted(.relative(presentation: .numeric)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .tag(entry.id)
                .contextMenu {
                    Button("Add to Collection") { app.restore(entry) }
                    Button("Delete", role: .destructive) { app.history.delete(entry.id) }
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("No history", systemImage: "clock", description: Text("Requests you send appear here."))
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = app.history.entries.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(entry.method).font(Theme.mono(.callout, weight: .bold)).foregroundStyle(Theme.methodColor(entry.method))
                    Text(entry.url).font(Theme.mono(.callout)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 8)
                    if entry.collectionID == app.document?.documentID, entry.nodeID != nil {
                        Button("Open Request") {
                            if app.openSource(of: entry) { dismiss() }
                        }
                        .fixedSize()
                    }
                    Button("Add to Collection") { app.restore(entry) }
                        .fixedSize()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                HStack(spacing: 10) {
                    TabStrip(tabs: Tab.allCases, selection: $tab, title: \.rawValue)
                        .fixedSize()
                    Spacer()
                    if let ms = entry.elapsedMs {
                        Text(String(format: "%.0f ms", ms)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(entry.at.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Divider()
                switch tab {
                case .response: responseDetail(entry)
                case .request: requestDetail(entry)
                }
            }
        } else {
            ContentUnavailableView("Select an entry", systemImage: "clock.arrow.circlepath")
        }
    }

    @ViewBuilder
    private func responseDetail(_ entry: HistoryEntry) -> some View {
        if let error = entry.error {
            ContentUnavailableView("Request failed", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            VSplitView {
                headerList(entry.responseHeaders ?? [])
                    .frame(minHeight: 80, idealHeight: 140)
                body(entry.responseBody ?? "", truncated: entry.responseTruncated == true)
                    .frame(minHeight: 160)
            }
        }
    }

    private func requestDetail(_ entry: HistoryEntry) -> some View {
        VSplitView {
            headerList(entry.requestHeaders ?? [])
                .frame(minHeight: 80, idealHeight: 140)
            body(entry.body, truncated: false)
                .frame(minHeight: 160)
        }
    }

    private func headerList(_ headers: [HistoryEntry.Header]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(headers.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Text(headers[index].name).font(Theme.mono(.caption, weight: .medium)).frame(width: 180, alignment: .leading)
                        Text(headers[index].value).font(Theme.mono(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if headers.isEmpty {
                    Text("No headers recorded").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func body(_ text: String, truncated: Bool) -> some View {
        let isJSON = JSONHighlighter.isJSON(text, contentType: nil)
        let shown = isJSON ? (JSONHighlighter.prettyPrint(text) ?? text) : text
        return VStack(spacing: 0) {
            if truncated {
                Text("Trimmed to the first 256 KB").font(.caption).foregroundStyle(.orange).padding(4)
            }
            if shown.isEmpty {
                Text("No body").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeViewer(text: shown, runs: isJSON ? JSONHighlighter.runs(shown) : [], isJSON: isJSON)
            }
        }
    }

    private func statusColor(_ status: Int?) -> Color {
        switch status {
        case .some(200..<300): .green
        case .some(300..<400): .orange
        default: .red
        }
    }
}
