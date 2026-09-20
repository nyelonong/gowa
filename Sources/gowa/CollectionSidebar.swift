import SwiftUI

struct CollectionSidebar: View {
    let app: AppState

    static let widthDefaultsKey = "gowa.sidebar.width"

    static var savedWidth: CGFloat {
        let saved = UserDefaults.standard.double(forKey: widthDefaultsKey)
        return saved > 120 ? saved : 300
    }

    var body: some View {
        @Bindable var app = app

        Group {
            if app.document != nil {
                collectionContent
            } else {
                emptyState
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: Self.savedWidth, max: 520)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.width) { _, new in
                        guard new > 120 else { return }
                        UserDefaults.standard.set(new, forKey: Self.widthDefaultsKey)
                    }
            }
        )
        .alert("Rename", isPresented: Binding(
            get: { app.renameTarget != nil || app.renamingCollection },
            set: { if !$0 { app.cancelRename() } }
        )) {
            TextField("Name", text: $app.renameText)
                .onSubmit { app.commitRename() }
            Button("Rename") { app.commitRename() }
            Button("Cancel", role: .cancel) { app.cancelRename() }
        }
    }

    // MARK: - No collection open

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Welcome to Gowa")
                .font(.title3.weight(.semibold))
            Text("Organize HTTP requests in collections.\nEach collection is a YAML file you keep in git.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Button {
                    app.newCollection()
                } label: {
                    Label("Create a new collection", systemImage: "plus.circle.fill")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n")

                Button {
                    app.openCollectionPanel()
                } label: {
                    Label("Open a collection…", systemImage: "folder")
                        .frame(maxWidth: 200)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("o")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Collection open

    private var collectionContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if app.sidebarTree.isEmpty {
                emptyCollectionHint
            } else {
                treeList
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.document?.name ?? "Collection")
                        .font(.headline)
                        .lineLimit(1)
                    if let url = app.document?.url {
                        Text(url.lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    app.beginRenameCollection()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Rename collection (writes info.name on save)")
                if app.hasUnsavedChanges {
                    Circle()
                        .fill(.orange)
                        .frame(width: 7, height: 7)
                        .help("Unsaved changes — ⌘S to save")
                }
            }

            HStack(spacing: 8) {
                Menu {
                    Button("New Request") { app.addRequest(under: nil) }
                    Button("New Folder") { app.addFolder(under: nil) }
                    Divider()
                    Button("Paste cURL…") { app.showingCurlImport = true }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .fixedSize()

                Button("Open…") { app.openCollectionPanel() }

                Button {
                    app.saveCollection()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(!app.hasUnsavedChanges && app.document?.url != nil)

                Spacer(minLength: 0)

                if app.document?.url != nil {
                    Button {
                        app.revealCollectionInFinder()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Reveal collection file in Finder")
                }
            }

            if !app.environments.isEmpty {
                HStack(spacing: 6) {
                    Picker("Environment", selection: Binding(
                        get: { app.activeEnvironment ?? "" },
                        set: { app.activeEnvironment = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("No environment").tag("")
                        ForEach(app.environments) { env in
                            Text(env.name).tag(env.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    Button {
                        app.showingEnvironmentManager = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .help("Manage environments and variables")
                }
            }
        }
        .padding(10)
    }

    private var emptyCollectionHint: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.and.pencil")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("This collection is empty")
                .font(.callout.weight(.medium))
            Text("Add your first request to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Add a Request") { app.addRequest(under: nil) }
                .buttonStyle(.borderedProminent)
            Button("Paste cURL…") { app.showingCurlImport = true }
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Request") { app.addRequest(under: nil) }
            Button("New Folder") { app.addFolder(under: nil) }
        }
    }

    private var treeList: some View {
        List {
            ForEach(app.sidebarTree) { node in
                SidebarRow(app: app, node: node)
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("New Request") { app.addRequest(under: nil) }
            Button("New Folder") { app.addFolder(under: nil) }
        }
        .overlay(alignment: .bottom) {
            if let message = app.statusMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation { app.statusMessage = nil }
                    }
            }
        }
    }
}

struct SidebarRow: View {
    let app: AppState
    let node: SidebarNode
    @State private var isExpanded = true

    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    SidebarRow(app: app, node: child)
                }
            } label: {
                folderLabel
            }
        } else {
            requestLabel
                .tag(node.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    app.select(path: node.node.path)
                }
                .background(
                    app.selectedRequestPath == node.node.path
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear
                )
        }
    }

    private var folderLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(node.name)
                .lineLimit(1)
        }
        .contextMenu {
            Button("New Request") { app.addRequest(under: node.node.path) }
            Button("New Folder") { app.addFolder(under: node.node.path) }
            Divider()
            Button("Rename…") { app.beginRename(node.node.path) }
            Button("Duplicate") { app.duplicate(node.node.path) }
            Divider()
            Button("Delete", role: .destructive) { app.delete(node.node.path) }
        }
    }

    private var requestLabel: some View {
        HStack(spacing: 6) {
            Text(node.node.method ?? "HTTP")
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundStyle(methodColor)
                .frame(width: 46, alignment: .leading)
            Text(node.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contextMenu {
            Button("Copy as cURL") { app.copyAsCurl(at: node.node.path) }
            Divider()
            Button("Rename…") { app.beginRename(node.node.path) }
            Button("Duplicate") { app.duplicate(node.node.path) }
            Divider()
            Button("Delete", role: .destructive) { app.delete(node.node.path) }
        }
    }

    private var methodColor: Color {
        switch node.node.method {
        case "GET": .green
        case "POST": .blue
        case "PUT", "PATCH": .orange
        case "DELETE": .red
        default: .secondary
        }
    }
}
