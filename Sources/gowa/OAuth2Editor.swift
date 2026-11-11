import SwiftUI

struct OAuth2Editor: View {
    let config: OCOAuth2
    var variables: VariableScope?
    var actions: OAuthTokenActions?
    let onChange: (OCOAuth2) -> Void
    @State private var fetching = false
    @State private var message: String?
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Grant type", selection: bind(\.flow)) {
                ForEach(OCOAuth2.Flow.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 340)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                if config.flow.usesBrowser {
                    row("Authorization URL", bind(\.authorizationUrl))
                }
                if config.flow != .implicit {
                    row("Access token URL", bind(\.accessTokenUrl))
                }
                if config.flow.usesBrowser {
                    row("Callback URL", bind(\.callbackUrl))
                }
                row("Client ID", bind(\.clientId))
                if config.flow != .implicit {
                    row("Client secret", bind(\.clientSecret), secure: true)
                }
                if config.flow == .password {
                    row("Username", bind(\.username))
                    row("Password", bind(\.password), secure: true)
                }
                row("Scope", bind(\.scope))
                if config.flow != .implicit {
                    row("Refresh token URL", bind(\.refreshTokenUrl), placeholder: "Defaults to the access token URL")
                }
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    if config.flow != .implicit {
                        Picker("Send client credentials", selection: bind(\.credentialsPlacement)) {
                            Text("As Basic auth header").tag("basic_auth_header")
                            Text("In the request body").tag("body")
                        }
                        .frame(maxWidth: 380)
                    }
                    if config.flow == .authorizationCode {
                        Toggle("Use PKCE (S256)", isOn: bind(\.pkceEnabled))
                            .toggleStyle(.checkbox)
                    }
                    Picker("Send token in", selection: Binding(
                        get: { config.tokenQuery.isEmpty ? "header" : "query" },
                        set: { place in
                            var next = config
                            if place == "query" {
                                next.tokenQuery = next.tokenQuery.isEmpty ? "access_token" : next.tokenQuery
                            } else {
                                next.tokenQuery = ""
                                if next.tokenHeader.isEmpty { next.tokenHeader = "Authorization" }
                            }
                            onChange(next)
                        }
                    )) {
                        Text("Header").tag("header")
                        Text("Query parameter").tag("query")
                    }
                    .frame(maxWidth: 300)
                    HStack {
                        Text(config.tokenQuery.isEmpty ? "Header name" : "Parameter name")
                        TextField("", text: config.tokenQuery.isEmpty ? bind(\.tokenHeader) : bind(\.tokenQuery))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                    }
                    Picker("Use", selection: bind(\.tokenSource)) {
                        Text("Access token").tag("access_token")
                        Text("ID token").tag("id_token")
                    }
                    .frame(maxWidth: 260)
                    Toggle("Fetch a token automatically when sending without one", isOn: bind(\.autoFetch))
                        .toggleStyle(.checkbox)
                    Toggle("Refresh expired tokens automatically", isOn: bind(\.autoRefresh))
                        .toggleStyle(.checkbox)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 520)

            if let actions {
                tokenStatus(actions)
            }

            Text("Saved in the collection file. Put client secrets and passwords in secret environment variables, e.g. {{clientSecret}}. Tokens are kept in the macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func tokenStatus(_ actions: OAuthTokenActions) -> some View {
        let _ = revision
        let token = actions.status(config)
        HStack(spacing: 10) {
            Button {
                fetching = true
                message = nil
                Task {
                    message = await actions.fetch(config)
                    fetching = false
                    revision += 1
                }
            } label: {
                Label("Get New Token", systemImage: "key.fill")
            }
            .disabled(fetching)
            if fetching { ProgressView().controlSize(.small) }
            if token != nil {
                Button("Clear Token") {
                    actions.clear(config)
                    revision += 1
                }
            }
        }
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let token {
            VStack(alignment: .leading, spacing: 2) {
                Text("Token: \(token.accessToken.prefix(12))…")
                    .font(.system(.caption, design: .monospaced))
                Text(expiry(token))
                    .font(.caption)
                    .foregroundStyle(token.isExpired() ? .orange : .secondary)
            }
        } else {
            Text("No token yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func expiry(_ token: OAuth2Token) -> String {
        guard let expires = token.expiresAt else { return "No expiry given" + (token.refreshToken != nil ? " · has refresh token" : "") }
        let relative = expires.formatted(.relative(presentation: .named))
        return (token.isExpired() ? "Expired " : "Expires ") + relative + (token.refreshToken != nil ? " · has refresh token" : "")
    }

    private func row(_ title: String, _ text: Binding<String>, secure: Bool = false, placeholder: String = "Supports {{vars}}") -> some View {
        GridRow {
            Text(title)
                .font(.callout)
                .gridColumnAlignment(.trailing)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                } else {
                    VariableField(placeholder, text: text, variables: variables)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            .frame(maxWidth: 440)
            .accessibilityLabel(title)
        }
    }

    private func bind<Value>(_ keyPath: WritableKeyPath<OCOAuth2, Value>) -> Binding<Value> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { value in
                var next = config
                next[keyPath: keyPath] = value
                onChange(next)
            }
        )
    }
}
