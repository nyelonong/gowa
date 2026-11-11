import SwiftUI

/// Auth type picker and fields, shared by requests and folder/collection defaults.
struct AuthEditor: View {
    let auth: OAuthKind
    var variables: VariableScope?
    var inheritNote = "Uses the auth of the nearest parent folder, or the collection, at send time."
    let onChange: (OAuthKind) -> Void

    enum Kind: String, CaseIterable, Identifiable {
        case inherit = "Inherit"
        case none = "None"
        case basic = "Basic"
        case bearer = "Bearer"
        case apiKey = "API Key"
        case preserved = "Custom"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch auth {
        case .none: .none
        case .inherit: .inherit
        case .basic: .basic
        case .bearer: .bearer
        case .apiKey: .apiKey
        case .preserved: .preserved
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Auth type", selection: Binding(
                get: { kind },
                set: { newValue in
                    switch newValue {
                    case .none: onChange(.none)
                    case .inherit: onChange(.inherit)
                    case .basic: onChange(.basic(username: "", password: ""))
                    case .bearer: onChange(.bearer(token: ""))
                    case .apiKey: onChange(.apiKey(key: "", value: "", placement: "header"))
                    case .preserved: break
                    }
                }
            )) {
                ForEach(Kind.allCases.filter { $0 != .preserved || kind == .preserved }) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Auth type")

            switch auth {
            case .basic(let username, let password):
                field("Username", Binding(get: { username }, set: { onChange(.basic(username: $0, password: password)) }))
                field("Password", Binding(get: { password }, set: { onChange(.basic(username: username, password: $0)) }), secure: true)
            case .bearer(let token):
                field("Token", Binding(get: { token }, set: { onChange(.bearer(token: $0)) }))
            case .apiKey(let key, let value, let placement):
                field("Key name", Binding(get: { key }, set: { onChange(.apiKey(key: $0, value: value, placement: placement)) }))
                field("Value", Binding(get: { value }, set: { onChange(.apiKey(key: key, value: $0, placement: placement)) }))
                label("Add to")
                Picker("Add to", selection: Binding(
                    get: { placement },
                    set: { onChange(.apiKey(key: key, value: value, placement: $0)) }
                )) {
                    Text("Header").tag("header")
                    Text("Query").tag("query")
                }
                .labelsHidden()
                .fixedSize()
            case .none:
                note("No authentication is applied.")
            case .inherit:
                note(inheritNote)
            case .preserved:
                note("This auth type can't be edited in Gowa yet. It is kept in the YAML exactly as stored.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ title: String, _ text: Binding<String>, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            label(title)
            Group {
                if secure {
                    SecureField("Supports {{vars}}", text: text)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                } else {
                    VariableField("Supports {{vars}}", text: text, variables: variables)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            .frame(maxWidth: 460)
            .accessibilityLabel(title)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
