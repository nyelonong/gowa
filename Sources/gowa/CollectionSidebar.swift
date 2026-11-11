import SwiftUI

struct CollectionSidebar: View {
    let app: AppState
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

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
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No collection open")
                .font(.headline)
            Text("Open a collection to begin.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                app.openCollectionPanel()
            } label: {
                Label("Open Collection…", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Collection open

    private var collectionContent: some View {
        VStack(spacing: 0) {
            content
            if app.document?.url != nil {
                Divider()
                GitFooter(app: app)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshGitStatus()
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            if app.sidebarTree.isEmpty {
                Divider()
                emptyCollectionHint
            } else {
                searchField
                Divider()
                if visibleTree.isEmpty {
                    noMatches
                } else {
                    treeList
                }
            }
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var visibleTree: [SidebarNode] {
        SidebarNode.filter(app.sidebarTree, query: searchText)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search requests", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    if isSearching, let first = SidebarNode.firstRequest(in: visibleTree) {
                        app.select(path: first.node.path)
                    }
                }
                .onExitCommand {
                    searchText = ""
                    searchFocused = false
                }
                .accessibilityLabel("Search requests")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .background(
            Button("Search Requests") { searchFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .hidden()
        )
    }

    private var noMatches: some View {
        VStack(spacing: 6) {
            Text("No matches")
                .font(.callout.weight(.medium))
            Text("No request name, URL, or method contains “\(searchText.trimmingCharacters(in: .whitespaces))”.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.document?.name ?? "Collection")
                        .font(.headline)
                        .lineLimit(1)
                    if app.hasUnsavedChanges {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                            .help("Unsaved changes — ⌘S to save")
                            .accessibilityLabel("Unsaved changes")
                    }
                }
                if let url = app.document?.url {
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button("New Request") { app.addRequest(under: nil) }
                Button("New WebSocket") { app.addWebSocket(under: nil) }
                Button("New Folder") { app.addFolder(under: nil) }
                Divider()
                Button("Paste cURL…") { app.showingCurlImport = true }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New request, folder, or cURL import")
            .accessibilityLabel("New")

            Menu {
                Button("Collection Settings…") { app.editingDefaults = .collection }
                Button("Cookies…") { app.showingCookies = true }
                Divider()
                Button("Rename Collection…") { app.beginRenameCollection() }
                Button("Open Collection…") { app.openCollectionPanel() }
                if app.document?.url != nil {
                    Button("Reveal in Finder") { app.revealCollectionInFinder() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Collection actions")
            .accessibilityLabel("Collection actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            app.move(nodeID: id, toParent: nil, index: nil)
            return true
        }
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
            ForEach(visibleTree) { node in
                SidebarRow(app: app, node: node, forceExpanded: isSearching)
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
    var forceExpanded = false
    @State private var isExpanded = true
    @State private var isDropTarget = false

    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: forceExpanded ? .constant(true) : $isExpanded) {
                ForEach(node.children) { child in
                    SidebarRow(app: app, node: child, forceExpanded: forceExpanded)
                }
            } label: {
                folderLabel
                    .draggable(node.id)
                    .dropDestination(for: String.self) { ids, _ in
                        guard let id = ids.first, id != node.id else { return false }
                        app.move(nodeID: id, toParent: node.node.path, index: nil)
                        isExpanded = true
                        return true
                    } isTargeted: { isDropTarget = $0 }
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.accentColor, lineWidth: isDropTarget ? 2 : 0)
                    )
            }
        } else {
            requestLabel
                .draggable(node.id)
                .dropDestination(for: String.self) { ids, _ in
                    guard let id = ids.first, id != node.id else { return false }
                    let parent = Array(node.node.path.dropLast())
                    app.move(nodeID: id, toParent: parent.isEmpty ? nil : parent, index: node.node.path.last)
                    return true
                } isTargeted: { isDropTarget = $0 }
                .overlay(alignment: .top) {
                    if isDropTarget {
                        Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -3)
                    }
                }
                .tag(node.id)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    app.select(path: node.node.path)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(isSelected ? 0.2 : 0))
                        .padding(.horizontal, 8)
                )
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var isSelected: Bool {
        app.selectedRequestPath == node.node.path
    }

    private var folderLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(node.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
        .contextMenu {
            Button("Run all") { app.startRunner(under: node.node.path) }
            Button("Folder Settings…") { app.editingDefaults = .folder(node.node.path) }
            Divider()
            Button("New Request") { app.addRequest(under: node.node.path) }
            Button("New WebSocket") { app.addWebSocket(under: node.node.path) }
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
            Text(Theme.badge(kind: node.node.kind, method: node.node.method))
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.badgeColor(kind: node.node.kind, method: node.node.method))
                .frame(width: 36, alignment: .trailing)
                .accessibilityLabel(node.node.method ?? "HTTP")
            Text(node.name)
                .font(.callout)
                .fontWeight(isSelected ? .medium : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contextMenu {
            Button("Copy as cURL") { app.copyAsCurl(at: node.node.path) }
            Button("Generate Code…") {
                app.select(path: node.node.path)
                app.showingCode = true
            }
            Divider()
            Button("Rename…") { app.beginRename(node.node.path) }
            Button("Duplicate") { app.duplicate(node.node.path) }
            Divider()
            Button("Delete", role: .destructive) { app.delete(node.node.path) }
        }
    }
}

struct GitFooter: View {
    let app: AppState
    @State private var showingChanges = false

    var body: some View {
        HStack(spacing: 6) {
            if let status = app.gitStatus {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(status.branch)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if status.ahead > 0 { Text("↑\(status.ahead)").font(.caption).foregroundStyle(.secondary) }
                if status.behind > 0 { Text("↓\(status.behind)").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                Button {
                    showingChanges.toggle()
                } label: {
                    Text(summary(status))
                        .font(.caption)
                        .foregroundStyle(status.collectionChange == nil ? Color.secondary : Color.orange)
                }
                .buttonStyle(.plain)
                .help("Show changed files")
                .popover(isPresented: $showingChanges, arrowEdge: .top) { changes(status) }
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.tertiary)
                Text("Not in a git repository")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private func summary(_ status: GitStatus) -> String {
        if let change = status.collectionChange { return "collection \(change.label)" }
        return status.changes.isEmpty ? "clean" : "\(status.changes.count) changed"
    }

    private func changes(_ status: GitStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(status.changes.isEmpty ? "Working tree clean" : "Uncommitted changes")
                .font(.headline)
            ForEach(status.changes.prefix(40)) { change in
                HStack(spacing: 8) {
                    Text(change.code.trimmingCharacters(in: .whitespaces))
                        .font(.system(.caption, design: .monospaced).weight(.bold))
                        .foregroundStyle(change.code.contains("?") ? Color.green : Color.orange)
                        .frame(width: 22, alignment: .leading)
                    Text(change.path)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(change == status.collectionChange ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if status.changes.count > 40 {
                Text("and \(status.changes.count - 40) more").font(.caption).foregroundStyle(.secondary)
            }
            Text("Commit from your terminal or git client; Gowa only reads git status.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(14)
        .frame(minWidth: 280, maxWidth: 420, alignment: .leading)
    }
}
