import SwiftUI

/// Headers, auth, variables, and docs that every request inside a folder
/// (or the whole collection) inherits.
struct DefaultsSheet: View {
    let app: AppState
    let target: AppState.DefaultsTarget
    @Environment(\.dismiss) private var dismiss
    @State private var defaults = OCDefaults()
    @State private var tab: Tab = .headers

    enum Tab: String, CaseIterable, Identifiable {
        case headers = "Headers"
        case auth = "Auth"
        case variables = "Variables"
        case scripts = "Scripts"
        case docs = "Docs"
        case network = "Network"
        var id: String { rawValue }
    }

    private var tabs: [Tab] {
        target == .collection ? Tab.allCases : Tab.allCases.filter { $0 != .network }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.defaultsTitle(for: target))
                        .font(.headline)
                    Text(target == .collection
                         ? "Applied to every request in the collection"
                         : "Applied to every request in this folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)

            TabStrip(tabs: tabs, selection: $tab, title: { $0.rawValue }, badge: badge)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch tab {
                    case .headers:
                        note("Request headers with the same name override these.")
                        KeyValueTable(rows: defaults.headers.map(\.kvRow), noun: "header") { edit in
                            change { $0.headers.apply(edit) }
                        }
                    case .auth:
                        AuthEditor(
                            auth: defaults.auth,
                            tokenActions: app.tokenActions(at: target.path),
                            inheritNote: target == .collection
                                ? "No collection-wide auth. Requests set inherit fall back to none."
                                : "Uses the parent folder's or the collection's auth."
                        ) { auth in
                            change { $0.auth = auth }
                        }
                        note("Requests whose auth is Inherit use this.")
                    case .variables:
                        note("Folder variables override environment and collection variables; request and captured values override these.")
                        KeyValueTable(rows: defaults.variables.map(\.kvRow), noun: "variable") { edit in
                            change { $0.variables.apply(edit) }
                        }
                    case .docs:
                        TextEditor(text: Binding(
                            get: { defaults.docs ?? "" },
                            set: { text in change { $0.docs = text } }
                        ))
                        .font(.system(.callout, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 260)
                        .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.hairline))
                        note("Markdown. Saved in the collection file.")
                    case .network:
                        NetworkSettingsView(app: app)
                    case .scripts:
                        note("Runs for every request inside, before the request's own scripts.")
                        ScriptsEditor(scripts: defaults.scripts) { scripts in change { $0.scripts = scripts } }
                            .frame(minHeight: 320)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { defaults = app.defaults(for: target) }
    }

    private func badge(_ tab: Tab) -> Int {
        switch tab {
        case .headers: defaults.headers.filter { !$0.disabled }.count
        case .variables: defaults.variables.filter { !$0.disabled }.count
        case .scripts: defaults.scripts.filter { !$0.code.isEmpty }.count
        case .auth, .docs, .network: 0
        }
    }

    private func change(_ edit: (inout OCDefaults) -> Void) {
        edit(&defaults)
        app.updateDefaults(defaults, for: target)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
