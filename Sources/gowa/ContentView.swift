import SwiftUI

struct ContentView: View {
    @State private var app = AppState()

    var body: some View {
        VStack(spacing: 0) {
            RequestBar(app: app)
            Divider()
            ResponseArea(app: app)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct RequestBar: View {
    let app: AppState

    var body: some View {
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
                Button("Send") {
                    app.send()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!app.canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = app.result {
                ResponseBody(result: result)
            } else {
                ContentUnavailableView(
                    "Gowa",
                    systemImage: "paperplane",
                    description: Text("Enter a URL and press ⌘↩")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct ResponseBody: View {
    let result: HTTPResult

    private var bodyText: String? {
        String(data: result.body.prefix(1 << 20), encoding: .utf8)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(result.status) \(result.statusPhrase)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.15), in: Capsule())

                Text(formatBytes(result.body.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(formatDuration(result.elapsed))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                if let text = bodyText {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    Text("\(result.body.count) bytes (binary)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
    }

    private var statusColor: Color {
        switch result.status {
        case 200..<300: .green
        case 300..<400: .orange
        default: .red
        }
    }

    private func formatBytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .binary)
    }

    private func formatDuration(_ d: Duration) -> String {
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e18
        return String(format: "%.0f ms", ms)
    }
}
