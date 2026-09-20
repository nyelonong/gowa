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
                Text("Pick one in the sidebar, or add a new one:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        app.addRequest(under: nil)
                    } label: {
                        Label("New Request", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Menu("New Folder") {
                        Button("At top level") { app.addFolder(under: nil) }
                    }
                    Button("Paste cURL…") { app.showingCurlImport = true }
                }
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
            HStack(spacing: 10) {
                Picker("Method", selection: Binding(
                    get: { draft.method },
                    set: { newValue in commit { snapshot in snapshot.method = newValue } }
                )) {
                    ForEach(HTTPMethod.allCases) { method in
                        Text(method.rawValue).tag(method.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()

                TextField(
                    "https://example.com/path",
                    text: Binding(
                        get: { draft.url },
                        set: { newValue in commit { snapshot in snapshot.url = newValue } }
                    )
                )
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit { app.send() }

                if !activeVariables.isEmpty {
                    Menu {
                        ForEach(activeVariables) { variable in
                            Button("{{\(variable.name)}}") { insertVariableAtCursor(variable) }
                        }
                    } label: {
                        Image(systemName: "curlybraces.square")
                    }
                    .help("Insert a variable at the cursor")
                }

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

            if !variableSuggestions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "curlybraces")
                        .foregroundStyle(.secondary)
                    Text("Complete:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(variableSuggestions) { variable in
                        Button("{{\(variable.name)}}") {
                            completeVariable(variable)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 520)
            .padding(.bottom, 8)

            switch section {
            case .params: ParamRows(app: app, draft: draft, commit: RequestCommitter { change in commit(change) })
            case .headers: HeaderRows(app: app, draft: draft, commit: RequestCommitter { change in commit(change) })
            case .auth: AuthSection(app: app, draft: draft, commit: RequestCommitter { change in commit(change) })
            case .body: BodySection(app: app, draft: draft, commit: RequestCommitter { change in commit(change) })
            case .captures: CaptureRows(app: app, draft: draft, commit: RequestCommitter { change in commit(change) })
            case .checks: CheckRows(app: app, draft: draft, commit: RequestCommitter { change in commit(change) })
            case .settings: SettingsSection(app: app, draft: draft, commit: RequestCommitter { change in commit(change) })
            }
        }
    }

    // MARK: variable quick-add

    private var activeVariables: [OCVariable] {
        app.environments
            .first(where: { $0.name == app.activeEnvironment })?
            .variables
            .filter { !$0.disabled && !$0.name.isEmpty } ?? []
    }

    private var trailingVariablePartial: String? {
        guard let match = draft.url.range(of: #"\{\{([A-Za-z0-9_]*)$"#, options: .regularExpression) else { return nil }
        return String(draft.url[match.lowerBound...])
    }

    private var variableSuggestions: [OCVariable] {
        guard let partial = trailingVariablePartial else { return [] }
        let typed = partial.dropFirst(2).lowercased()
        return activeVariables.filter { $0.name.lowercased().hasPrefix(typed) }
    }

    private func completeVariable(_ variable: OCVariable) {
        guard let match = draft.url.range(of: #"\{\{([A-Za-z0-9_]*)$"#, options: .regularExpression) else { return }
        var newURL = draft.url
        newURL.replaceSubrange(match, with: "{{\(variable.name)}}")
        commit { $0.url = newURL }
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

    private func update(_ change: (inout OCRequestSnapshot) -> Void) {
        commit(change)
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(draft.params.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { !draft.params[index].disabled },
                        set: { newValue in update { snapshot in snapshot.params[index].disabled = !newValue } }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    Picker("", selection: Binding(
                        get: { draft.params[index].kind },
                        set: { newValue in update { snapshot in snapshot.params[index].kind = newValue } }
                    )) {
                        Text("Query").tag("query")
                        Text("Path").tag("path")
                    }
                    .labelsHidden()
                    .frame(width: 84)

                    TextField("Name", text: Binding(
                        get: { draft.params[index].name },
                        set: { newValue in update { snapshot in snapshot.params[index].name = newValue } }
                    ))
                    .font(.system(.callout, design: .monospaced))

                    TextField("Value", text: Binding(
                        get: { draft.params[index].value },
                        set: { newValue in update { snapshot in snapshot.params[index].value = newValue } }
                    ))
                    .font(.system(.callout, design: .monospaced))

                    removeButton { update { snapshot in snapshot.params.remove(at: index) } }
                }
            }
            addButton("Add parameter") {
                update { snapshot in snapshot.params.append(OCParam(name: "", value: "", kind: "query", disabled: false)) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func addButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Label(label, systemImage: "plus.circle")
        }
        .buttonStyle(.plain)
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Headers

struct HeaderRows: View {
    let app: AppState
    let draft: OCRequestSnapshot
    let commit: RequestCommitter

    private func update(_ change: (inout OCRequestSnapshot) -> Void) {
        commit(change)
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(draft.headers.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { !draft.headers[index].disabled },
                        set: { newValue in update { snapshot in snapshot.headers[index].disabled = !newValue } }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    TextField("Name", text: Binding(
                        get: { draft.headers[index].name },
                        set: { newValue in update { snapshot in snapshot.headers[index].name = newValue } }
                    ))
                    .font(.system(.callout, design: .monospaced))

                    Text(":")
                        .foregroundStyle(.tertiary)

                    TextField("Value", text: Binding(
                        get: { draft.headers[index].value },
                        set: { newValue in update { snapshot in snapshot.headers[index].value = newValue } }
                    ))
                    .font(.system(.callout, design: .monospaced))

                    Button {
                        update { snapshot in snapshot.headers.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            Button {
                update { snapshot in snapshot.headers.append(OCHeader(name: "", value: "", disabled: false)) }
            } label: {
                Label("Add header", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

// MARK: - Auth

struct AuthSection: View {
    let app: AppState
    let draft: OCRequestSnapshot
    let commit: RequestCommitter

    private func update(_ change: (inout OCRequestSnapshot) -> Void) {
        commit(change)
    }

    private var kind: AuthKindUI {
        switch draft.authKind {
        case .none: .none
        case .inherit: .inherit
        case .basic: .basic
        case .bearer: .bearer
        case .apiKey: .apiKey
        case .preserved: .preserved
        }
    }

    enum AuthKindUI: String, CaseIterable, Identifiable {
        case none = "None"
        case inherit = "Inherit"
        case basic = "Basic"
        case bearer = "Bearer"
        case apiKey = "API Key"
        case preserved = "Custom"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Auth type", selection: Binding(
                get: { kind },
                set: { newValue in
                    commit { snapshot in
                        switch newValue {
                        case .none: snapshot.authKind = .none
                        case .inherit: snapshot.authKind = .inherit
                        case .basic: snapshot.authKind = .basic(username: "", password: "")
                        case .bearer: snapshot.authKind = .bearer(token: "")
                        case .apiKey: snapshot.authKind = .apiKey(key: "", value: "", placement: "header")
                        case .preserved: break // not settable
                        }
                    }
                }
            )) {
                ForEach(AuthKindUI.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 160)

            switch kind {
            case .basic:
                TextField("Username (supports {{vars}})", text: Binding(
                    get: { usernameOf(draft.authKind) },
                    set: { newValue in commit { snapshot in snapshot.authKind = .basic(username: newValue, password: passwordOf(snapshot.authKind)) } }
                ))
                .font(.system(.callout, design: .monospaced))
                SecureField("Password (supports {{vars}})", text: Binding(
                    get: { passwordOf(draft.authKind) },
                    set: { newValue in commit { snapshot in snapshot.authKind = .basic(username: usernameOf(snapshot.authKind), password: newValue) } }
                ))
                .font(.system(.callout, design: .monospaced))
            case .bearer:
                TextField("Token (supports {{vars}})", text: Binding(
                    get: { tokenOf(draft.authKind) },
                    set: { newValue in commit { snapshot in snapshot.authKind = .bearer(token: newValue) } }
                ))
                .font(.system(.callout, design: .monospaced))
            case .apiKey:
                TextField("Key name", text: Binding(
                    get: { apiKeyOf(draft.authKind).key },
                    set: { newValue in commit { snapshot in
                        let current = apiKeyOf(snapshot.authKind)
                        snapshot.authKind = .apiKey(key: newValue, value: current.value, placement: current.placement)
                    } }
                ))
                .font(.system(.callout, design: .monospaced))
                TextField("Value", text: Binding(
                    get: { apiKeyOf(draft.authKind).value },
                    set: { newValue in commit { snapshot in
                        let current = apiKeyOf(snapshot.authKind)
                        snapshot.authKind = .apiKey(key: current.key, value: newValue, placement: current.placement)
                    } }
                ))
                .font(.system(.callout, design: .monospaced))
                Picker("Add to", selection: Binding(
                    get: { apiKeyOf(draft.authKind).placement },
                    set: { newValue in commit { snapshot in
                        let current = apiKeyOf(snapshot.authKind)
                        snapshot.authKind = .apiKey(key: current.key, value: current.value, placement: newValue)
                    } }
                )) {
                    Text("Header").tag("header")
                    Text("Query").tag("query")
                }
                .frame(width: 140)
            case .none:
                Text("No authentication is applied.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .inherit:
                Text("Inherits auth from the parent folder or collection at send time (v3 preserves this flag; folder-level defaults execution arrives later).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            case .preserved:
                Text("This request uses an auth type Gowa can render but not edit (e.g. OAuth2). It is preserved in the YAML exactly as stored.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func usernameOf(_ kind: OAuthKind) -> String {
        if case .basic(let username, _) = kind { return username }
        return ""
    }

    private func passwordOf(_ kind: OAuthKind) -> String {
        if case .basic(_, let password) = kind { return password }
        return ""
    }

    private func tokenOf(_ kind: OAuthKind) -> String {
        if case .bearer(let token) = kind { return token }
        return ""
    }

    private func apiKeyOf(_ kind: OAuthKind) -> (key: String, value: String, placement: String) {
        if case .apiKey(let key, let value, let placement) = kind {
            return (key, value, placement)
        }
        return ("", "", "header")
    }
}

// MARK: - Body

struct BodySection: View {
    let app: AppState
    let draft: OCRequestSnapshot
    let commit: RequestCommitter

    private func update(_ change: (inout OCRequestSnapshot) -> Void) {
        commit(change)
    }

    private var carriesBody: Bool {
        draft.method.requestHasBody
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if carriesBody {
                HStack(spacing: 10) {
                    Picker("Type", selection: Binding(
                        get: { draft.bodyType ?? "json" },
                        set: { newValue in update { snapshot in snapshot.bodyType = newValue } }
                    )) {
                        Text("JSON").tag("json")
                        Text("Text").tag("text")
                        Text("XML").tag("xml")
                        Text("Form URL-Encoded").tag("form-urlencoded")
                    }
                    .frame(width: 190)

                    if (draft.bodyType ?? "json") == "json" {
                        Button("Format") {
                            if let formatted = JSONHighlighter.prettyPrint(draft.bodyData) {
                                update { snapshot in snapshot.bodyData = formatted }
                            }
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                }

                TextEditor(text: Binding(
                    get: { draft.bodyData },
                    set: { newValue in update { snapshot in snapshot.bodyData = newValue } }
                ))
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(minHeight: 140)
            } else {
                Text("\(draft.method) requests do not carry a body")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

// MARK: - Captures

struct CaptureRows: View {
    let app: AppState
    let draft: OCRequestSnapshot
    let commit: RequestCommitter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("After this response, values are extracted and stored for the next requests. Runtime scope stays in memory only — never saved to the collection file.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(draft.captures.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { !draft.captures[index].disabled },
                        set: { enabled in update { snapshot in snapshot.captures[index].disabled = !enabled } }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    TextField("{{variable}}", text: Binding(
                        get: { draft.captures[index].variableName },
                        set: { newName in update { snapshot in snapshot.captures[index].variableName = newName } }
                    ))
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 140)

                    Text("from")
                        .foregroundStyle(.tertiary)
                        .font(.caption)

                    TextField("$.access_token", text: Binding(
                        get: { draft.captures[index].expression },
                        set: { newExpression in update { snapshot in snapshot.captures[index].expression = newExpression } }
                    ))
                    .font(.system(.callout, design: .monospaced))

                    Picker("", selection: Binding(
                        get: { draft.captures[index].scope },
                        set: { newScope in update { snapshot in snapshot.captures[index].scope = newScope } }
                    )) {
                        Text("Runtime").tag("runtime")
                        Text("Environment").tag("environment")
                    }
                    .labelsHidden()
                    .frame(width: 130)

                    Button {
                        update { snapshot in snapshot.captures.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Button {
                update { snapshot in
                    snapshot.captures.append(OCCapture(
                        variableName: "",
                        expression: "$.",
                        scope: "runtime",
                        disabled: false
                    ))
                }
            } label: {
                Label("Add capture", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Checks run after every send and in folder runs. Expressions: res.status, res.time, res.body, res.body.<json path>, res.headers.<name>.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(draft.assertions.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { !draft.assertions[index].disabled },
                        set: { enabled in commit { snapshot in snapshot.assertions[index].disabled = !enabled } }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                    TextField("res.status", text: Binding(
                        get: { draft.assertions[index].expression },
                        set: { newExpression in commit { snapshot in snapshot.assertions[index].expression = newExpression } }
                    ))
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 200)

                    Picker("", selection: Binding(
                        get: { draft.assertions[index].op },
                        set: { newOp in commit { snapshot in snapshot.assertions[index].op = newOp } }
                    )) {
                        ForEach(Self.operators, id: \.self) { op in
                            Text(op).tag(op)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)

                    TextField("value", text: Binding(
                        get: { draft.assertions[index].value },
                        set: { newValue in commit { snapshot in snapshot.assertions[index].value = newValue } }
                    ))
                    .font(.system(.callout, design: .monospaced))
                    .disabled(draft.assertions[index].op.hasPrefix("is") || draft.assertions[index].op == "exists" || draft.assertions[index].op == "notExists")

                    Button {
                        commit { snapshot in snapshot.assertions.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Button {
                commit { snapshot in
                    snapshot.assertions.append(OCAssertion(expression: "res.status", op: "eq", value: "200", disabled: false))
                }
            } label: {
                Label("Add check", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

// MARK: - Settings

struct SettingsSection: View {
    let app: AppState
    let draft: OCRequestSnapshot
    let commit: RequestCommitter

    private func update(_ change: (inout OCRequestSnapshot) -> Void) {
        commit(change)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Follow redirects", isOn: Binding(
                get: { draft.settings.followRedirects ?? true },
                set: { newValue in update { snapshot in snapshot.settings.followRedirects = newValue } }
            ))
            .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Text("Timeout (ms, 0 = none)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("0", text: Binding(
                    get: { String(draft.settings.timeout ?? 0) },
                    set: { newValue in update { snapshot in snapshot.settings.timeout = Int(newValue) } }
                ))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 100)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}
