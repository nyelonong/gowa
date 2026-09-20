import SwiftUI

struct CollectionSidebar: View {
    let app: AppState

    var body: some View {
        @Bindable var app = app

        Group {
            if app.document != nil {
                treeList
            } else {
                emptyState
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 280)
        .alert("Rename", isPresented: Binding(
            get: { app.renameTarget != nil },
            set: { if !$0 { app.cancelRename() } }
        )) {
            TextField("Name", text: $app.renameText)
                .onSubmit { app.commitRename() }
            Button("Rename") { app.commitRename() }
            Button("Cancel", role: .cancel) { app.cancelRename() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Open a collection")
                .font(.headline)
            Text("Collections are OpenCollection YAML files you can keep in git.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("New") { app.newCollection() }
                Button("Open…") { app.openCollectionPanel() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var treeList: some View {
        List {
            ForEach(app.sidebarTree) { node in
                SidebarRow(app: app, node: node)
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    app.newCollection()
                } label: {
                    Image(systemName: "plus.square")
                }
                .help("New collection")

                Button {
                    app.openCollectionPanel()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Open collection (⌘O)")

                Button {
                    app.saveCollection()
                } label: {
                    Image(systemName: app.hasUnsavedChanges ? "square.and.arrow.up" : "checkmark.square")
                }
                .help(app.hasUnsavedChanges ? "Save (⌘S) — unsaved changes" : "Saved")
                .opacity(app.hasUnsavedChanges ? 1 : 0.5)

                if let url = app.document?.url {
                    Button {
                        app.revealCollectionInFinder()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Reveal in Finder")
                }
            }
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
