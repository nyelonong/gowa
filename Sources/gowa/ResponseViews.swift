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
                VStack(spacing: 0) {
                    if !app.lastCaptures.isEmpty {
                        capturedStrip
                        Divider()
                    }
                    ResponseView(app: app, result: result, display: display)
                }
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

extension ResponseArea {
    @ViewBuilder
    private var capturedStrip: some View {
        @Bindable var app = app
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .foregroundStyle(.green)
            Text("Captured")
                .font(.caption.weight(.medium))
            ForEach(app.lastCaptures, id: \.name) { capture in
                HStack(spacing: 4) {
                    Text("{{\(capture.name)}}")
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                    Text("= \(capture.value)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(capture.value == "<not found>" ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 260, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(capture.stored ? Color.orange.opacity(0.12) : Color.green.opacity(0.12), in: Capsule())
                .help(capture.stored ? "Stored into the active environment (persisted on save)" : "Stored in session memory — not saved to the collection file")
            }
            Spacer()
            Button("Clear") {
                app.sessionVariables = [:]
                app.lastCaptures = []
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.05))
    }
}

struct ResponseView: View {
    let app: AppState
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
                    app.beginFindInResponse()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("Find in response (⌘F)")

                Button {
                    app.copyAsCurl()
                } label: {
                    Image(systemName: "curlybraces.square")
                }
                .buttonStyle(.plain)
                .help("Copy request as cURL")

                Button {
                    app.saveResponse()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("Save response body to file")

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
