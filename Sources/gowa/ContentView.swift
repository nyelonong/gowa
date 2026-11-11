import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app
    @AppStorage("gowa.layout.sideBySide") private var sideBySide = false

    var body: some View {
        NavigationSplitView {
            CollectionSidebar(app: app)
        } detail: {
            detail
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
                VStack(spacing: 0) {
                    if let color = app.activeEnvironmentColor {
                        color.frame(height: 3)
                            .accessibilityLabel("Environment \(app.activeEnvironment ?? "") color")
                    }
                    if !app.missingSecrets.isEmpty {
                        missingSecretsBar
                    }

                    if app.draft != nil {
                        if sideBySide {
                            HSplitView {
                                RequestEditor(app: app)
                                    .id(app.selectedRequestPath)
                                    .frame(minWidth: 460, maxWidth: .infinity)
                                ResponseArea(app: app)
                                    .frame(minWidth: 360, maxWidth: .infinity)
                            }
                        } else {
                            VSplitView {
                                RequestEditor(app: app)
                                    .id(app.selectedRequestPath)
                                    .frame(minHeight: 300)
                                ResponseArea(app: app)
                                    .frame(minHeight: 180)
                                    .layoutPriority(1)
                            }
                        }
                    } else {
                        RequestEditor(app: app)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
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
