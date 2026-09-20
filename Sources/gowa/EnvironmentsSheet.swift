import SwiftUI

/// Environment & variable manager. Secret variables are backed by the macOS
/// Keychain; the collection YAML stores their names only.
struct EnvironmentsSheet: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEnvironment: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Environments")
                    .font(.headline)
                Spacer()
                Button {
                    app.addEnvironment()
                } label: {
                    Label("Add Environment", systemImage: "plus")
                }
            }
            .padding(12)

            Divider()

            HStack(spacing: 0) {
                environmentList
                    .frame(width: 200)
                Divider()
                variablePane
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text("Secret values are stored in the macOS Keychain and never written to the collection file. Reference them in requests as {{name}}.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(10)
            }
        }
        .onAppear {
            if selectedEnvironment == nil {
                selectedEnvironment = app.activeEnvironment ?? app.environments.first?.name
            }
        }
    }

    private var environmentList: some View {
        List(selection: Binding(
            get: { selectedEnvironment },
            set: { selectedEnvironment = $0 }
        )) {
            ForEach(app.environments) { env in
                HStack {
                    Text(env.name)
                        .lineLimit(1)
                    Spacer()
                    Text("\(env.variables.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .tag(env.name)
                .contextMenu {
                    Button("Delete \"\(env.name)\"", role: .destructive) {
                        app.deleteEnvironment(env.name)
                        if selectedEnvironment == env.name { selectedEnvironment = nil }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var variablePane: some View {
        if let env = app.environments.first(where: { $0.name == selectedEnvironment }) {
            VariableRows(app: app, environment: env)
        } else {
            ContentUnavailableView(
                "No environment selected",
                systemImage: "square.stack.3d.up",
                description: Text("Pick an environment, or add one")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct VariableRows: View {
    let app: AppState
    let environment: OCEnvironmentSnapshot
    @State private var newVariableName = ""
    @FocusState private var newNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("New variable name", text: $newVariableName)
                    .font(.system(.callout, design: .monospaced))
                    .focused($newNameFocused)
                    .onSubmit(addVariable)

                Button("Add Variable") { addVariable() }
                    .disabled(newVariableName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)

            Divider()

            if environment.variables.isEmpty {
                ContentUnavailableView(
                    "No variables",
                    systemImage: "curlybraces.square",
                    description: Text("Variables interpolate into requests as {{name}}")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                variableRows
            }
        }
    }

    private var variableRows: some View {
        ScrollView {
            VStack(spacing: 0) {
                headerRow
                ForEach(environment.variables, id: \.name) { variable in
                    VariableRow(app: app, environment: environment, variable: variable)
                    Divider().opacity(0.4)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("Name").font(.caption.weight(.medium)).frame(width: 160, alignment: .leading)
            Text("Value").font(.caption.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
            Text("Secret").font(.caption.weight(.medium)).frame(width: 54)
            Text("On").font(.caption.weight(.medium)).frame(width: 34)
            Text("").frame(width: 22)
        }
        .padding(.horizontal, 12)
        .foregroundStyle(.secondary)
    }

    private func addVariable() {
        let name = newVariableName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        app.setVariable(
            OCVariable(name: name, value: "", secret: false, disabled: false),
            in: environment.name,
            previousName: nil
        )
        newVariableName = ""
        newNameFocused = true
    }
}

struct VariableRow: View {
    let app: AppState
    let environment: OCEnvironmentSnapshot
    let variable: OCVariable

    @State private var editingName: String
    @State private var editingValue: String
    @FocusState private var valueFocused: Bool

    init(app: AppState, environment: OCEnvironmentSnapshot, variable: OCVariable) {
        self.app = app
        self.environment = environment
        self.variable = variable
        // Secret values live in the keychain; show a stored marker instead of
        // the value itself.
        _editingName = State(initialValue: variable.name)
        _editingValue = State(initialValue: {
            if variable.secret { return app.storedSecretValue(environment: environment.name, variable: variable.name) ?? "" }
            return variable.value
        }())
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $editingName)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 160)
                .onSubmit { commitName() }

            if variable.secret {
                SecureField(isStored ? "•••• stored in Keychain" : "Enter value — stored in Keychain",
                            text: $editingValue)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit { commitValue() }
                    .onDisappear { commitValue() }

                if isStored {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .help("Value stored in the macOS Keychain")
                }
            } else {
                TextField("", text: $editingValue)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit { commitValue() }
            }

            Toggle("", isOn: Binding(
                get: { variable.secret },
                set: { isSecret in toggleSecret(isSecret) }
            ))
            .labelsHidden()
            .frame(width: 54)
            .help("Secret values are stored in the macOS Keychain, not in the collection file")

            Toggle("", isOn: Binding(
                get: { !variable.disabled },
                set: { enabled in
                    app.setVariable(
                        OCVariable(name: variable.name, value: effectiveStoredValue, secret: variable.secret, disabled: !enabled),
                        in: environment.name,
                        previousName: variable.name
                    )
                }
            ))
            .labelsHidden()
            .frame(width: 34)

            Button {
                app.deleteVariable(variable.name, in: environment.name)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: value plumbing

    private var isStored: Bool {
        variable.secret && !(app.storedSecretValue(environment: environment.name, variable: variable.name) ?? "").isEmpty
    }

    /// The authoritative value for writes: secret values go to the keychain;
    /// plain values stay in the YAML.
    private var effectiveStoredValue: String {
        if variable.secret {
            return app.storedSecretValue(environment: environment.name, variable: variable.name) ?? variable.value
        }
        return variable.value
    }

    private func commitName() {
        let name = editingName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != variable.name else { return }
        app.setVariable(
            OCVariable(name: name, value: effectiveStoredValue, secret: variable.secret, disabled: variable.disabled),
            in: environment.name,
            previousName: variable.name
        )
    }

    private func commitValue() {
        guard editingValue != effectiveStoredValue || !variable.secret else { return }
        if variable.secret {
            app.storeSecretValue(editingValue, environment: environment.name, variable: variable.name)
        } else {
            app.setVariable(
                OCVariable(name: variable.name, value: editingValue, secret: false, disabled: variable.disabled),
                in: environment.name,
                previousName: variable.name
            )
        }
    }

    private func toggleSecret(_ isSecret: Bool) {
        if isSecret {
            // Migrate the plain value into the keychain.
            if !variable.value.isEmpty {
                app.storeSecretValue(variable.value, environment: environment.name, variable: variable.name)
            }
            app.setVariable(
                OCVariable(name: variable.name, value: "", secret: true, disabled: variable.disabled),
                in: environment.name,
                previousName: variable.name
            )
        } else {
            // Migrate the keychain value back into the plain field.
            let value = app.storedSecretValue(environment: environment.name, variable: variable.name) ?? ""
            app.setVariable(
                OCVariable(name: variable.name, value: value, secret: false, disabled: variable.disabled),
                in: environment.name,
                previousName: variable.name
            )
        }
    }
}
