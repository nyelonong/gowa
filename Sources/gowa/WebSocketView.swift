import SwiftUI

struct WebSocketView: View {
    let app: AppState
    let draft: OCWebSocketSnapshot
    @State private var tab = Tab.message

    enum Tab: String, CaseIterable, Identifiable {
        case message = "Message"
        case headers = "Headers"
        case auth = "Auth"
        case docs = "Docs"
        var id: String { rawValue }
    }

    var body: some View {
        VSplitView {
            editor
                .frame(minHeight: 260)
            MessageLog(connection: app.socket)
                .frame(minHeight: 180)
                .layoutPriority(1)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: Binding(get: { draft.name }, set: { name in change { $0.name = name } }))
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .accessibilityLabel("WebSocket name")
                    .background(InitialFocusClearer())
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("WS")
                            .font(.system(.callout, design: .monospaced).weight(.bold))
                            .foregroundStyle(.teal)
                        Divider().frame(height: 16)
                        VariableField(
                            "wss://example.com/socket",
                            text: Binding(get: { draft.url }, set: { url in change { $0.url = url } }),
                            variables: app.variableScope,
                            fontSize: 13,
                            onSubmit: { toggleConnection() }
                        )
                        .accessibilityLabel("WebSocket URL")
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.hairline))

                    stateBadge
                    Button(app.socket.state == .open || app.socket.state == .connecting ? "Disconnect" : "Connect") {
                        toggleConnection()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(app.socket.isOpen ? .red : app.activeEnvironmentColor)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            TabStrip(tabs: Tab.allCases, selection: $tab, title: \.rawValue) { tab in
                switch tab {
                case .headers: draft.headers.filter { !$0.disabled }.count
                case .docs: (draft.docs ?? "").isEmpty ? 0 : 1
                default: 0
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Divider()

            Group {
                switch tab {
                case .message: composer
                case .headers:
                    ScrollView {
                        KeyValueTable(rows: draft.headers.map(\.kvRow), noun: "header", variables: app.variableScope) { edit in
                            change { $0.headers.apply(edit) }
                        }
                        .padding(16)
                    }
                case .auth:
                    ScrollView {
                        AuthEditor(auth: draft.authKind, variables: app.variableScope, tokenActions: app.tokenActions(at: app.selectedRequestPath)) { auth in
                            change { $0.authKind = auth }
                        }
                        .padding(16)
                    }
                case .docs:
                    DocsEditor(text: draft.docs ?? "") { text in change { $0.docs = text.isEmpty ? nil : text } }
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Type", selection: Binding(get: { draft.messageType }, set: { type in change { $0.messageType = type } })) {
                    Text("JSON").tag("json")
                    Text("Text").tag("text")
                    Text("XML").tag("xml")
                    Text("Binary (base64)").tag("binary")
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button {
                    app.sendSocketMessage()
                } label: {
                    Label("Send Message", systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!app.socket.isOpen)
                .help(app.socket.isOpen ? "Send (⌘↩)" : "Connect first")
            }
            CodeEditor(
                text: Binding(get: { draft.message }, set: { text in change { $0.message = text } }),
                highlightsJSON: draft.messageType == "json",
                variables: app.variableScope
            )
            .background(Theme.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.hairline))
        }
        .padding(16)
    }

    @ViewBuilder
    private var stateBadge: some View {
        let (text, color): (String, Color) = switch app.socket.state {
        case .idle: ("Not connected", .secondary)
        case .connecting: ("Connecting", .orange)
        case .open: ("Connected", .green)
        case .closed: ("Closed", .secondary)
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout.weight(.medium)).foregroundStyle(color)
        }
        .fixedSize()
    }

    private func toggleConnection() {
        if app.socket.state == .open || app.socket.state == .connecting {
            app.socket.disconnect()
        } else {
            app.connectSocket()
        }
    }

    private func change(_ edit: (inout OCWebSocketSnapshot) -> Void) {
        var copy = draft
        edit(&copy)
        app.updateSocketDraft(copy)
    }
}

private struct MessageLog: View {
    let connection: WebSocketConnection
    @State private var filter = ""

    var body: some View {
        let shown = connection.messages.filter { filter.isEmpty || $0.text.localizedCaseInsensitiveContains(filter) }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Messages").font(.callout.weight(.semibold))
                Text("\(connection.messages.filter { $0.direction == .sent }.count) sent · \(connection.messages.filter { $0.direction == .received }.count) received")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button("Clear") { connection.clear() }
                    .disabled(connection.messages.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
            if shown.isEmpty {
                ContentUnavailableView("No messages", systemImage: "arrow.left.arrow.right", description: Text("Connect, then send a message."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(shown) { message in
                        row(message).id(message.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: connection.messages.count) {
                        if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func row(_ message: WebSocketMessage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon(message.direction))
                .foregroundStyle(color(message.direction))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.direction == .received || message.direction == .sent ? (JSONHighlighter.prettyPrint(message.text) ?? message.text) : message.text)
                    .font(message.direction == .info || message.direction == .error ? .callout : .system(.callout, design: .monospaced))
                    .foregroundStyle(message.direction == .error ? Color.red : Color.primary)
                    .textSelection(.enabled)
                    .lineLimit(40)
                HStack(spacing: 6) {
                    Text(message.at.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                    if message.byteCount > 0 { Text("\(message.byteCount) B") }
                    if message.isBinary { Text("binary") }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(_ direction: WebSocketMessage.Direction) -> String {
        switch direction {
        case .sent: "arrow.up.right"
        case .received: "arrow.down.left"
        case .info: "info.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private func color(_ direction: WebSocketMessage.Direction) -> Color {
        switch direction {
        case .sent: .blue
        case .received: .green
        case .info: .secondary
        case .error: .red
        }
    }
}
