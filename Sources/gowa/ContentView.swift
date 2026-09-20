import SwiftUI

struct ContentView: View {
    @State private var app = AppState()

    var body: some View {
        NavigationSplitView {
            HistorySidebar(app: app)
        } detail: {
            VStack(spacing: 0) {
                RequestEditor(app: app)
                Divider()
                ResponseArea(app: app)
            }
        }
        .navigationTitle("Gowa")
    }
}

// MARK: - Sidebar

struct HistorySidebar: View {
    let app: AppState

    var body: some View {
        @Bindable var app = app

        List(selection: Binding(get: { nil as UUID? }, set: { id in
            guard let id,
                  let entry = app.history.entries.first(where: { $0.id == id })
            else { return }
            app.restore(entry)
        })) {
            ForEach(app.history.entries) { entry in
                HStack(spacing: 8) {
                    Text(entry.method)
                        .font(.caption.weight(.semibold).monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)

                    Text(entry.url)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    if let status = entry.status {
                        Circle()
                            .fill(status < 300 ? .green : (status < 400 ? .orange : .red))
                            .frame(width: 7, height: 7)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                    }
                }
                .tag(entry.id)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    app.history.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear history (⌘K)")
                .keyboardShortcut("k", modifiers: .command)
                .disabled(app.history.entries.isEmpty)
            }
        }
        .overlay {
            if app.history.entries.isEmpty {
                ContentUnavailableView(
                    "No history yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Requests you send appear here")
                )
            }
        }
    }
}

// MARK: - Request editor

struct RequestEditor: View {
    let app: AppState

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Method", selection: Binding(
                    get: { app.method },
                    set: { app.method = $0 }
                )) {
                    ForEach(HTTPMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .labelsHidden()
                .fixedSize()

                TextField(
                    "https://example.com/path",
                    text: Binding(get: { app.url }, set: { app.url = $0 })
                )
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit { app.send() }

                if app.busy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        app.send()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!app.canSend)
                    .help("Send request (⌘↩)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack(spacing: 16) {
                Toggle("Follow redirects", isOn: Binding(
                    get: { app.followRedirects },
                    set: { app.followRedirects = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.callout)
                .controlSize(.small)

                Spacer()

                Text("\(app.activeHeaders.count) header\(app.activeHeaders.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if app.method.carriesBody || !app.requestHeaders.isEmpty {
                RequestDetails(app: app)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
    }
}

struct RequestDetails: View {
    @State private var section: Section = .body
    let app: AppState

    enum Section: String, CaseIterable, Identifiable {
        case body = "Body"
        case headers = "Headers"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            switch section {
            case .body:
                if app.method.carriesBody {
                    TextEditor(text: Binding(
                        get: { app.requestBody },
                        set: { app.requestBody = $0 }
                    ))
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(height: 110)
                } else {
                    Text("\(app.method.rawValue) requests do not carry a body")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .headers:
                HeadersEditor(app: app)
            }
        }
    }
}

struct HeadersEditor: View {
    let app: AppState

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 6) {
            ForEach($app.requestHeaders) { $field in
                HStack(spacing: 6) {
                    TextField("Name", text: $field.name)
                        .font(.system(.callout, design: .monospaced))
                    Text(":")
                        .foregroundStyle(.tertiary)
                    TextField("Value", text: $field.value)
                        .font(.system(.callout, design: .monospaced))
                    Button {
                        app.removeHeader(field)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Button {
                app.addHeader()
            } label: {
                Label("Add header", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Response

struct ResponseArea: View {
    let app: AppState

    var body: some View {
        Group {
            if app.busy {
                ProgressView("Sending…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = app.errorText {
                ContentUnavailableView {
                    Label("Request failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if let result = app.result {
                ResponseView(result: result)
            } else {
                ContentUnavailableView(
                    "Gowa",
                    systemImage: "paperplane",
                    description: Text("Enter a URL and press ⌘↩")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ResponseView: View {
    let result: HTTPResult
    @State private var tab: Tab = .body
    @State private var prettyPrinted = false

    enum Tab: String, CaseIterable, Identifiable {
        case body = "Body"
        case headers = "Headers"
        var id: String { rawValue }
    }

    private var contentType: String? {
        result.headers.first { $0.name.lowercased() == "content-type" }?.value
    }

    private var bodyText: String? {
        String(data: result.body.prefix(4 << 20), encoding: .utf8)
    }

    private var displayText: String {
        let raw = bodyText ?? ""
        if prettyPrinted, let formatted = JSONHighlighter.prettyPrint(raw) {
            return formatted
        }
        return raw
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Response", selection: $tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)

                Text("\(result.status) \(result.statusPhrase)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.15), in: Capsule())

                Text(ByteCountFormatter.string(fromByteCount: Int64(result.body.count), countStyle: .binary))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(formatDuration(result.elapsed))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

                if let text = bodyText, JSONHighlighter.isJSON(text, contentType: contentType) {
                    Toggle("Format", isOn: $prettyPrinted)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .controlSize(.small)
                }

                if bodyText != nil {
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(displayText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy body")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch tab {
            case .body:
                responseBody
            case .headers:
                headersList
            }
        }
    }

    @ViewBuilder
    private var responseBody: some View {
        ScrollView {
            if let text = bodyText {
                if JSONHighlighter.isJSON(text, contentType: contentType) {
                    Text(JSONHighlighter.highlight(displayText))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    Text(displayText)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                Text("\(result.body.count) bytes (binary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private var headersList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(result.headers, id: \.name) { header in
                    HStack(alignment: .top, spacing: 0) {
                        Text(header.name)
                            .font(.system(.callout, design: .monospaced).weight(.medium))
                            .frame(width: 220, alignment: .leading)
                            .textSelection(.enabled)
                        Text(header.value)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    Divider().opacity(0.4)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var statusColor: Color {
        switch result.status {
        case 200..<300: .green
        case 300..<400: .orange
        default: .red
        }
    }

    private func formatDuration(_ d: Duration) -> String {
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e18
        return String(format: "%.0f ms", ms)
    }
}
