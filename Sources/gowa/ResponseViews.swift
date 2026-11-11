import AppKit
import SwiftUI

struct ResponseArea: View {
    let app: AppState

    var body: some View {
        Group {
            if app.busy {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = app.errorText {
                VStack(spacing: 0) {
                    ContentUnavailableView {
                        Label("Request failed", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    }
                    if !app.lastLogs.isEmpty {
                        Divider()
                        ConsoleView(logs: app.lastLogs)
                            .frame(maxHeight: 180)
                    }
                }
            } else if let result = app.result, let display = app.bodyDisplay {
                VStack(spacing: 0) {
                    if !app.lastAssertions.isEmpty || !app.lastTests.isEmpty || app.lastScriptError != nil {
                        checksStrip
                        Divider()
                    }
                    if !app.lastCaptures.isEmpty {
                        capturedStrip
                        Divider()
                    }
                    ResponseView(app: app, result: result, display: display)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "paperplane")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                    Text("No response yet")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("Press")
                        Text("⌘↩")
                            .font(.caption.weight(.medium).monospaced())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                        Text("to send")
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ResponseArea {
    @ViewBuilder
    private var checksStrip: some View {
        let failed = app.lastAssertions.contains { !$0.pass } || app.lastTests.contains { !$0.passed } || app.lastScriptError != nil
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Image(systemName: failed ? "xmark.seal" : "checkmark.seal")
                    .foregroundStyle(failed ? .red : .green)
                Text(failed ? "Checks failed" : "Checks passed")
                    .font(.caption.weight(.medium))
                ForEach(app.lastAssertions, id: \.expression) { outcome in
                    HStack(spacing: 4) {
                        Image(systemName: outcome.pass ? "checkmark" : "xmark")
                            .foregroundStyle(outcome.pass ? .green : .red)
                            .font(.caption2)
                        Text(outcome.expression)
                            .font(.system(.caption, design: .monospaced))
                        Text(outcome.op)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if let expected = outcome.expected {
                            Text("= \(expected)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if let actual = outcome.actual {
                            let actualColor: Color = outcome.pass ? .secondary : .red
                            Text("got \(actual)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(actualColor)
                                .lineLimit(1)
                                .frame(maxWidth: 200, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(outcome.pass ? Color.green.opacity(0.10) : Color.red.opacity(0.12), in: Capsule())
                }
                ForEach(app.lastTests.indices, id: \.self) { index in
                    let test = app.lastTests[index]
                    HStack(spacing: 4) {
                        Image(systemName: test.passed ? "checkmark" : "xmark")
                            .foregroundStyle(test.passed ? .green : .red)
                            .font(.caption2)
                        Text(test.name)
                            .font(.caption)
                        if let error = test.error {
                            Text(error)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .frame(maxWidth: 260, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(test.passed ? Color.green.opacity(0.10) : Color.red.opacity(0.12), in: Capsule())
                    .help(test.error ?? test.name)
                }
                if let scriptError = app.lastScriptError {
                    Label(scriptError, systemImage: "exclamationmark.octagon")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(scriptError)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .background(failed ? Color.red.opacity(0.05) : Color.green.opacity(0.05))
    }

    @ViewBuilder
    private var capturedStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
        }
        .background(Color.green.opacity(0.05))
    }
}

struct ResponseView: View {
    let app: AppState
    let result: HTTPResult
    let display: BodyDisplay
    @State private var tab: Tab = .body
    @State private var prettyPrinted = false
    @State private var showDiff = false
    @State private var showTimings = false

    enum Tab: String, CaseIterable, Identifiable {
        case body = "Body"
        case headers = "Headers"
        case console = "Console"
        var id: String { rawValue }
    }

    private var shownText: String {
        display.text(prettyPrinted: prettyPrinted)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TabStrip(
                    tabs: Tab.allCases,
                    selection: $tab,
                    title: { $0.rawValue },
                    badge: { tab in
                        switch tab {
                        case .headers: result.headers.count
                        case .console: app.lastLogs.count
                        case .body: 0
                        }
                    }
                )

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text("\(result.status) \(result.statusPhrase)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.13), in: Capsule())

                Button {
                    showTimings.toggle()
                } label: {
                    Text(formatDuration(result.elapsed))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show timing breakdown")
                .popover(isPresented: $showTimings, arrowEdge: .bottom) {
                    TimingBreakdown(result: result)
                }

                Text(ByteCountFormatter.string(fromByteCount: Int64(result.body.count), countStyle: .binary))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                Divider()
                    .frame(height: 16)

                if display.isJSON {
                    Toggle(isOn: $prettyPrinted) {
                        Image(systemName: "text.alignleft")
                            .frame(width: 22, height: 22)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help(prettyPrinted ? "Show raw body" : "Format JSON")
                    .accessibilityLabel("Format JSON")
                }

                if app.diffContext != nil {
                    Toggle(isOn: $showDiff) {
                        Image(systemName: "plus.forwardslash.minus")
                            .frame(width: 22, height: 22)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help(showDiff ? "Back to response" : "Diff with previous response")
                    .accessibilityLabel("Diff with previous response")
                }

                IconButton(title: "Find in response", systemImage: "magnifyingglass", help: "Find in response (⌘F)") {
                    app.beginFindInResponse()
                }

                IconButton(title: "Copy response body", systemImage: "doc.on.doc", help: "Copy body") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(shownText, forType: .string)
                }

                IconButton(title: "Save response body", systemImage: "square.and.arrow.down", help: "Save response body to file") {
                    app.saveResponse()
                }

                IconButton(title: "Copy request as cURL", systemImage: "terminal", help: "Copy request as cURL") {
                    app.copyAsCurl()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            switch tab {
            case .body:
                if showDiff, let context = app.diffContext {
                    DiffViewer(context: context)
                } else if result.body.isEmpty {
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
                        runs: display.runs(prettyPrinted: prettyPrinted),
                        findTrigger: app.findTrigger
                    )
                }
            case .headers:
                headersList
            case .console:
                ConsoleView(logs: app.lastLogs)
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
        d.millisecondsText
    }
}

/// Colored line-by-line view of the previous vs current response body.
struct DiffViewer: View {
    let context: AppState.DiffContext

    var body: some View {
        let lines = LineDiff.diff(context.old, context.new) ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("Previous response → current")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("\(lines.filter { if case .added = $0 { return true }; return false }.count) added")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("\(lines.filter { if case .removed = $0 { return true }; return false }.count) removed")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                diffLines(lines)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func diffLines(_ lines: [LineDiff.Line]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                let (prefix, color): (String, Color) = {
                    switch line {
                    case .added: return ("+ ", Color.green.opacity(0.14))
                    case .removed: return ("- ", Color.red.opacity(0.14))
                    case .same: return ("  ", Color.clear)
                    }
                }()
                HStack(spacing: 0) {
                    Text(prefix)
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18)
                    Text(lineText(line))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
                .background(color)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func lineText(_ line: LineDiff.Line) -> String {
        switch line {
        case .added(let text): return text
        case .removed(let text): return text
        case .same(let text): return text
        }
    }
}

struct TimingBreakdown: View {
    let result: HTTPResult

    var body: some View {
        let total = max(result.elapsed.milliseconds, 1)
        VStack(alignment: .leading, spacing: 8) {
            Text("Timing").font(.headline)
            if result.timings.isEmpty {
                Text("No breakdown available (the connection was reused or the response came from a redirect).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 260, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(result.timings.indices, id: \.self) { index in
                let phase = result.timings[index]
                let start = result.timings[..<index].reduce(0) { $0 + $1.duration.milliseconds }
                HStack(spacing: 8) {
                    Text(phase.name)
                        .font(.caption)
                        .frame(width: 104, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: max(2, geo.size.width * phase.duration.milliseconds / total))
                            .offset(x: geo.size.width * min(start, total) / total)
                    }
                    .frame(width: 160, height: 8)
                    Text(String(format: "%.1f ms", phase.duration.milliseconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
            Divider()
            HStack {
                Text("Total").font(.caption.weight(.semibold))
                Spacer()
                Text(result.elapsed.millisecondsText).font(.caption.monospacedDigit().weight(.semibold))
            }
        }
        .padding(14)
        .frame(minWidth: 300)
    }
}

struct ConsoleView: View {
    let logs: [ScriptLog]

    var body: some View {
        if logs.isEmpty {
            ContentUnavailableView("No console output", systemImage: "terminal", description: Text("console.log from scripts appears here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(logs.indices, id: \.self) { index in
                        let log = logs[index]
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(log.level)
                                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                .foregroundStyle(color(log.level))
                                .frame(width: 40, alignment: .leading)
                            Text(log.message)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        Divider().opacity(0.4)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func color(_ level: String) -> Color {
        switch level {
        case "error": .red
        case "warn": .orange
        default: .secondary
        }
    }
}
