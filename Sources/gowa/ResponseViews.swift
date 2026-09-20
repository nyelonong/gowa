import AppKit
import SwiftUI

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
            } else if let result = app.result, let display = app.bodyDisplay {
                ResponseView(result: result, display: display)
            } else {
                ContentUnavailableView(
                    "Gowa",
                    systemImage: "paperplane",
                    description: Text("Select a request and press ⌘↩")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ResponseView: View {
    let result: HTTPResult
    let display: BodyDisplay
    @State private var tab: Tab = .body
    @State private var prettyPrinted = false

    enum Tab: String, CaseIterable, Identifiable {
        case body = "Body"
        case headers = "Headers"
        var id: String { rawValue }
    }

    private var shownText: String {
        display.text(prettyPrinted: prettyPrinted)
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

                if display.isJSON {
                    Toggle("Format", isOn: $prettyPrinted)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                        .controlSize(.small)
                }

                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(shownText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy body")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch tab {
            case .body:
                if result.body.isEmpty {
                    ContentUnavailableView(
                        "Empty body",
                        systemImage: "doc",
                        description: Text("The response carried no content")
                    )
                } else if !display.isJSON && String(data: result.body.prefix(16), encoding: .utf8) == nil {
                    ContentUnavailableView(
                        "Binary response",
                        systemImage: "doc.text",
                        description: Text("\(ByteCountFormatter.string(fromByteCount: Int64(result.body.count), countStyle: .binary)) of non-text data")
                    )
                } else {
                    CodeViewer(
                        text: shownText,
                        runs: display.runs(prettyPrinted: prettyPrinted)
                    )
                }
            case .headers:
                headersList
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
