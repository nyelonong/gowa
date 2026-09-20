import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationSplitView {
            CollectionSidebar(app: app)
        } detail: {
            detail
        }
        .navigationTitle("Gowa")
        .frame(minWidth: 960, minHeight: 620)
        .alert("Couldn't open collection", isPresented: Binding(
            get: { app.openErrorMessage != nil },
            set: { if !$0 { app.openErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.openErrorMessage ?? "")
        }
    }

    private var detail: some View {
        Group {
            if app.document == nil {
                welcome
            } else {
            VStack(spacing: 0) {
                if !app.missingSecrets.isEmpty {
                    missingSecretsBar
                }
                RequestEditor(app: app)
                if app.draft != nil {
                    Divider()
                    ResponseArea(app: app)
                }
            }
        }
        }
        .sheet(isPresented: Binding(
            get: { app.showingEnvironmentManager },
            set: { app.showingEnvironmentManager = $0 }
        )) {
            EnvironmentsSheet(app: app)
        }
        .sheet(isPresented: Binding(
            get: { app.showingCurlImport },
            set: { app.showingCurlImport = $0 }
        )) {
            CurlImportSheet(app: app)
        }
    }

    private var missingSecretsBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.slash")
                .foregroundStyle(.orange)
            Text("Secret not stored: \(app.missingSecrets.joined(separator: ", ")) — sends will fail until it is set")
                .font(.callout)
            Button("Set it") { app.showingEnvironmentManager = true }
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08))
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("Gowa")
                .font(.largeTitle.weight(.bold))
            Text("A fast HTTP client with collections you keep in git.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    app.newCollection()
                } label: {
                    Label("New Collection", systemImage: "plus.circle.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("n")

                Button {
                    app.openCollectionPanel()
                } label: {
                    Label("Open…", systemImage: "folder")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut("o")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
