import SwiftUI

struct RequestEditor: View {
    let app: AppState

    var body: some View {
        if let draft = app.draft {
            EditorContent(app: app, draft: draft)
        } else if app.document != nil {
            VStack(spacing: 12) {
                Image(systemName: "cursorarrow.rays")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("No request selected")
                    .font(.title3.weight(.medium))
                Text("Choose a request from the sidebar, or use New to add one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Type-erased edit pipeline for request editors. `callAsFunction` lets
/// children keep natural trailing-closure syntax.
struct RequestCommitter {
    let apply: (@MainActor ((inout OCRequestSnapshot) -> Void) -> Void)

    @MainActor
    func callAsFunction(_ change: (inout OCRequestSnapshot) -> Void) {
        apply(change)
    }
}

private struct EditorContent: View {
    let app: AppState
    @State private var draft: OCRequestSnapshot
    @State private var section: Section = .params

    enum Section: String, CaseIterable, Identifiable {
        case params = "Params"
        case headers = "Headers"
        case auth = "Auth"
        case body = "Body"
        case captures = "Captures"
        case checks = "Checks"
        case scripts = "Scripts"
        case docs = "Docs"
        case settings = "Settings"

        var id: String { rawValue }
    }

    init(app: AppState, draft: OCRequestSnapshot) {
        self.app = app
        self.draft = draft
        let hasBody = draft.method.requestHasBody
        _section = State(initialValue: hasBody ? .body : .params)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    "Request name",
                    text: Binding(
                        get: { draft.name },
                        set: { newValue in commit { snapshot in snapshot.name = newValue } }
                    )
                )
                .font(.title3.weight(.semibold))
                .textFieldStyle(.plain)
                .accessibilityLabel("Request name")
                .background(InitialFocusClearer())

                HStack(spacing: 8) {
                    urlBar
                    sendControl
                }

                if let validationMessage = app.sendValidationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            TabStrip(
                tabs: Section.allCases,
                selection: $section,
                title: { $0.rawValue },
                badge: badgeCount
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            sectionContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var urlBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(HTTPMethod.allCases) { method in
                    Button(method.rawValue) {
                        commit { snapshot in snapshot.method = method.rawValue }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(draft.method)
                        .font(Theme.mono(.callout, weight: .bold))
                        .foregroundStyle(Theme.methodColor(draft.method))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("HTTP method")
            .accessibilityValue(draft.method)

            Divider()
                .frame(height: 16)

            VariableField(
                "https://example.com/path — or paste a cURL command",
                text: Binding(
                    get: { draft.url },
                    set: { newValue in commit { snapshot in snapshot.url = newValue } }
                ),
                variables: app.variableScope,
                fontSize: 13,
                onSubmit: { app.send() },
                onPaste: { text in importCurl(text) }
            )
            .accessibilityLabel("Request URL")

            if !activeVariables.isEmpty {
                Menu {
                    ForEach(activeVariables) { variable in
                        Button("{{\(variable.name)}}") { insertVariableAtCursor(variable) }
                    }
                } label: {
                    Image(systemName: "curlybraces")
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Insert a variable at the cursor")
                .accessibilityLabel("Insert a variable")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(Theme.hairline)
        )
    }

    @ViewBuilder
    private var sendControl: some View {
        if app.busy {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Button("Stop") { app.cancelSend() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
            }
        } else {
            Button {
                app.send()
            } label: {
                Label("Send", systemImage: "paperplane.fill")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(app.activeEnvironmentColor)
            .controlSize(.large)
            .shadow(color: (app.activeEnvironmentColor ?? .accentColor).opacity(app.canSend ? 0.35 : 0), radius: 8, y: 2)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!app.canSend)
            .help("Send request (⌘↩)")
            .accessibilityLabel("Send request")
        }
    }

    private func badgeCount(_ section: Section) -> Int {
        switch section {
        case .params: draft.params.filter { !$0.disabled }.count
        case .headers: draft.headers.filter { !$0.disabled }.count
        case .captures: draft.captures.filter { !$0.disabled }.count
        case .checks: draft.assertions.filter { !$0.disabled }.count
        case .scripts: draft.scripts.filter { !$0.code.isEmpty }.count
        case .docs: (draft.docs ?? "").isEmpty ? 0 : 1
        case .auth, .body, .settings: 0
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        let committer = RequestCommitter { change in commit(change) }
        switch section {
        case .params: ScrollView { ParamRows(app: app, draft: draft, commit: committer) }
        case .headers: ScrollView { HeaderRows(app: app, draft: draft, commit: committer) }
        case .auth: ScrollView { AuthSection(app: app, draft: draft, commit: committer) }
        case .body: BodySection(app: app, draft: draft, commit: committer)
        case .captures: ScrollView { CaptureRows(app: app, draft: draft, commit: committer) }
        case .checks: ScrollView { CheckRows(app: app, draft: draft, commit: committer) }
        case .scripts:
            ScriptsEditor(scripts: draft.scripts) { scripts in commit { $0.scripts = scripts } }
                .padding(16)
        case .docs:
            DocsEditor(text: draft.docs ?? "") { text in commit { $0.docs = text.isEmpty ? nil : text } }
                .padding(16)
        case .settings: ScrollView { SettingsSection(app: app, draft: draft, commit: committer) }
        }
    }

    // MARK: variable quick-add

    private var activeVariables: [OCVariable] {
        app.variableScope.values.keys.sorted().map { OCVariable(name: $0, value: "", secret: false, disabled: false) }
    }

    /// Replaces the request with a pasted cURL command; other text pastes normally.
    private func importCurl(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("curl "), let parsed = try? CurlParser.parse(trimmed) else { return false }
        commit { snapshot in
            snapshot.applyCurl(parsed)
        }
        app.statusMessage = parsed.warnings.isEmpty
            ? "Filled the request from the pasted cURL command"
            : "Filled from cURL. " + parsed.warnings.joined(separator: "; ")
        if parsed.bodyType != nil { section = .body }
        return true
    }

    private func insertVariableAtCursor(_ variable: OCVariable) {
        let token = "{{\(variable.name)}}"
        guard let editor = NSApp.keyWindow?.firstResponder as? NSText else {
            commit { $0.url += token }
            return
        }
        let location = min(editor.selectedRange.location, draft.url.utf16.count)
        var newURL = draft.url
        let index = newURL.index(newURL.startIndex, offsetBy: location)
        newURL.insert(contentsOf: token, at: index)
        commit { $0.url = newURL }
    }

    private func commit(_ change: (inout OCRequestSnapshot) -> Void) {
        var copy = draft
        change(&copy)
        draft = copy
        app.updateDraft(copy)
    }
}

// MARK: - Params

struct ParamRows: View {
    let app: AppState
    let draft: OCRequestSnapshot
    let commit: RequestCommitter

    var body: some View {
        KeyValueTable(
            rows: draft.params.map(\.kvRow),
            noun: "parameter",
            extraTitle: "Type",
            variables: app.variableScope,
            onEdit: { edit in commit { $0.params.apply(edit) } }
        ) { index in
            Picker("", selection: Binding(
                get: { draft.params[index].kind },
                set: { kind in commit { $0.params[index].kind = kind } }
            )) {
                Text("Query").tag("query")
                Text("Path").tag("path")
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Parameter location")
        }
        .padding(16)
    }
}

// MARK: - Headers

struct HeaderRows: View {
    let app: AppState
    let draft: OCRequestSnapshot
    let commit: RequestCommitter

    var body: some View {
        KeyValueTable(
            rows: draft.headers.map(\.kvRow),
            noun: "header",
            variables: app.variableScope,
            onEdit: { edit in commit { $0.headers.apply(edit) } }
        )
        .padding(16)
    }
}

// MARK: - Auth

struct AuthSection: View {
    let app: AppState
    let draft: OCRequestSnapshot
    let commit: RequestCommitter

    var body: some View {
        AuthEditor(auth: draft.authKind, variables: app.variableScope, tokenActions: app.tokenActions(at: app.selectedRequestPath)) { auth in
            commit { $0.authKind = auth }
        }
        .padding(16)
    }
}

// MARK: - Body

struct BodySection: View {
    let app: AppState
    let draft: OCRequestSnapshot
    let commit: RequestCommitter

    static let types: [(tag: String, title: String)] = [
        ("json", "JSON"),
        ("text", "Text"),
        ("xml", "XML"),
        ("form-urlencoded", "Form URL-Encoded"),
        ("multipart-form", "Multipart Form"),
        ("file", "Binary File"),
        ("graphql", "GraphQL"),
    ]

    private var type: String { draft.bodyType ?? "json" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.method.requestHasBody || draft.isGraphQL {
                HStack(spacing: 10) {
                    Picker("Type", selection: Binding(
                        get: { type },
                        set: { newValue in
                            commit { snapshot in
                                if newValue == "graphql", !snapshot.method.requestHasBody { snapshot.method = "POST" }
                                snapshot.bodyType = newValue
                            }
                        }
                    )) {
                        ForEach(Self.types, id: \.tag) { Text($0.title).tag($0.tag) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Body type")

                    if type == "json" {
                        Button("Format") {
                            if let formatted = JSONHighlighter.prettyPrint(draft.bodyData) {
                                commit { $0.bodyData = formatted }
                            }
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                }

                switch type {
                case "form-urlencoded":
                    ScrollView {
                        KeyValueTable(
                            rows: draft.formFields.map(\.kvRow),
                            noun: "field",
                            variables: app.variableScope,
                            onEdit: { edit in commit { $0.formFields.apply(edit) } }
                        )
                    }
                case "multipart-form":
                    ScrollView { multipartTable }
                case "file":
                    fileBody
                case "graphql":
                    graphqlBody
                default:
                    editor(Binding(get: { draft.bodyData }, set: { text in commit { $0.bodyData = text } }), json: type == "json")
                }
            } else {
                Text("\(draft.method) requests do not carry a body")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    private func editor(_ text: Binding<String>, json: Bool) -> some View {
        CodeEditor(text: text, highlightsJSON: json, variables: app.variableScope)
            .background(Theme.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.hairline))
            .frame(maxHeight: .infinity)
    }

    private var multipartTable: some View {
        KeyValueTable(
            rows: draft.formFields.map(\.kvRow),
            noun: "part",
            valuePlaceholder: "Value or file path",
            extraTitle: "Type",
            extraWidth: 112,
            variables: app.variableScope,
            onEdit: { edit in commit { $0.formFields.apply(edit) } }
        ) { index in
            HStack(spacing: 4) {
                Picker("", selection: Binding(
                    get: { draft.formFields[index].kind },
                    set: { kind in commit { $0.formFields[index].kind = kind } }
                )) {
                    Text("Text").tag("text")
                    Text("File").tag("file")
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Part type")

                if draft.formFields[index].kind == "file" {
                    IconButton(title: "Choose file", systemImage: "folder") {
                        app.chooseFile { path in commit { $0.formFields[index].value = path } }
                    }
                }
            }
        }
    }

    private var fileBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VariableField("Path to file — relative to the collection folder, or absolute", text: Binding(
                    get: { draft.filePath },
                    set: { path in commit { $0.filePath = path } }
                ))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                .accessibilityLabel("File path")
                Button("Choose…") {
                    app.chooseFile { path in commit { $0.filePath = path } }
                }
            }
            HStack(spacing: 8) {
                Text("Content-Type")
                    .font(.callout)
                TextField("Detected from the file extension", text: Binding(
                    get: { draft.fileContentType },
                    set: { type in commit { $0.fileContentType = type } }
                ))
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(.callout))
                .frame(maxWidth: 320)
            }
            Text("The file's bytes are sent as the request body. The collection stores only the path.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var graphqlBody: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Query").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                editor(Binding(get: { draft.bodyData }, set: { text in commit { $0.bodyData = text } }), json: false)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Variables (JSON)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                editor(Binding(get: { draft.graphqlVariables }, set: { text in commit { $0.graphqlVariables = text } }), json: true)
            }
            .frame(maxWidth: 360)
        }
    }
}

extension OCFormField {
    var kvRow: KVRow { KVRow(name: name, value: value, disabled: disabled) }
}

extension Array where Element == OCFormField {
    mutating func apply(_ edit: KVEdit) {
        edit.apply(to: &self, row: \.kvRow) { row, existing in
            OCFormField(
                name: row.name,
                value: row.value,
                kind: existing?.kind ?? "text",
                contentType: existing?.contentType ?? "",
                disabled: row.disabled
            )
        }
    }
}

// MARK: - Captures

struct CaptureRows: View {
    let app: AppState
    let draft: OCRequestSnapshot
    let commit: RequestCommitter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("After this response, values are extracted and stored for the next requests. Runtime scope stays in memory only — never saved to the collection file.")
                .font(.caption)
                .foregroundStyle(.secondary)

            FieldTable {
            ForEach(draft.captures.indices, id: \.self) { index in
                TableRow {
                    Toggle("", isOn: Binding(
                        get: { !draft.captures[index].disabled },
                        set: { enabled in update { snapshot in snapshot.captures[index].disabled = !enabled } }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 18)
                    .accessibilityLabel("Enable capture")

                    TextField("{{variable}}", text: Binding(
                        get: { draft.captures[index].variableName },
                        set: { newName in update { snapshot in snapshot.captures[index].variableName = newName } }
                    ))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(.callout))
                    .frame(width: 160)
                    .accessibilityLabel("Variable name")

                    Text("from")
                        .foregroundStyle(.tertiary)
                        .font(.caption)

                    TextField("$.access_token", text: Binding(
                        get: { draft.captures[index].expression },
                        set: { newExpression in update { snapshot in snapshot.captures[index].expression = newExpression } }
                    ))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(.callout))
                    .accessibilityLabel("Capture expression")

                    Picker("", selection: Binding(
                        get: { draft.captures[index].scope },
                        set: { newScope in update { snapshot in snapshot.captures[index].scope = newScope } }
                    )) {
                        Text("Runtime").tag("runtime")
                        Text("Environment").tag("environment")
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 130)
                    .accessibilityLabel("Capture scope")

                    RemoveRowButton(label: "Remove capture") {
                        update { snapshot in snapshot.captures.remove(at: index) }
                    }
                }
                .opacity(draft.captures[index].disabled ? 0.5 : 1)
            }

            AddRowButton(label: "Add capture") {
                update { snapshot in
                    snapshot.captures.append(OCCapture(
                        variableName: "",
                        expression: "$.",
                        scope: "runtime",
                        disabled: false
                    ))
                }
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func update(_ change: (inout OCRequestSnapshot) -> Void) {
        commit(change)
    }
}

// MARK: - Checks

struct CheckRows: View {
    let app: AppState
    let draft: OCRequestSnapshot
    let commit: RequestCommitter

    static let operators = ["eq", "neq", "gt", "gte", "lt", "lte", "contains", "startsWith", "endsWith", "isString", "isNumber", "isBoolean", "exists", "notExists"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checks run after every send and in folder runs. Expressions: res.status, res.time, res.body, res.body.<json path>, res.headers.<name>.")
                .font(.caption)
                .foregroundStyle(.secondary)

            FieldTable {
            ForEach(draft.assertions.indices, id: \.self) { index in
                TableRow {
                    Toggle("", isOn: Binding(
                        get: { !draft.assertions[index].disabled },
                        set: { enabled in commit { snapshot in snapshot.assertions[index].disabled = !enabled } }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 18)
                    .accessibilityLabel("Enable check")

                    TextField("res.status", text: Binding(
                        get: { draft.assertions[index].expression },
                        set: { newExpression in commit { snapshot in snapshot.assertions[index].expression = newExpression } }
                    ))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(.callout))
                    .frame(width: 220)
                    .accessibilityLabel("Check expression")

                    Picker("", selection: Binding(
                        get: { draft.assertions[index].op },
                        set: { newOp in commit { snapshot in snapshot.assertions[index].op = newOp } }
                    )) {
                        ForEach(Self.operators, id: \.self) { op in
                            Text(op).tag(op)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 120)
                    .accessibilityLabel("Check operator")

                    TextField("value", text: Binding(
                        get: { draft.assertions[index].value },
                        set: { newValue in commit { snapshot in snapshot.assertions[index].value = newValue } }
                    ))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(.callout))
                    .accessibilityLabel("Expected value")
                    .disabled(draft.assertions[index].op.hasPrefix("is") || draft.assertions[index].op == "exists" || draft.assertions[index].op == "notExists")

                    RemoveRowButton(label: "Remove check") {
                        commit { snapshot in snapshot.assertions.remove(at: index) }
                    }
                }
                .opacity(draft.assertions[index].disabled ? 0.5 : 1)
            }

            AddRowButton(label: "Add check") {
                commit { snapshot in
                    snapshot.assertions.append(OCAssertion(expression: "res.status", op: "eq", value: "200", disabled: false))
                }
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

// MARK: - Settings

struct SettingsSection: View {
    let app: AppState
    let draft: OCRequestSnapshot
    let commit: RequestCommitter
    @State private var timeoutText = ""

    private func update(_ change: (inout OCRequestSnapshot) -> Void) {
        commit(change)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Follow redirects", isOn: Binding(
                get: { draft.settings.followRedirects ?? true },
                set: { newValue in update { snapshot in snapshot.settings.followRedirects = newValue } }
            ))
            .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Text("Timeout (milliseconds)")
                    .font(.callout)
                TextField("0 = no timeout", text: $timeoutText)
                    .font(Theme.mono(.callout))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .onSubmit(commitTimeout)
                    .onDisappear { commitTimeout() }
                    .accessibilityLabel("Request timeout in milliseconds")
                Text("0 = no timeout")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .onAppear {
            timeoutText = String(draft.settings.timeout ?? 0)
        }
        .onChange(of: draft.settings.timeout) { _, value in
            let text = String(value ?? 0)
            if Int(text) != value {
                timeoutText = text
            }
        }
    }

    private func commitTimeout() {
        let trimmed = timeoutText.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value >= 0 else {
            timeoutText = String(draft.settings.timeout ?? 0)
            return
        }
        update { snapshot in snapshot.settings.timeout = value }
    }
}

/// AppKit focuses a window's first text field with its text selected, so one
/// stray key would rename the request. This clears that automatic focus once
/// the editor is in a window, including windows that aren't key yet.
struct InitialFocusClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClearingView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ClearingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            for delay in [0.0, 0.15, 0.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                          editor.selectedRange().length > 0, editor.selectedRange().length == (editor.string as NSString).length
                    else { return }
                    window.makeFirstResponder(nil)
                }
            }
        }
    }
}
