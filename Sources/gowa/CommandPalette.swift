import SwiftUI

struct PaletteItem: Identifiable {
    enum Kind { case request, environment, action }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let badge: String?
    let run: @MainActor () -> Void
}

enum PaletteSearch {
    /// Fuzzy score: every query character must appear in order; contiguous
    /// runs, word starts, and early matches score higher. nil = no match.
    static func score(_ query: String, _ candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let hay = Array(candidate.lowercased())
        var score = 0
        var position = 0
        var previous = -2
        for character in needle {
            guard let found = hay[position...].firstIndex(of: character) else { return nil }
            score += 1
            if found == previous + 1 { score += 5 }
            if found == 0 || !hay[found - 1].isLetter && !hay[found - 1].isNumber { score += 3 }
            score -= min(found - position, 10) / 3
            previous = found
            position = found + 1
        }
        return score
    }

    static func rank(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items
            .compactMap { item in score(query, item.title + " " + item.subtitle).map { (item, $0 + (score(query, item.title) ?? 0)) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

/// ⌘K: jump to any request, switch environments, or run an action by typing.
struct CommandPalette: View {
    let app: AppState
    let onToggleLayout: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = Array(PaletteSearch.rank(items, query: query).prefix(60))
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to a request, environment, or action", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { run(results) }
                    .onChange(of: query) { selection = 0 }
                    .onKeyPress(.downArrow) {
                        selection = min(selection + 1, max(results.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selection = max(selection - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == selection)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = index
                                    run(results)
                                }
                        }
                        if results.isEmpty {
                            Text("No matches")
                                .foregroundStyle(.secondary)
                                .padding(24)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
            .frame(height: 340)
        }
        .frame(width: 600)
        .onAppear { focused = true }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Group {
                switch item.kind {
                case .request:
                    Text(item.badge ?? "")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(item.badge == "GQL" ? Color.pink : Theme.methodColor(item.badge))
                case .environment:
                    Image(systemName: "globe").foregroundStyle(.secondary)
                case .action:
                    Image(systemName: "command").foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, alignment: .trailing)
            Text(item.title).lineLimit(1)
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func run(_ results: [PaletteItem]) {
        guard results.indices.contains(selection) else { return }
        let item = results[selection]
        dismiss()
        DispatchQueue.main.async { item.run() }
    }

    private var items: [PaletteItem] {
        var items: [PaletteItem] = []
        if let doc = app.document {
            let nodes = doc.enumerate()
            for node in nodes where !node.isFolder {
                let folders = (1..<max(node.path.count, 1)).compactMap { depth in
                    nodes.first { $0.path == Array(node.path.prefix(depth)) }?.name
                }
                items.append(PaletteItem(
                    id: "r" + node.id,
                    kind: .request,
                    title: node.name,
                    subtitle: (folders + [node.url ?? ""]).joined(separator: " › "),
                    badge: node.kind == "graphql" ? "GQL" : Theme.shortMethod(node.method),
                    run: { app.select(path: node.path) }
                ))
            }
            for environment in app.environments {
                items.append(PaletteItem(
                    id: "e" + environment.name, kind: .environment,
                    title: "Use environment: \(environment.name)", subtitle: "\(environment.variables.count) variables", badge: nil,
                    run: { app.activeEnvironment = environment.name }
                ))
            }
            items.append(PaletteItem(id: "e-none", kind: .environment, title: "Use no environment", subtitle: "", badge: nil) { app.activeEnvironment = nil })
        }
        let actions: [(String, String, @MainActor () -> Void)] = [
            ("New Request", "", { app.addRequest(under: nil) }),
            ("New Folder", "", { app.addFolder(under: nil) }),
            ("Paste cURL…", "Import a request", { app.showingCurlImport = true }),
            ("Send Request", "⌘↩", { app.send() }),
            ("Generate Code…", "cURL, HTTPie, JavaScript, Python, Go, Swift", { app.showingCode = true }),
            ("Save Collection", "⌘S", { app.saveCollection() }),
            ("Run All Requests", "Folder runner", { app.startRunner(under: nil) }),
            ("Manage Environments…", "", { app.showingEnvironmentManager = true }),
            ("Collection Settings…", "Headers, auth, variables, scripts, network", { app.editingDefaults = .collection }),
            ("Cookies…", "", { app.showingCookies = true }),
            ("History…", "Past requests and responses", { app.showingHistory = true }),
            ("Toggle Response Layout", "Beside or below", { onToggleLayout() }),
            ("Open Collection…", "⌘O", { app.openCollectionPanel() }),
        ]
        for (title, subtitle, run) in actions where app.document != nil || title.hasPrefix("Open") {
            items.append(PaletteItem(id: "a" + title, kind: .action, title: title, subtitle: subtitle, badge: nil, run: run))
        }
        return items
    }
}
