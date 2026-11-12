import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app
    @AppStorage("gowa.layout.sideBySide") private var sideBySide = true
    @AppStorage("gowa.layout.split.horizontal") private var horizontalSplit = 0.45
    @AppStorage("gowa.layout.split.vertical") private var verticalSplit = 0.5
    @AppStorage(Theme.glassKey) private var glass = true
    @AppStorage(Theme.ligaturesKey) private var ligatures = true
    @AppStorage(Theme.appearanceKey) private var appearance = Theme.Appearance.system.rawValue

    var body: some View {
        NavigationSplitView {
            CollectionSidebar(app: app)
        } detail: {
            detail
        }
        .background(WindowBackground(glass: glass).ignoresSafeArea())
        .toolbarBackgroundVisibility(glass ? .hidden : .automatic, for: .windowToolbar)
        .onChange(of: appearance, initial: true) { _, value in
            NSApp.appearance = (Theme.Appearance(rawValue: value) ?? .system).nsAppearance
        }
        .navigationTitle(app.draft?.name ?? app.document?.name ?? "Gowa")
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
                VStack(spacing: Theme.paneGap) {
                    if !app.missingSecrets.isEmpty {
                        missingSecretsBar
                    }

                    if app.draft != nil {
                        PaneSplit(
                            axis: sideBySide ? .horizontal : .vertical,
                            fraction: sideBySide ? $horizontalSplit : $verticalSplit,
                            minFirst: sideBySide ? 420 : 260,
                            minSecond: sideBySide ? 340 : 180
                        ) {
                            RequestEditor(app: app)
                                .id(EditorIdentity(path: app.selectedRequestPath, ligatures: ligatures))
                                .panel(glass: glass)
                        } second: {
                            ResponseArea(app: app)
                                .id(ligatures)
                                .panel(glass: glass)
                        }
                    } else if let grpc = app.grpcDraft {
                        GrpcView(app: app, draft: grpc)
                            .id(EditorIdentity(path: app.selectedRequestPath, ligatures: ligatures))
                            .panel(glass: glass)
                    } else if let socket = app.socketDraft {
                        WebSocketView(app: app, draft: socket)
                            .id(EditorIdentity(path: app.selectedRequestPath, ligatures: ligatures))
                            .panel(glass: glass)
                    } else {
                        RequestEditor(app: app)
                            .panel(glass: glass)
                    }
                }
                .padding([.horizontal, .bottom], Theme.paneGap)
                .padding(.top, 2)
                .overlay(alignment: .top) {
                    if let color = app.activeEnvironmentColor {
                        color
                            .frame(height: 2)
                            .shadow(color: color.opacity(0.9), radius: 6)
                            .ignoresSafeArea(edges: .top)
                            .accessibilityLabel("Environment \(app.activeEnvironment ?? "") color")
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
        .sheet(isPresented: Binding(
            get: { app.showingCode },
            set: { app.showingCode = $0 }
        )) {
            CodeSheet(app: app)
        }
        .sheet(isPresented: Binding(
            get: { app.showingHistory },
            set: { app.showingHistory = $0 }
        )) {
            HistorySheet(app: app)
        }
        .sheet(isPresented: Binding(
            get: { app.showingPalette },
            set: { app.showingPalette = $0 }
        )) {
            CommandPalette(app: app) { sideBySide.toggle() }
        }
        .sheet(isPresented: Binding(
            get: { app.showingCookies },
            set: { app.showingCookies = $0 }
        )) {
            CookiesSheet(app: app)
        }
        .sheet(item: Binding(
            get: { app.editingDefaults },
            set: { app.editingDefaults = $0 }
        )) { target in
            DefaultsSheet(app: app, target: target)
        }
        .sheet(isPresented: Binding(
            get: { app.showingRunner },
            set: { app.showingRunner = $0 }
        )) {
            RunnerSheet(app: app)
        }
        .toolbar {
            if app.document != nil {
                ToolbarItemGroup(placement: .primaryAction) {
                    environmentMenu

                    Button {
                        sideBySide.toggle()
                    } label: {
                        Label(
                            sideBySide ? "Response Below" : "Response Beside",
                            systemImage: sideBySide ? "rectangle.split.1x2" : "rectangle.split.2x1"
                        )
                    }
                    .help(sideBySide ? "Show the response below the request (⌥⌘L)" : "Show the response beside the request (⌥⌘L)")
                    .keyboardShortcut("l", modifiers: [.command, .option])

                    Button {
                        app.showingHistory = true
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .help("History of sent requests (⌘Y)")
                    .keyboardShortcut("y")

                    Button {
                        app.startRunner(under: nil)
                    } label: {
                        Label("Run All", systemImage: "play.fill")
                    }
                    .help("Run all requests (top to bottom)")

                    Button {
                        app.saveCollection()
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!app.hasUnsavedChanges && app.document?.url != nil)
                    .help("Save collection (⌘S)")
                }
            }
        }
    }

    private var environmentMenu: some View {
        Menu {
            Picker("Environment", selection: Binding(
                get: { app.activeEnvironment ?? "" },
                set: { app.activeEnvironment = $0.isEmpty ? nil : $0 }
            )) {
                Text("No environment").tag("")
                ForEach(app.environments) { environment in
                    Label {
                        Text(environment.name)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(Theme.color(hex: environment.color) ?? .secondary)
                    }
                    .tag(environment.name)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()
            Button("Manage Environments…") { app.showingEnvironmentManager = true }
        } label: {
            Label {
                Text(app.activeEnvironment ?? "No environment")
            } icon: {
                if let color = app.activeEnvironmentColor {
                    Theme.dot(color)
                } else {
                    Image(systemName: "globe")
                }
            }
            .labelStyle(.titleAndIcon)
        }
        .help("Choose or manage the active environment")
        .accessibilityLabel("Active environment: \(app.activeEnvironment ?? "none")")
    }

    private var missingSecretsBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.slash")
                .foregroundStyle(.orange)
            Text("Secret not stored: \(app.missingSecrets.joined(separator: ", ")) — requests that use it will not send until it is set")
                .font(.callout)
            Button("Set it") { app.showingEnvironmentManager = true }
                .controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.panelRadius))
    }

    private var welcome: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Gowa")
                .font(.largeTitle.weight(.bold))
            Text("A fast HTTP client with collections you keep in git.")
                .font(.title3)
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
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

/// Rebuilds an editor for another request, or when the code font changes
/// (text views read their font once, when created).
private struct EditorIdentity: Hashable {
    let path: NodePath?
    let ligatures: Bool
}
