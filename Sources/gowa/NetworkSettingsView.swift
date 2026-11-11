import SwiftUI

/// Collection-wide proxy, client certificates, TLS verification, and cookies.
struct NetworkSettingsView: View {
    let app: AppState
    @State private var settings = OCNetworkSettings()
    @State private var showingCookies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Proxy") {
                Picker("Proxy", selection: bind(\.proxy.mode)) {
                    ForEach(OCProxy.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                switch settings.proxy.mode {
                case .system:
                    note("Uses the proxy configured in macOS System Settings.")
                case .off:
                    note("Connects directly, ignoring any system proxy.")
                case .custom:
                    HStack(spacing: 8) {
                        Picker("Protocol", selection: bind(\.proxy.scheme)) {
                            Text("HTTP").tag("http")
                            Text("HTTPS").tag("https")
                            Text("SOCKS5").tag("socks5")
                        }
                        .labelsHidden()
                        .fixedSize()
                        TextField("Host", text: bind(\.proxy.hostname))
                            .textFieldStyle(.roundedBorder)
                        TextField("Port", value: bind(\.proxy.port), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                    }
                    .frame(maxWidth: 480)
                    Toggle("Proxy requires a username and password", isOn: bind(\.proxy.authEnabled))
                        .toggleStyle(.checkbox)
                    if settings.proxy.authEnabled {
                        HStack(spacing: 8) {
                            TextField("Username", text: bind(\.proxy.username))
                            SecureField("Password — use {{secretVar}}", text: bind(\.proxy.password))
                        }
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 480)
                        note("These are saved in the collection file. Reference a secret environment variable such as {{proxyPassword}} to keep the password in the Keychain.")
                    }
                    TextField("Bypass for hosts (comma-separated, e.g. localhost, *.internal)", text: bind(\.proxy.bypass))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 480)
                }
            }

            section("Client certificates") {
                note("Sent when a server asks for mutual TLS. Gowa reads PKCS#12 (.p12 / .pfx) files.")
                ForEach(settings.clientCertificates.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { !settings.clientCertificates[index].disabled },
                            set: { enabled in change { $0.clientCertificates[index].disabled = !enabled } }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("Enable certificate")
                        TextField("Domain, e.g. api.example.com or *.example.com", text: bind(\.clientCertificates[index].domain))
                            .frame(width: 220)
                        TextField("Path to .p12", text: bind(\.clientCertificates[index].path))
                        Button("Choose…") {
                            app.chooseFile { path in change { $0.clientCertificates[index].path = path } }
                        }
                        SecureField("Passphrase", text: bind(\.clientCertificates[index].passphrase))
                            .frame(width: 130)
                        RemoveRowButton(label: "Remove certificate") {
                            change { $0.clientCertificates.remove(at: index) }
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    if settings.clientCertificates[index].type == "pem" {
                        Label("PEM certificates aren't supported; convert to .p12 with openssl pkcs12 -export.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Button {
                    change { $0.clientCertificates.append(OCClientCertificate()) }
                } label: {
                    Label("Add certificate", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            section("TLS") {
                Toggle("Verify server certificates", isOn: bind(\.verifyTLS))
                    .toggleStyle(.checkbox)
                if !settings.verifyTLS {
                    Label("Gowa accepts any certificate for this collection's requests, including forged ones. Use only for local or test servers.", systemImage: "exclamationmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("Cookies") {
                Toggle("Store cookies from responses and send them back", isOn: bind(\.storeCookies))
                    .toggleStyle(.checkbox)
                note("Each collection has its own cookie jar. Cookies with an expiry date are kept between launches.")
                Button("Manage Cookies…") { showingCookies = true }
            }
        }
        .onAppear { settings = app.networkSettings }
        .sheet(isPresented: $showingCookies) { CookiesSheet(app: app) }
    }

    private func bind<Value>(_ keyPath: WritableKeyPath<OCNetworkSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in change { $0[keyPath: keyPath] = value } }
        )
    }

    private func change(_ edit: (inout OCNetworkSettings) -> Void) {
        edit(&settings)
        app.networkSettings = settings
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CookiesSheet: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = app.cookieRevision
        let cookies = app.cookieJar?.all ?? []
        let domains = Dictionary(grouping: cookies, by: \.domain).sorted { $0.key < $1.key }
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cookies").font(.headline)
                    Text("\(cookies.count) stored for \(app.document?.name ?? "this collection")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Delete All", role: .destructive) { app.cookieJar?.deleteAll() }
                    .disabled(cookies.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            if cookies.isEmpty {
                ContentUnavailableView("No cookies", systemImage: "birthday.cake", description: Text("Cookies set by responses appear here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(domains, id: \.key) { domain, entries in
                        Section {
                            ForEach(entries, id: \.self) { cookie in
                                CookieRow(cookie: cookie) { app.cookieJar?.delete(cookie) }
                            }
                        } header: {
                            HStack {
                                Text(domain)
                                Spacer()
                                Button("Delete") { app.cookieJar?.deleteAll(domain: domain) }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
    }
}

struct CookieRow: View {
    let cookie: HTTPCookie
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cookie.name).font(.system(.callout, design: .monospaced).weight(.medium))
                    Text(cookie.value)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let onDelete {
                RemoveRowButton(label: "Delete cookie", action: onDelete)
            }
        }
    }

    private var details: String {
        var parts = ["Path \(cookie.path)"]
        if let expires = cookie.expiresDate {
            parts.append("expires \(expires.formatted(date: .abbreviated, time: .shortened))")
        } else {
            parts.append("session")
        }
        if cookie.isSecure { parts.append("Secure") }
        if cookie.isHTTPOnly { parts.append("HttpOnly") }
        if let policy = cookie.sameSitePolicy { parts.append("SameSite=\(policy.rawValue)") }
        return parts.joined(separator: " · ")
    }
}
