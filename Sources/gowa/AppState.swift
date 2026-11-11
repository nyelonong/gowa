import AppKit
import Foundation
import Observation
import SwiftUI

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

extension SidebarNode {
    /// Keeps requests whose method, name, and URL together contain every
    /// word of `query`. A folder whose own name matches keeps its whole subtree.
    static func filter(_ tree: [SidebarNode], query: String) -> [SidebarNode] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return tree }

        func matches(_ text: String) -> Bool {
            let haystack = text.lowercased()
            return words.allSatisfy(haystack.contains)
        }

        func keep(_ nodes: [SidebarNode]) -> [SidebarNode] {
            nodes.compactMap { item in
                if item.isFolder {
                    if matches(item.name) { return item }
                    let children = keep(item.children)
                    return children.isEmpty ? nil : SidebarNode(node: item.node, children: children)
                }
                let text = [item.node.method, item.name, item.node.url].compactMap { $0 }.joined(separator: " ")
                return matches(text) ? item : nil
            }
        }
        return keep(tree)
    }

    static func firstRequest(in tree: [SidebarNode]) -> SidebarNode? {
        for item in tree {
            if !item.isFolder { return item }
            if let found = firstRequest(in: item.children) { return found }
        }
        return nil
    }
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
    var renamingCollection = false
    var openErrorMessage: String?

    // Environment
    var activeEnvironment: String?
    var environments: [OCEnvironmentSnapshot] = []
    var showingEnvironmentManager = false
    var showingCurlImport = false

    /// Secret variables of the active environment with no stored value.
    var missingSecrets: [String] {
        document?.resolveVariables(in: activeEnvironment).missingSecrets ?? []
    }

    // Send state
    var busy = false
    private var sendTask: Task<Void, Never>?
    private var sendRequestID: UUID?
    var sendValidationMessage: String? {
        guard let draft else { return nil }
        let url = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return "Enter a URL before sending" }
        guard url.contains("{{") || url.hasPrefix("http://") || url.hasPrefix("https://") else {
            return "URL must start with http:// or https://"
        }
        guard url.contains("{{") || URL(string: url) != nil else { return "Enter a valid URL" }
        return nil
    }
    var result: HTTPResult?
    var bodyDisplay: BodyDisplay?
    var errorText: String?

    /// Values captured from responses (e.g. OAuth tokens). Session-scoped:
    /// they override environment variables during interpolation and are
    /// never written to the collection file.
    var sessionVariables: [String: String] = [:]
    var lastCaptures: [(name: String, value: String, stored: Bool)] = []
    var lastAssertions: [OpenCollectionDocument.AssertionOutcome] = []
    var lastTests: [ScriptTestResult] = []
    /// Server-sent events arriving while a streamed response is still open.
    var liveEvents: [SSEEvent] = []
    var lastLogs: [ScriptLog] = []
    var lastScriptError: String?

    struct DiffContext: Sendable {
        var old: String
        var new: String
    }
    var diffContext: DiffContext?
    private var lastBodyByKey: [String: String] = [:]

    let history = HistoryStore()
    private(set) var cookieJar: CookieJar?
    private(set) var oauthClient: OAuth2Client?
    /// Bumped when the jar changes so cookie views refresh.
    var cookieRevision = 0
    var showingCookies = false
    var showingPalette = false
    var showingCode = false

    /// The selected request with variables and inheritance resolved, for code generation.
    func effectiveRequestForCode() -> Result<(effective: EffectiveRequest, note: String), Error>? {
        guard let snapshot = draft else { return nil }
        let executor = RequestExecutor(document: document, environment: activeEnvironment, cookies: cookieJar, oauth: oauthClient)
        do {
            let prepared = try executor.prepare(snapshot, at: selectedRequestPath, session: sessionVariables)
            var notes = ["Values are resolved with the active environment, so the code can contain secrets."]
            if case .oauth2 = prepared.snapshot.authKind { notes.append("OAuth 2.0 tokens aren't included; add an Authorization header.") }
            if !executor.scripts(prepared.snapshot, at: selectedRequestPath, types: ["before-request"]).isEmpty {
                notes.append("Pre-request scripts don't run here.")
            }
            return .success((prepared.effective, notes.joined(separator: " ")))
        } catch {
            return .failure(error)
        }
    }
    var showingHistory = false
    var gitStatus: GitStatus?

    func refreshGitStatus() {
        guard let url = document?.url else {
            gitStatus = nil
            return
        }
        Task { @MainActor in
            let status = await GitStatus.load(for: url)
            if self.document?.url == url { self.gitStatus = status }
        }
    }

    private static let lastCollectionKey = "gowa.lastCollection"

    init(restoringLastCollection: Bool = true) {
        if restoringLastCollection { restoreLastCollection() }
    }

    /// Reopens the most recently opened or saved collection at launch.
    private func restoreLastCollection() {
        guard let path = UserDefaults.standard.string(forKey: Self.lastCollectionKey),
              FileManager.default.fileExists(atPath: path)
        else { return }
        openCollection(at: URL(fileURLWithPath: path))
    }

    private func rememberCurrentCollection() {
        guard let path = document?.url?.path else { return }
        UserDefaults.standard.set(path, forKey: Self.lastCollectionKey)
    }

    var canSend: Bool { draft != nil && !busy && sendValidationMessage == nil }

    /// Variables `{{name}}` resolves to for the selected request (or folder).
    var variableScope: VariableScope {
        let executor = RequestExecutor(document: document, environment: activeEnvironment, cookies: cookieJar, oauth: oauthClient)
        let resolution = executor.variables(at: selectedRequestPath, session: sessionVariables)
        return VariableScope(values: resolution.values, secretNames: Set(resolution.missingSecrets))
    }

    /// Token actions for the OAuth 2.0 editor, using variables visible at `path`.
    func tokenActions(at path: NodePath?) -> OAuthTokenActions {
        let resolve = { [weak self] (config: OCOAuth2) -> OCOAuth2 in
            guard let self else { return config }
            let executor = RequestExecutor(document: self.document, environment: self.activeEnvironment)
            return config.interpolated(executor.variables(at: path, session: self.sessionVariables).values)
        }
        return OAuthTokenActions(
            status: { [weak self] config in self?.oauthClient?.cachedToken(for: resolve(config)) },
            fetch: { [weak self] config in
                guard let client = self?.oauthClient else { return "Open a collection first" }
                do {
                    _ = try await client.fetch(resolve(config))
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            clear: { [weak self] config in self?.oauthClient?.clear(resolve(config)) }
        )
    }

    // MARK: - Folder and collection defaults

    enum DefaultsTarget: Identifiable, Equatable {
        case collection
        case folder(NodePath)

        var id: String {
            switch self {
            case .collection: "collection"
            case .folder(let path): path.map(String.init).joined(separator: ".")
            }
        }

        var path: NodePath? {
            if case .folder(let path) = self { return path }
            return nil
        }
    }

    var editingDefaults: DefaultsTarget?

    func defaults(for target: DefaultsTarget) -> OCDefaults {
        document?.defaults(at: target.path) ?? OCDefaults()
    }

    func updateDefaults(_ defaults: OCDefaults, for target: DefaultsTarget) {
        guard let doc = document else { return }
        doc.updateDefaults(at: target.path, defaults)
        hasUnsavedChanges = true
    }

    var networkSettings: OCNetworkSettings {
        get { document?.networkSettings ?? OCNetworkSettings() }
        set {
            document?.networkSettings = newValue
            hasUnsavedChanges = true
        }
    }

    func defaultsTitle(for target: DefaultsTarget) -> String {
        switch target {
        case .collection:
            return document?.name ?? "Collection"
        case .folder(let path):
            return document?.enumerate().first { $0.path == path }?.name ?? "Folder"
        }
    }
    // MARK: - Collection lifecycle

    func newCollection() {
        let doc = OpenCollectionDocument.sample()
        let starter = OCRequestSnapshot(
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
    func presentAsSheet(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
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
            statusMessage = "Opened \(url.lastPathComponent)"
        } catch {
            openErrorMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
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
                refreshGitStatus()
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
                self.refreshGitStatus()
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
        invalidateActiveSend()
        document = doc
        let jar = CookieJar.forCollection(id: doc.documentID)
        jar.onChange = { [weak self] in
            Task { @MainActor in self?.cookieRevision += 1 }
        }
        cookieJar = jar
        grpc.reset()
        grpcDraft = nil
        socket.disconnect(reason: nil)
        socket.clear()
        socketDraft = nil
        gitStatus = nil
        refreshGitStatus()
        oauthClient = OAuth2Client(collectionID: doc.documentID)
        rememberCurrentCollection()
        hasUnsavedChanges = false
        sessionVariables = [:]
        lastCaptures = []
        lastAssertions = []
        diffContext = nil
        lastBodyByKey = [:]
        selectedRequestPath = nil
        draft = nil
        result = nil
        bodyDisplay = nil
        errorText = nil
        rebuildSidebar()
        let envs = doc.environments
        environments = envs
        activeEnvironment = nil
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
        if selectedRequestPath != path, busy {
            invalidateActiveSend()
        }
        if selectedRequestPath != path {
            socket.disconnect()
            socket.clear()
        }
        socketDraft = nil
        if selectedRequestPath != path { grpc.reset() }
        grpcDraft = nil
        if let snapshot = doc.grpcSnapshot(at: path) {
            selectedRequestPath = path
            draft = nil
            grpcDraft = snapshot
        } else if let snapshot = doc.webSocketSnapshot(at: path) {
            selectedRequestPath = path
            draft = nil
            socketDraft = snapshot
        } else if let snapshot = doc.requestSnapshot(at: path) {
            selectedRequestPath = path
            draft = snapshot
            result = nil
            bodyDisplay = nil
            errorText = nil
            lastCaptures = []
            lastAssertions = []
            lastTests = []
            lastLogs = []
            lastScriptError = nil
            diffContext = nil
        } else {
            // Folder selected: keep request selection independent.
            selectedRequestPath = nil
            draft = nil
        }
    }

    // MARK: - gRPC

    var grpcDraft: OCGrpcSnapshot?
    let grpc = GrpcSession()

    func addGrpc(under parent: NodePath?) {
        guard let doc = document else { return }
        let name = uniqueName("New gRPC", among: siblingNames(under: parent))
        let path = doc.addGrpc(under: parent, OCGrpcSnapshot(name: name, url: "localhost:50051"))
        markDirtyAndRebuild()
        select(path: path)
    }

    func updateGrpcDraft(_ snapshot: OCGrpcSnapshot) {
        guard let doc = document, let path = selectedRequestPath else { return }
        grpcDraft = snapshot
        doc.updateGrpc(at: path, snapshot)
        hasUnsavedChanges = true
        rebuildSidebar()
    }

    /// Address, metadata, security, and variables for the selected gRPC request.
    private func grpcContext() async throws -> (target: GrpcTarget, metadata: [(name: String, value: String)], security: GrpcClient.Security, message: String, variables: [String: String]) {
        guard let snapshot = grpcDraft else { throw GrpcError.noMethod("") }
        let executor = RequestExecutor(document: document, environment: activeEnvironment, cookies: cookieJar, oauth: oauthClient)
        let prepared = try executor.prepare(snapshot.asRequest, at: selectedRequestPath, session: sessionVariables)
        var effective = prepared.effective
        if case .oauth2(let config) = prepared.snapshot.authKind {
            try await executor.applyOAuth2(config.interpolated(prepared.variables), to: &effective)
        }
        let settings = document?.networkSettings ?? OCNetworkSettings()
        var security = GrpcClient.Security(verifyTLS: settings.verifyTLS)
        let target = try GrpcTarget.parse(OpenCollectionDocument.interpolate(snapshot.url, prepared.variables))
        if let certificate = settings.clientCertificates.first(where: { !$0.disabled && !$0.path.isEmpty && NetworkOptions.domain($0.domain, matches: target.host, port: target.port) }) {
            security.clientCertificate = try GrpcCertificates.load(certificate, variables: prepared.variables, base: document?.url?.deletingLastPathComponent())
        }
        // HTTP-only headers (often inherited from REST defaults) are reserved in gRPC.
        let reserved: Set<String> = ["content-type", "content-length", "te", "user-agent", "host", "connection", "accept", "accept-encoding", "transfer-encoding"]
        let metadata = effective.headers.filter { !reserved.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("grpc-") }
        return (target, metadata, security, OpenCollectionDocument.interpolate(snapshot.message, prepared.variables), prepared.variables)
    }

    func loadGrpcSchema() {
        grpc.task?.cancel()
        grpc.error = nil
        let run = UUID()
        grpc.runID = run
        grpc.task = Task { @MainActor in
            do {
                try await fetchGrpcSchema(run: run)
            } catch {
                guard grpc.runID == run, !(error is CancellationError) else { return }
                grpc.error = error.localizedDescription
            }
        }
    }

    /// Loads methods from the descriptor file, or by server reflection, and
    /// picks the first method when none is chosen yet. Results of a run that
    /// was replaced (another call, another request) are dropped.
    private func fetchGrpcSchema(run: UUID) async throws {
        guard let snapshot = grpcDraft else { return }
        grpc.loadingSchema = true
        defer { if grpc.runID == run { grpc.loadingSchema = false } }
        let context = try await grpcContext()
        let schema: ProtoSchema
        let source: String
        if !snapshot.protoFilePath.isEmpty {
            let base = document?.url?.deletingLastPathComponent()
            let file = EffectiveBody.resolvePath(OpenCollectionDocument.interpolate(snapshot.protoFilePath, context.variables), base: base)
            schema = try await Task.detached { try GrpcClient.loadDescriptors(at: file, importPaths: []) }.value
            source = file.lastPathComponent
        } else {
            schema = try await GrpcClient.reflect(target: context.target, security: context.security, metadata: context.metadata)
            source = "server reflection"
        }
        try Task.checkCancellation()
        guard grpc.runID == run else { throw CancellationError() }
        grpc.schema = schema
        grpc.schemaSource = source
        if var current = grpcDraft,
           current.method.isEmpty || schema.method(current.method) == nil, let first = schema.methods.first {
            current.method = first.fullName
            current.methodType = first.kind
            if current.message.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" {
                current.message = JSONPath.render([ProtoCodec(schema: schema).template(for: first.input)])
            }
            updateGrpcDraft(current)
        }
    }

    func invokeGrpc() {
        grpc.task?.cancel()
        let run = UUID()
        grpc.runID = run
        grpc.calling = true
        grpc.error = nil
        grpc.result = nil
        grpc.liveResponses = []
        grpc.task = Task { @MainActor in
            defer { if grpc.runID == run { grpc.calling = false } }
            do {
                if grpc.schema == nil { try await fetchGrpcSchema(run: run) }
                guard let snapshot = grpcDraft, let schema = grpc.schema else { throw GrpcError.reflection("no schema") }
                guard let method = schema.method(snapshot.method) else { throw GrpcError.noMethod(snapshot.method) }
                let context = try await grpcContext()
                let encoded = try GrpcClient.encode(context.message, method: method, schema: schema)
                let result = try await GrpcClient.invoke(
                    target: context.target, security: context.security, method: method, schema: schema,
                    encoded: encoded, metadata: context.metadata, timeout: .seconds(60)
                ) { text in
                    Task { @MainActor [weak self] in
                        guard let self, self.grpc.runID == run else { return }
                        self.grpc.liveResponses.append(text)
                    }
                }
                guard grpc.runID == run else { return }
                grpc.result = result
            } catch {
                guard grpc.runID == run else { return }
                grpc.error = error is CancellationError ? "Call cancelled" : error.localizedDescription
            }
        }
    }

    func cancelGrpc() {
        grpc.task?.cancel()
    }

    // MARK: - WebSocket

    var socketDraft: OCWebSocketSnapshot?
    let socket = WebSocketConnection()

    func addWebSocket(under parent: NodePath?) {
        guard let doc = document else { return }
        let name = uniqueName("New WebSocket", among: siblingNames(under: parent))
        let path = doc.addWebSocket(under: parent, OCWebSocketSnapshot(name: name, url: "wss://"))
        markDirtyAndRebuild()
        select(path: path)
    }

    func updateSocketDraft(_ snapshot: OCWebSocketSnapshot) {
        guard let doc = document, let path = selectedRequestPath else { return }
        socketDraft = snapshot
        doc.updateWebSocket(at: path, snapshot)
        hasUnsavedChanges = true
        rebuildSidebar()
    }

    /// Connects with the same variables, inherited headers and auth, cookies,
    /// proxy, and TLS settings an HTTP request would use.
    func connectSocket() {
        guard let snapshot = socketDraft else { return }
        let path = selectedRequestPath
        let executor = RequestExecutor(document: document, environment: activeEnvironment, cookies: cookieJar, oauth: oauthClient)
        Task { @MainActor in
            do {
                let prepared = try executor.prepare(snapshot.upgradeRequest, at: path, session: sessionVariables)
                var effective = prepared.effective
                if case .oauth2(let config) = prepared.snapshot.authKind {
                    try await executor.applyOAuth2(config.interpolated(prepared.variables), to: &effective)
                }
                guard let url = URL(string: effective.url), ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") else {
                    throw HTTPError.invalidURL("WebSocket URLs start with ws:// or wss://")
                }
                let network = try document.map {
                    try NetworkOptions.resolve($0.networkSettings, variables: prepared.variables, baseDirectory: $0.url?.deletingLastPathComponent(), cookies: cookieJar)
                } ?? .none
                socket.connect(url: url, headers: effective.headers, network: network, timeout: 30)
            } catch {
                socket.disconnect(reason: nil)
                statusMessage = error.localizedDescription
                socketError = error.localizedDescription
            }
        }
    }

    var socketError: String?

    /// Sends the composed message with `{{variables}}` resolved.
    func sendSocketMessage() {
        guard let snapshot = socketDraft else { return }
        let values = RequestExecutor(document: document, environment: activeEnvironment).variables(at: selectedRequestPath, session: sessionVariables).values
        socket.send(OpenCollectionDocument.interpolate(snapshot.message, values), binary: snapshot.messageType == "binary")
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

    func beginRenameCollection() {
        guard let doc = document else { return }
        renameText = doc.name
        renamingCollection = true
    }

    func beginRename(_ path: NodePath) {
        guard let doc = document,
              let node = doc.enumerate().first(where: { $0.path == path })
        else { return }
        renameTarget = path
        renameText = node.name
    }

    func commitRename() {
        if renamingCollection {
            let name = renameText.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, let doc = document, name != doc.name {
                doc.name = name
                hasUnsavedChanges = true
                statusMessage = "Collection renamed — ⌘S writes info.name to the YAML"
            }
            renamingCollection = false
            return
        }
        guard let target = renameTarget else { return }
        renameSelection(target, to: renameText)
        renameTarget = nil
    }

    func cancelRename() {
        renamingCollection = false
        renameTarget = nil
    }

    func duplicate(_ path: NodePath) {
        guard let doc = document else { return }
        doc.duplicate(at: path)
        if let selected = selectedRequestPath {
            selectedRequestPath = OpenCollectionDocument.adjust(selected, inserting: path.dropLast() + [path.last! + 1])
        }
        lastBodyByKey = [:]
        markDirtyAndRebuild()
    }

    func delete(_ path: NodePath) {
        guard let doc = document else { return }
        doc.delete(at: path)
        if selectedRequestPath?.starts(with: path) == true {
            selectedRequestPath = nil
            draft = nil
            socketDraft = nil
            grpcDraft = nil
            grpc.reset()
            socket.disconnect(reason: nil)
        } else if let selected = selectedRequestPath {
            selectedRequestPath = OpenCollectionDocument.adjust(selected, removing: path)
        }
        lastBodyByKey = [:]
        markDirtyAndRebuild()
    }

    /// Drag-and-drop move; the selection follows the item it pointed at.
    func move(nodeID: String, toParent parent: NodePath?, index: Int?) {
        guard let doc = document else { return }
        let source = nodeID.split(separator: ".").compactMap { Int($0) }
        guard !source.isEmpty, let result = doc.move(from: source, toParent: parent, index: index) else { return }
        if let selected = selectedRequestPath {
            selectedRequestPath = OpenCollectionDocument.remap(selected, from: source, toParent: parent, index: index, result: result)
        }
        lastBodyByKey = [:]
        diffContext = nil
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

    // MARK: - cURL export

    func copyAsCurl() {
        guard let snapshot = draft else { return }
        let vars = document?.resolveVariables(in: activeEnvironment).values ?? [:]
        let effective = if let doc = document, let path = selectedRequestPath {
            doc.effectiveRequest(at: path, from: snapshot, variables: vars)
        } else {
            Self.effectiveRequest(from: snapshot, variables: vars)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(CurlBuilder.command(from: effective), forType: .string)
        statusMessage = "cURL copied to clipboard (interpolated with the active environment)"
    }

    func copyAsCurl(at path: NodePath) {
        guard let doc = document, let snapshot = doc.requestSnapshot(at: path) else { return }
        let vars = doc.resolveVariables(in: activeEnvironment).values
        let effective = doc.effectiveRequest(at: path, from: snapshot, variables: vars)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(CurlBuilder.command(from: effective), forType: .string)
        statusMessage = "cURL copied to clipboard"
    }

    func saveResponse() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.title = "Save Response"
        panel.allowedContentTypes = [.data]
        let name = (result.url.lastPathComponent as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(name.isEmpty ? "response" : name).body"
        panel.directoryURL = defaultWorkspaceDirectory
        presentAsSheet(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try result.body.write(to: url)
                self.statusMessage = "Response saved to \(url.lastPathComponent)"
            } catch {
                self.statusMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    /// Picks a file and reports its path, relative to the collection folder when inside it.
    func chooseFile(_ completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let base = document?.url?.deletingLastPathComponent().standardizedFileURL
        panel.directoryURL = base
        presentAsSheet(panel) { response in
            guard response == .OK, let url = panel.url?.standardizedFileURL else { return }
            completion(Self.storedPath(for: url, base: base))
        }
    }

    nonisolated static func storedPath(for url: URL, base: URL?) -> String {
        guard let base else { return url.path }
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }

    var findTrigger: Int = 0

    func beginFindInResponse() {
        findTrigger += 1
    }

    // MARK: - cURL import

    func addRequestFromCurl(_ snapshot: OCRequestSnapshot, under parent: NodePath?) {
        guard let doc = document else { return }
        let path = doc.addRequest(under: parent, snapshot: snapshot)
        markDirtyAndRebuild()
        select(path: path)
    }

    /// Flattened destination options for import pickers.
    func folderOptions() -> [(path: NodePath, label: String)] {
        var options: [(NodePath, String)] = []
        func walk(_ nodes: [SidebarNode], _ depth: Int) {
            for node in nodes where node.isFolder {
                options.append((node.node.path, String(repeating: "    ", count: depth) + node.name))
                walk(node.children, depth + 1)
            }
        }
        walk(sidebarTree, 0)
        return options
    }

    // MARK: - Environment management

    func refreshEnvironments() {
        guard let doc = document else { return }
        environments = doc.environments
        if let active = activeEnvironment, !environments.contains(where: { $0.name == active }) {
            activeEnvironment = nil
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

    func setEnvironmentColor(_ name: String, hex: String?) {
        guard let doc = document else { return }
        var envs = doc.environments
        guard let index = envs.firstIndex(where: { $0.name == name }) else { return }
        envs[index].color = hex
        doc.environments = envs
        hasUnsavedChanges = true
        refreshEnvironments()
    }

    var activeEnvironmentColor: Color? {
        Theme.color(hex: environments.first { $0.name == activeEnvironment }?.color)
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
        let executor = RequestExecutor(document: document, environment: activeEnvironment, cookies: cookieJar, oauth: oauthClient)
        do {
            _ = try executor.prepare(snapshot, at: selectedRequestPath, session: sessionVariables)
        } catch {
            errorText = error.localizedDescription
            return
        }
        busy = true
        result = nil
        bodyDisplay = nil
        errorText = nil
        liveEvents = []
        lastAssertions = []
        lastTests = []
        lastLogs = []
        lastScriptError = nil

        let requestID = UUID()
        sendRequestID = requestID
        let path = selectedRequestPath

        sendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.sendRequestID == requestID else { return }
            do {
                let outcome = try await executor.execute(snapshot, at: path, session: self.sessionVariables) { event in
                    Task { @MainActor [weak self] in
                        guard let self, self.sendRequestID == requestID else { return }
                        self.liveEvents.append(event)
                    }
                }
                try Task.checkCancellation()
                guard self.sendRequestID == requestID else { return }
                let response = outcome.response
                self.result = response
                self.recordHistory(snapshot: snapshot, path: path, effective: outcome.effective, response: response, error: nil)
                self.applyCaptures(outcome.captures)
                self.applyScriptVariables(outcome)
                self.lastTests = outcome.tests
                self.lastLogs = outcome.logs
                self.lastScriptError = outcome.scriptError
                if let key = path?.map(String.init).joined(separator: ".") {
                    let diffText = String(data: response.body.prefix(4 << 20), encoding: .utf8) ?? ""
                    if let previous = self.lastBodyByKey[key], previous != diffText {
                        self.diffContext = DiffContext(old: previous, new: diffText)
                    }
                    self.lastBodyByKey[key] = diffText
                }
                self.lastAssertions = outcome.assertions
                let bodyText = String(data: response.body.prefix(16 << 20), encoding: .utf8) ?? ""
                let display = await Task.detached(priority: .userInitiated) {
                    BodyDisplay.build(response, bodyText: bodyText)
                }.value
                try Task.checkCancellation()
                self.bodyDisplay = display
            } catch is CancellationError {
                self.errorText = "Request cancelled"
            } catch let error as URLError where error.code == .cancelled {
                self.errorText = "Request cancelled"
            } catch {
                self.errorText = error.localizedDescription
                if case ExecutionError.script(_, let logs) = error { self.lastLogs = logs }
                if let effective = try? executor.prepare(snapshot, at: path, session: self.sessionVariables).effective {
                    self.recordHistory(snapshot: snapshot, path: path, effective: effective, response: nil, error: error.localizedDescription)
                }
            }
            guard self.sendRequestID == requestID else { return }
            self.sendRequestID = nil
            self.busy = false
            self.sendTask = nil
        }
    }

    private func recordHistory(snapshot: OCRequestSnapshot, path: NodePath?, effective: EffectiveRequest, response: HTTPResult?, error: String?) {
        let sent = response?.requestHeaders.isEmpty == false ? response!.requestHeaders : effective.headers
        let redaction = historyRedaction(for: snapshot)
        history.record(HistoryEntry(
            method: effective.method,
            url: redaction.url(effective.url),
            body: redaction.text(effective.body),
            at: Date(),
            status: response?.status,
            requestName: snapshot.name,
            collectionID: document?.documentID,
            nodeID: path?.map(String.init).joined(separator: "."),
            requestHeaders: sent.map { redaction.header($0.name, $0.value) },
            responseHeaders: response?.headers.map { .init(name: $0.name, value: $0.value) },
            responseBody: response.map { String(decoding: $0.body.prefix(HistoryStore.maxBodyBytes + 1), as: UTF8.self) },
            elapsedMs: response?.elapsed.milliseconds,
            error: error
        ))
    }

    /// What history must not store for this request: the auth header or query
    /// parameter it uses, and the values of secret variables wherever they appear.
    private func historyRedaction(for snapshot: OCRequestSnapshot) -> HistoryRedaction {
        var headers: Set<String> = []
        var queries: Set<String> = []
        var auth = snapshot.authKind
        if case .inherit = auth, let doc = document, let path = selectedRequestPath { auth = doc.resolvedAuth(at: path) ?? .none }
        switch auth {
        case .apiKey(let key, _, let placement):
            if placement == "query" { queries.insert(key) } else { headers.insert(key.lowercased()) }
        case .oauth2(let config):
            if config.tokenQuery.isEmpty { headers.insert((config.tokenHeader.isEmpty ? "Authorization" : config.tokenHeader).lowercased()) } else { queries.insert(config.tokenQuery) }
        default: break
        }
        var secrets: [String] = []
        if let doc = document, let environment = environments.first(where: { $0.name == activeEnvironment }) {
            let values = doc.resolveVariables(in: activeEnvironment).values
            secrets = environment.variables.filter(\.secret).compactMap { values[$0.name] }.filter { $0.count >= 4 }
        }
        return HistoryRedaction(headers: headers, queries: queries, secrets: secrets)
    }

    /// Adds a history entry back to the collection as a new request.
    func restore(_ entry: HistoryEntry) {
        guard document != nil else { return }
        var snapshot = OCRequestSnapshot(
            name: uniqueName(entry.requestName ?? "\(entry.method) request", among: siblingNames(under: nil)),
            method: entry.method,
            url: entry.url,
            params: [],
            headers: (entry.requestHeaders ?? [])
                .filter { !$0.value.hasPrefix("••••") && !["content-length", "host"].contains($0.name.lowercased()) }
                .map { OCHeader(name: $0.name, value: $0.value, disabled: false) },
            bodyType: entry.body.isEmpty ? nil : (JSONHighlighter.isJSON(entry.body, contentType: nil) ? "json" : "text"),
            bodyData: entry.body,
            authKind: .none,
            settings: OCSettings(followRedirects: nil, timeout: nil),
            docs: nil
        )
        if !entry.method.requestHasBody { snapshot.bodyType = nil; snapshot.bodyData = "" }
        addRequestFromCurl(snapshot, under: nil)
        statusMessage = "Added \(snapshot.name) from history; credential headers weren't saved, so set auth again"
    }

    /// Selects the request a history entry came from, when it still exists.
    func openSource(of entry: HistoryEntry) -> Bool {
        guard entry.collectionID == document?.documentID, let id = entry.nodeID,
              let node = document?.enumerate().first(where: { $0.id == id && !$0.isFolder })
        else { return false }
        select(path: node.path)
        return true
    }

    func cancelSend() {
        guard busy else { return }
        sendTask?.cancel()
        statusMessage = "Cancelling request…"
    }

    private func invalidateActiveSend() {
        sendRequestID = nil
        sendTask?.cancel()
        sendTask = nil
        busy = false
    }

    private func applyCaptures(_ captures: [CaptureOutcome]) {
        var shown: [(name: String, value: String, stored: Bool)] = []
        for capture in captures {
            guard let value = capture.value else {
                shown.append((capture.name, "<not found>", false))
                continue
            }
            sessionVariables[capture.name] = value
            if capture.storesInEnvironment {
                persistToEnvironment(name: capture.name, value: value)
            }
            shown.append((capture.name, value, capture.storesInEnvironment))
        }
        if !shown.isEmpty {
            lastCaptures = shown
        }
    }

    private func applyScriptVariables(_ outcome: ExecutionOutcome) {
        for (name, value) in outcome.runtimeVariables {
            sessionVariables[name] = value
        }
        for (name, value) in outcome.environmentVariables {
            sessionVariables[name] = value
            persistToEnvironment(name: name, value: value)
        }
    }

    /// Environment-scope captures write through to the in-memory document
    /// (and thus the YAML on save). Choose this scope only for values that
    /// belong in the file.
    private func persistToEnvironment(name: String, value: String) {
        guard let doc = document, let envName = activeEnvironment else { return }
        var envs = doc.environments
        guard let index = envs.firstIndex(where: { $0.name == envName }) else { return }
        var variables = envs[index].variables
        if let position = variables.firstIndex(where: { $0.name == name }) {
            if variables[position].secret {
                // Secret values live in the Keychain, never in the collection file.
                Keychain.setValue(value, account: doc.secretAccount(env: envName, variable: name))
                return
            }
            variables[position].value = value
        } else {
            variables.append(OCVariable(name: name, value: value, secret: false, disabled: false))
        }
        envs[index].variables = variables
        doc.environments = envs
        environments = envs
        hasUnsavedChanges = true
    }

    // MARK: - Folder runner

    struct AssertionOutcomeView: Identifiable, Sendable {
        let id = UUID()
        let expression: String
        let op: String
        let expected: String?
        let actual: String?
        let pass: Bool
    }

    struct RunnerEntry: Identifiable, Sendable {
        enum State: Sendable { case pending, running, passed, failed, error, skipped }
        let id: UUID
        let path: NodePath
        let name: String
        let method: String
        var state: State = .pending
        var detail: String?
        var elapsedText: String?
        var outcomes: [AssertionOutcomeView] = []
    }

    @Observable
    final class RunnerState: @unchecked Sendable {
        var entries: [RunnerEntry] = []
        var running = false
        var cancelled = false
        var passedCount = 0
        var failedCount = 0
        var errorCount = 0

        var summary: String {
            if running { return "\(passedCount) passed · \(failedCount) failed · running…" }
            if cancelled { return "\(passedCount) passed · \(failedCount) failed · cancelled" }
            return "\(passedCount) passed · \(failedCount) failed · \(errorCount) errors"
        }
    }

    let runner = RunnerState()
    var showingRunner = false
    private var runnerSkipRemaining = false
    private var runnerTask: Task<Void, Never>?

    /// Depth-first requests under `path` (nil = whole collection), in tree order.
    func runnerRequests(under path: NodePath?) -> [NodePath] {
        guard let doc = document else { return [] }
        let prefix = path ?? []
        return doc.enumerate()
            .filter { !$0.isFolder && ($0.kind == "http" || $0.kind == "graphql") }
            .map(\.path)
            .filter { $0.count > prefix.count && Array($0.prefix(prefix.count)) == prefix }
    }

    func startRunner(under path: NodePath?) {
        guard let doc = document, !runner.running else { return }
        let paths = runnerRequests(under: path)
        guard !paths.isEmpty else {
            statusMessage = "Nothing to run — the folder has no requests"
            return
        }

        runner.entries = paths.map { nodePath in
            let node = doc.enumerate().first { $0.path == nodePath }
            return RunnerEntry(
                id: UUID(),
                path: nodePath,
                name: node?.name ?? "Untitled",
                method: node?.method ?? "GET"
            )
        }
        runner.running = true
        runner.cancelled = false
        runner.passedCount = 0
        runner.failedCount = 0
        runner.errorCount = 0
        showingRunner = true

        runnerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSequence(paths)
        }
    }

    func stopRunner() {
        runner.cancelled = true
        runnerSkipRemaining = true
        runnerTask?.cancel()
    }

    private func runSequence(_ paths: [NodePath]) async {
        runnerSkipRemaining = false
        for index in paths.indices {
            if runnerSkipRemaining || Task.isCancelled {
                for remainingIndex in paths.indices.dropFirst(index) {
                    runner.entries[remainingIndex].state = .skipped
                }
                break
            }
            runner.entries[index].state = .running
            let outcome = await runOne(at: paths[index])
            runner.entries[index].state = outcome.state
            runner.entries[index].detail = outcome.detail
            runner.entries[index].elapsedText = outcome.elapsedText
            runner.entries[index].outcomes = outcome.outcomes
            switch outcome.state {
            case .passed: runner.passedCount += 1
            case .failed: runner.failedCount += 1
            case .error: runner.errorCount += 1
            default: break
            }
        }
        runner.running = false
        runnerTask = nil
    }

    private struct SingleRunOutcome {
        var state: RunnerEntry.State
        var detail: String?
        var elapsedText: String?
        var outcomes: [AssertionOutcomeView]
    }

    private func runOne(at path: NodePath) async -> SingleRunOutcome {
        guard let doc = document, let snapshot = doc.requestSnapshot(at: path) else {
            return SingleRunOutcome(state: .error, detail: "request not found", elapsedText: nil, outcomes: [])
        }
        let executor = RequestExecutor(document: doc, environment: activeEnvironment, cookies: cookieJar, oauth: oauthClient)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let outcome = try await executor.execute(snapshot, at: path, session: sessionVariables)
            applyCaptures(outcome.captures)
            applyScriptVariables(outcome)
            var outcomes = outcome.assertions.map { outcome in
                AssertionOutcomeView(
                    expression: outcome.expression,
                    op: outcome.op,
                    expected: outcome.expected,
                    actual: outcome.actual,
                    pass: outcome.pass
                )
            }
            outcomes += outcome.tests.map {
                AssertionOutcomeView(expression: $0.name, op: "test", expected: nil, actual: $0.error, pass: $0.passed)
            }
            if let scriptError = outcome.scriptError {
                outcomes.append(AssertionOutcomeView(expression: "script", op: "error", expected: nil, actual: scriptError, pass: false))
            }
            return SingleRunOutcome(
                state: outcome.passed ? .passed : .failed,
                detail: "HTTP \(outcome.response.status)",
                elapsedText: outcome.response.elapsed.millisecondsText,
                outcomes: outcomes
            )
        } catch {
            return SingleRunOutcome(
                state: .error,
                detail: error.localizedDescription,
                elapsedText: start.duration(to: clock.now).millisecondsText,
                outcomes: []
            )
        }
    }

    struct EffectiveRequest: Sendable {
        var method: String
        var url: String
        var headers: [(name: String, value: String)]
        var payload: EffectiveBody
        var followRedirects: Bool
        var timeout: Int?

        init(method: String, url: String, headers: [(name: String, value: String)], payload: EffectiveBody, followRedirects: Bool, timeout: Int?) {
            self.method = method
            self.url = url
            self.headers = headers
            self.payload = payload
            self.followRedirects = followRedirects
            self.timeout = timeout
        }

        init(method: String, url: String, headers: [(name: String, value: String)], body: String, followRedirects: Bool, timeout: Int?) {
            self.init(
                method: method,
                url: url,
                headers: headers,
                payload: body.isEmpty ? .none : .text(body, contentType: "text/plain"),
                followRedirects: followRedirects,
                timeout: timeout
            )
        }

        var body: String { payload.summary }

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    static func effectivePayload(from snapshot: OCRequestSnapshot, variables: [String: String], baseDirectory: URL?) -> EffectiveBody {
        let method = snapshot.method.uppercased()
        if snapshot.isGraphQL {
            let variablesText = interpolate(snapshot.graphqlVariables, variables).trimmingCharacters(in: .whitespacesAndNewlines)
            var object: [String: Any] = ["query": interpolate(snapshot.bodyData, variables)]
            if !variablesText.isEmpty {
                object["variables"] = (try? JSONSerialization.jsonObject(with: Data(variablesText.utf8))) ?? variablesText
            }
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return .text(String(data: data, encoding: .utf8) ?? "", contentType: "application/json")
        }
        guard method.requestHasBody else { return .none }
        let fields = snapshot.formFields.filter { !$0.disabled && !$0.name.isEmpty }
        switch snapshot.bodyType ?? "json" {
        case "form-urlencoded":
            return .form(fields.map { .init(name: interpolate($0.name, variables), value: interpolate($0.value, variables)) })
        case "multipart-form":
            return .multipart(fields.map { field in
                let value = interpolate(field.value, variables)
                return MultipartPart(
                    name: interpolate(field.name, variables),
                    text: field.kind == "file" ? nil : value,
                    file: field.kind == "file" ? EffectiveBody.resolvePath(value, base: baseDirectory) : nil,
                    contentType: field.contentType
                )
            })
        case "file":
            let path = interpolate(snapshot.filePath, variables)
            guard !path.isEmpty else { return .none }
            return .file(EffectiveBody.resolvePath(path, base: baseDirectory), contentType: snapshot.fileContentType)
        case let type:
            let text = interpolate(snapshot.bodyData, variables)
            guard !text.isEmpty else { return .none }
            let contentType = switch type {
            case "xml": "application/xml"
            case "text": "text/plain"
            case "sparql": "application/sparql-query"
            default: "application/json"
            }
            return .text(text, contentType: contentType)
        }
    }

    /// Interpolate variables, apply auth, fill path params and fold query params into the URL.
    static func effectiveRequest(from snapshot: OCRequestSnapshot, variables: [String: String], baseDirectory: URL? = nil) -> EffectiveRequest {
        let pathParams = snapshot.params
            .filter { !$0.disabled && !$0.name.isEmpty && $0.kind == "path" }
            .map { (name: $0.name, value: interpolate($0.value, variables)) }
        let url = substitutePathParams(interpolate(snapshot.url, variables), pathParams)
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
        case .none, .inherit, .preserved, .oauth2:
            break
        }

        let urlWithParams = appendQuery(url, extraQuery)

        return EffectiveRequest(
            method: snapshot.method.uppercased(),
            url: urlWithParams,
            headers: headers,
            payload: effectivePayload(from: snapshot, variables: variables, baseDirectory: baseDirectory),
            followRedirects: snapshot.settings.followRedirects ?? true,
            timeout: snapshot.settings.timeout
        )
    }

    /// Unset secrets this request refers to as `{{name}}`; unrelated unset secrets do not block it.
    static func missingSecrets(usedBy snapshot: OCRequestSnapshot, missing: [String], variables: [String: String]) -> [String] {
        var parts = [snapshot.url, snapshot.bodyData, snapshot.graphqlVariables, snapshot.filePath]
        parts += snapshot.formFields.filter { !$0.disabled }.flatMap { [$0.name, $0.value] }
        parts += snapshot.params.filter { !$0.disabled }.flatMap { [$0.name, $0.value] }
        parts += snapshot.headers.filter { !$0.disabled }.flatMap { [$0.name, $0.value] }
        switch snapshot.authKind {
        case .basic(let username, let password): parts += [username, password]
        case .bearer(let token): parts.append(token)
        case .apiKey(let key, let value, _): parts += [key, value]
        case .oauth2(let config):
            parts += [config.accessTokenUrl, config.authorizationUrl, config.clientId, config.clientSecret, config.username, config.password, config.scope]
        case .none, .inherit, .preserved: break
        }
        let text = parts.joined(separator: "\n")
        return missing.filter { variables[$0] == nil && text.contains("{{\($0)}}") }
    }

    /// Replaces each `:name` path segment; a param with no value leaves its segment as typed.
    static func substitutePathParams(_ url: String, _ params: [(name: String, value: String)]) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        var result = url
        for param in params where !param.value.isEmpty {
            let encoded = param.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? param.value
            let pattern = "/:" + NSRegularExpression.escapedPattern(for: param.name) + "(?=[/?#]|$)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "/" + NSRegularExpression.escapedTemplate(for: encoded)
            )
        }
        return result
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



struct HistoryRedaction {
    var headers: Set<String>
    var queries: Set<String>
    var secrets: [String]
    static let mask = "•••• (not saved)"

    func text(_ value: String) -> String {
        secrets.reduce(value) { $0.replacingOccurrences(of: $1, with: "••••") }
    }

    func header(_ name: String, _ value: String) -> HistoryEntry.Header {
        headers.contains(name.lowercased()) ? .init(name: name, value: Self.mask) : .init(name: name, value: text(value))
    }

    func url(_ value: String) -> String {
        guard !queries.isEmpty, var components = URLComponents(string: value) else { return text(value) }
        components.queryItems = components.queryItems?.map { queries.contains($0.name) ? URLQueryItem(name: $0.name, value: "redacted") : $0 }
        return text(components.string ?? value)
    }
}
