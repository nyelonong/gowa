import SwiftUI

/// Sequential folder/collection runner: executes every request in tree
/// order, applies captures (so chained tokens work), and reports checks.
struct RunnerSheet: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run collection")
                        .font(.headline)
                    Text(app.runner.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if app.runner.running {
                    ProgressView()
                        .controlSize(.small)
                    Button("Stop") { app.stopRunner() }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        app.startRunner(under: nil)
                    } label: {
                        Label("Run again", systemImage: "play")
                    }
                    .buttonStyle(.bordered)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)

            Divider()

            if app.runner.entries.isEmpty {
                ContentUnavailableView(
                    "Nothing to run",
                    systemImage: "play.circle",
                    description: Text("This collection has no requests")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(app.runner.entries) { entry in
                        RunnerRow(entry: entry)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

struct RunnerRow: View {
    let entry: AppState.RunnerEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                stateIcon

                Text(entry.method)
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)

                Text(entry.name)
                    .font(.callout)
                    .lineLimit(1)

                Spacer()

                if let elapsed = entry.elapsedText {
                    Text(elapsed)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let detail = entry.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !entry.outcomes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(0..<entry.outcomes.count, id: \.self) { outcomeIndex in
                        let outcome = entry.outcomes[outcomeIndex]
                        HStack(spacing: 5) {
                            let stateColor: Color = outcome.pass ? .green : .red
                            Image(systemName: outcome.pass ? "checkmark" : "xmark")
                                .foregroundStyle(stateColor)
                                .font(.caption2)
                            Text(outcome.expression)
                                .font(.system(.caption, design: .monospaced))
                            Text(outcome.op)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let expected = outcome.expected {
                                Text("expected [\(expected)]")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            if let actual = outcome.actual {
                                let actualColor: Color = outcome.pass ? .secondary : .red
                                Text("got [\(actual)]")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(actualColor)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.leading, 54)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch entry.state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.tertiary)
        }
    }
}
