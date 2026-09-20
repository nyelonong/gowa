import AppKit
import Foundation
import Observation

struct HeaderField: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var value = ""
}

/// Hierarchical view of the collection for the sidebar tree.
struct SidebarNode: Identifiable {
    let node: OCNode
    let children: [SidebarNode]

    var id: String { node.id }
    var name: String { node.name }
    var isFolder: Bool { node.isFolder }
}

@MainActor
@Observable
final class AppState {
    // Collection
    var document: OpenCollectionDocument?
    var hasUnsavedChanges = false
    var sidebarTree: [SidebarNode] = []
    var statusMessage: String?

    // Selection
    var selectedRequestPath: NodePath?
    var draft: OCRequestSnapshot?

    // Rename flow
    var renameTarget: NodePath?
    var renameText: String = ""

    // Environment
    var activeEnvironment: String?
    var environments: [OCEnvironmentSnapshot] = []
    var showingEnvironmentManager = false

    /// Secret variables of the active environment with no stored value.
    var missingSecrets: [String] {
        document?.resolveVariables(in: activeEnvironment).missingSecrets ?? []
    }

    // Send state
    var busy = false
    var result: HTTPResult?
    var bodyDisplay: BodyDisplay?
    var errorText: String?

    let history = HistoryStore()
    private let client = HTTPClient()

    var canSend: Bool { draft != nil && !busy }
    // MARK: - Collection lifecycle

    func newCollection() {
        let doc = OpenCollectionDocument.sample()
        var starter = OCRequestSnapshot(
            name: "My First Request",
            method: "GET",
            url: "{{baseUrl}}/users",
            params: [],
            headers: [],
            bodyType: nil,
            bodyData: "",
            authKind: .none,
            settings: OCSettings(followRedirects: nil, timeout: nil),
            docs: nil
        )
        let path = doc.addRequest(under: nil, snapshot: starter)
        apply(doc)
        select(path: path)
        statusMessage = "New collection — ⌘S to save it into a git repo"
    }

    func openCollectionPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Collection"
        panel.allowedContentTypes = [.yaml]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        presentAsSheet(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            self.openCollection(at: url)
        }
    }

    /// File panels attach as sheets to the key window so they can never
    /// drift to a detached position (e.g. a secondary display).
    private func presentAsSheet(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    func openCollection(at url: URL) {
        do {
            let doc = try OpenCollectionDocument.load(from: url)
            apply(doc)
            statusMessage = nil
        } catch {
            statusMessage = "Failed to open: \(error.localizedDescription)"
        }
    }

    func saveCollection() {
        guard let doc = document else { return }
        do {
            if doc.url == nil {
                saveCollectionAs()
            } else {
                try doc.save()
                hasUnsavedChanges = false
                statusMessage = "Saved"
            }
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    func saveCollectionAs() {
        guard let doc = document else { return }
        let panel = NSSavePanel()
        panel.title = "Save Collection"
        panel.allowedContentTypes = [.yaml]
        panel.nameFieldStringValue = sanitizeFileName(doc.name) + ".yml"
        panel.directoryURL = defaultWorkspaceDirectory
        presentAsSheet(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try doc.save(to: url)
                self.hasUnsavedChanges = false
                self.defaultWorkspaceDirectory = url.deletingLastPathComponent()
                self.statusMessage = "Saved to \(url.lastPathComponent) — commit it with git"
            } catch {
                self.statusMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    func revealCollectionInFinder() {
        guard let url = document?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func apply(_ doc: OpenCollectionDocument) {
        document = doc
        hasUnsavedChanges = false
        selectedRequestPath = nil
        draft = nil
        result = nil
        bodyDisplay = nil
        errorText = nil
        rebuildSidebar()
        let envs = doc.environments
        environments = envs
        activeEnvironment = envs.first?.name
    }

    private func rebuildSidebar() {
        guard let doc = document else {
            sidebarTree = []
            return
        }
        sidebarTree = Self.buildTree(doc.enumerate())
    }

    static func buildTree(_ nodes: [OCNode]) -> [SidebarNode] {
        var index = 0
        func consume(_ depth: Int) -> [SidebarNode] {
            var result: [SidebarNode] = []
            while index < nodes.count, nodes[index].path.count == depth + 1 {
                let node = nodes[index]
                index += 1
                let children = node.isFolder ? consume(depth + 1) : []
                result.append(SidebarNode(node: node, children: children))
            }
            return result
        }
        return consume(0)
    }

    // MARK: - Selection

    func select(path: NodePath) {
        guard let doc = document else { return }
        if let snapshot = doc.requestSnapshot(at: path) {
            selectedRequestPath = path
            draft = snapshot
            result = nil
            bodyDisplay = nil
            errorText = nil
        } else {
            // Folder selected: keep request selection independent.
            selectedRequestPath = nil
            draft = nil
        }
    }

    func updateDraft(_ snapshot: OCRequestSnapshot) {
        guard let doc = document, let path = selectedRequestPath else { return }
        draft = snapshot
        doc.updateRequest(at: path, snapshot: snapshot)
        hasUnsavedChanges = true
        rebuildSidebar()
        environments = doc.environments
    }

    // MARK: - Tree mutations

    func addRequest(under parent: NodePath?) {
        guard document != nil else { return }
        var snapshot = OCRequestSnapshot(
            name: "New Request",
            method: "GET",
            url: "https://",
            params: [],
            headers: [],
            bodyType: nil,
            bodyData: "",
            authKind: .none,
            settings: OCSettings(followRedirects: nil, timeout: nil),
            docs: nil
        )
        snapshot.name = uniqueName("New Request", among: siblingNames(under: parent))
        guard let doc = document else { return }
        let path = doc.addRequest(under: parent, snapshot: snapshot)
        markDirtyAndRebuild()
        select(path: path)
    }

    func addFolder(under parent: NodePath?) {
        guard let doc = document else { return }
        let name = uniqueName("New Folder", among: siblingNames(under: parent))
        let path = doc.addFolder(under: parent, name: name)
        markDirtyAndRebuild()
        select(path: path)
    }

    func renameSelection(_ path: NodePath, to name: String) {
        guard let doc = document, !name.isEmpty else { return }
        doc.rename(at: path, to: name)
        markDirtyAndRebuild()
        if path == selectedRequestPath, let snapshot = doc.requestSnapshot(at: path) {
            draft = snapshot
        }
    }

    func beginRename(_ path: NodePath) {
        guard let doc = document,
              let node = doc.enumerate().first(where: { $0.path == path })
        else { return }
        renameTarget = path
        renameText = node.name
    }

    func commitRename() {
        guard let target = renameTarget else { return }
        renameSelection(target, to: renameText)
        renameTarget = nil
    }

    func cancelRename() {
        renameTarget = nil
    }

    func duplicate(_ path: NodePath) {
        guard let doc = document else { return }
        doc.duplicate(at: path)
        markDirtyAndRebuild()
    }

    func delete(_ path: NodePath) {
        guard let doc = document else { return }
        doc.delete(at: path)
        if selectedRequestPath?.starts(with: path) == true {
            selectedRequestPath = nil
            draft = nil
        }
        markDirtyAndRebuild()
    }

    private func markDirtyAndRebuild() {
        hasUnsavedChanges = true
        rebuildSidebar()
    }

    private func siblingNames(under parent: NodePath?) -> [String] {
        guard let doc = document else { return [] }
        let prefix = parent ?? []
        return doc.enumerate()
            .filter { $0.path.count == prefix.count + 1 && Array($0.path.dropLast()) == prefix }
            .map(\.name)
    }

    private func uniqueName(_ base: String, among existing: [String]) -> String {
        guard existing.contains(base) else { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Environment management

    func refreshEnvironments() {
        guard let doc = document else { return }
        environments = doc.environments
        if let active = activeEnvironment, !environments.contains(where: { $0.name == active }) {
            activeEnvironment = environments.first?.name
        }
        rebuildSidebar()
    }

    func addEnvironment() {
        guard let doc = document else { return }
        var envs = doc.environments
        var n = envs.count + 1
        while envs.contains(where: { $0.name == "Environment \(n)" }) { n += 1 }
        envs.append(OCEnvironmentSnapshot(name: "Environment \(n)", variables: []))
        doc.environments = envs
        hasUnsavedChanges = true
        refreshEnvironments()
    }

    func deleteEnvironment(_ name: String) {
        guard let doc = document else { return }
        var envs = doc.environments
        guard let index = envs.firstIndex(where: { $0.name == name }) else { return }
        for variable in envs[index].variables where variable.secret {
            Keychain.removeValue(account: doc.secretAccount(env: name, variable: variable.name))
        }
        envs.remove(at: index)
        doc.environments = envs
        hasUnsavedChanges = true
        refreshEnvironments()
    }

    func updateEnvironment(_ environment: OCEnvironmentSnapshot, previousName: String?) {
        guard let doc = document else { return }
        var envs = doc.environments
        guard let index = envs.firstIndex(where: { previousName == nil ? $0.name == environment.name : $0.name == previousName }) else { return }
        if let previousName, previousName != environment.name {
            // Renamed: move secret values to the new account.
            for variable in envs[index].variables where variable.secret {
                if let value = Keychain.value(account: doc.secretAccount(env: previousName, variable: variable.name)) {
                    Keychain.setValue(value, account: doc.secretAccount(env: environment.name, variable: variable.name))
                    Keychain.removeValue(account: doc.secretAccount(env: previousName, variable: variable.name))
                }
            }
        }
        envs[index] = environment
        doc.environments = envs
        hasUnsavedChanges = true
        if activeEnvironment == previousName { activeEnvironment = environment.name }
        refreshEnvironments()
    }

    func setVariable(_ variable: OCVariable, in environmentName: String, previousName: String?) {
        guard let doc = document else { return }
        var envs = doc.environments
        guard let index = envs.firstIndex(where: { $0.name == environmentName }) else { return }
        if let previousName, previousName != variable.name,
           let old = envs[index].variables.first(where: { $0.name == previousName }), old.secret {
            if let value = Keychain.value(account: doc.secretAccount(env: environmentName, variable: previousName)) {
                Keychain.setValue(value, account: doc.secretAccount(env: environmentName, variable: variable.name))
                Keychain.removeValue(account: doc.secretAccount(env: previousName, variable: previousName))
            }
        }
        if let position = envs[index].variables.firstIndex(where: { previousName == nil ? $0.name == variable.name : $0.name == previousName }) {
            envs[index].variables[position] = variable
        } else {
            envs[index].variables.append(variable)
        }
        doc.environments = envs
        hasUnsavedChanges = true
        refreshEnvironments()
    }

    func deleteVariable(_ name: String, in environmentName: String) {
        guard let doc = document else { return }
        var envs = doc.environments
        guard let index = envs.firstIndex(where: { $0.name == environmentName }) else { return }
        if let variable = envs[index].variables.first(where: { $0.name == name }), variable.secret {
            Keychain.removeValue(account: doc.secretAccount(env: environmentName, variable: name))
        }
        envs[index].variables.removeAll { $0.name == name }
        doc.environments = envs
        hasUnsavedChanges = true
        refreshEnvironments()
    }

    /// Keychain-backed value for a secret variable, if stored.
    func storedSecretValue(environment: String, variable: String) -> String? {
        guard let doc = document else { return nil }
        return Keychain.value(account: doc.secretAccount(env: environment, variable: variable))
    }

    func storeSecretValue(_ value: String, environment: String, variable: String) {
        guard let doc = document else { return }
        Keychain.setValue(value, account: doc.secretAccount(env: environment, variable: variable))
    }

    // MARK: - Send

    func send() {
        guard !busy, let snapshot = draft else { return }
        let resolution = document?.resolveVariables(in: activeEnvironment) ?? (values: [:], missingSecrets: [])
        let missing = resolution.missingSecrets
        if !missing.isEmpty {
            let names = missing.map { "\"\($0)\"" }.joined(separator: ", ")
            errorText = "Secret \(names) has no stored value. Open Environments to set it — secret values live in the macOS Keychain, never in the collection file."
            return
        }
        busy = true
        result = nil
        bodyDisplay = nil
        errorText = nil

        let effective = Self.effectiveRequest(from: snapshot, variables: resolution.values)
        let method = HTTPMethod(rawValue: effective.method) ?? .GET

        Task {
            do {
                let client = HTTPClient(followRedirects: effective.followRedirects)
                let response = try await client.send(
                    method: method,
                    urlText: effective.url,
                    body: effective.body,
                    headers: effective.headers
                )
                self.result = response
                self.history.record(method: method, url: effective.url, body: effective.body, status: response.status)
                let bodyText = String(data: response.body.prefix(16 << 20), encoding: .utf8) ?? ""
                let display = await Task.detached(priority: .userInitiated) {
                    BodyDisplay.build(response, bodyText: bodyText)
                }.value
                self.bodyDisplay = display
            } catch {
                self.errorText = error.localizedDescription
                self.history.record(method: method, url: effective.url, body: effective.body, status: nil)
            }
            self.busy = false
        }
    }

    struct EffectiveRequest: Sendable {
        var method: String
        var url: String
        var headers: [(name: String, value: String)]
        var body: String
        var followRedirects: Bool
    }

    /// Interpolate variables, apply auth, and fold query params into the URL.
    static func effectiveRequest(from snapshot: OCRequestSnapshot, variables: [String: String]) -> EffectiveRequest {
        let url = interpolate(snapshot.url, variables)
        let headerList = snapshot.headers
            .filter { !$0.disabled && !$0.name.isEmpty }
            .map { (name: interpolate($0.name, variables), value: interpolate($0.value, variables)) }
        let queryParams = snapshot.params
            .filter { !$0.disabled && !$0.name.isEmpty && $0.kind == "query" }
            .map { (name: interpolate($0.name, variables), value: interpolate($0.value, variables)) }

        var headers = headerList
        var extraQuery = queryParams

        switch snapshot.authKind {
        case .basic(let username, let password):
            let credentials = Data("\(interpolate(username, variables)):\(interpolate(password, variables))".utf8)
                .base64EncodedString()
            headers.append((name: "Authorization", value: "Basic \(credentials)"))
        case .bearer(let token):
            headers.append((name: "Authorization", value: "Bearer \(interpolate(token, variables))"))
        case .apiKey(let key, let value, let placement):
            let interpolatedValue = interpolate(value, variables)
            if placement == "query" {
                extraQuery.append((name: interpolate(key, variables), value: interpolatedValue))
            } else {
                headers.append((name: interpolate(key, variables), value: interpolatedValue))
            }
        case .none, .inherit, .preserved:
            break
        }

        let urlWithParams = appendQuery(url, extraQuery)
        let method = snapshot.method.uppercased()
        let body = method.requestHasBody
            ? (snapshot.bodyType == "graphql" ? snapshot.bodyData : interpolate(snapshot.bodyData, variables))
            : ""

        return EffectiveRequest(
            method: method,
            url: urlWithParams,
            headers: headers,
            body: body,
            followRedirects: snapshot.settings.followRedirects ?? true
        )
    }

    static func appendQuery(_ url: String, _ params: [(name: String, value: String)]) -> String {
        guard !params.isEmpty else { return url }
        var components = URLComponents(string: url)
        var items = (components?.queryItems ?? []).map { URLQueryItem(name: $0.name, value: $0.value) }
        for param in params {
            items.append(URLQueryItem(name: param.name, value: param.value))
        }
        components?.queryItems = items
        return components?.url?.absoluteString ?? url
    }

    nonisolated static func interpolate(_ template: String, _ variables: [String: String]) -> String {
        OpenCollectionDocument.interpolate(template, variables)
    }

    // MARK: - Workspace preferences

    private static let workspaceDefaultsKey = "gowa.workspace.directory"

    var defaultWorkspaceDirectory: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: Self.workspaceDefaultsKey) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: Self.workspaceDefaultsKey)
        }
    }

    private func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "collection" : cleaned
    }
}
