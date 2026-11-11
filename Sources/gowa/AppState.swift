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

    struct DiffContext: Sendable {
        var old: String
        var new: String
    }
    var diffContext: DiffContext?
    private var lastBodyByKey: [String: String] = [:]

    let history = HistoryStore()

    private static let lastCollectionKey = "gowa.lastCollection"

    init() {
        restoreLastCollection()
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
        invalidateActiveSend()
        document = doc
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
        if let snapshot = doc.requestSnapshot(at: path) {
            selectedRequestPath = path
            draft = snapshot
            result = nil
            bodyDisplay = nil
            errorText = nil
            lastCaptures = []
            lastAssertions = []
            diffContext = nil
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
        let executor = RequestExecutor(document: document, environment: activeEnvironment)
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
        lastAssertions = []

        let requestID = UUID()
        sendRequestID = requestID
        let path = selectedRequestPath

        sendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.sendRequestID == requestID else { return }
            do {
                let outcome = try await executor.execute(snapshot, at: path, session: self.sessionVariables)
                try Task.checkCancellation()
                guard self.sendRequestID == requestID else { return }
                let response = outcome.response
                self.result = response
                self.history.record(method: outcome.effective.method, url: outcome.effective.url, body: outcome.effective.body, status: response.status)
                self.applyCaptures(outcome.captures)
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
                if let effective = try? executor.prepare(snapshot, at: path, session: self.sessionVariables).effective {
                    self.history.record(method: effective.method, url: effective.url, body: effective.body, status: nil)
                }
            }
            guard self.sendRequestID == requestID else { return }
            self.sendRequestID = nil
            self.busy = false
            self.sendTask = nil
        }
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

    /// Environment-scope captures write through to the in-memory document
    /// (and thus the YAML on save). Choose this scope only for values that
    /// belong in the file.
    private func persistToEnvironment(name: String, value: String) {
        guard let doc = document, let envName = activeEnvironment else { return }
        var envs = doc.environments
        guard let index = envs.firstIndex(where: { $0.name == envName }) else { return }
        var variables = envs[index].variables
        if let position = variables.firstIndex(where: { $0.name == name }) {
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
            .filter { !$0.isFolder }
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
        let executor = RequestExecutor(document: doc, environment: activeEnvironment)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let outcome = try await executor.execute(snapshot, at: path, session: sessionVariables)
            applyCaptures(outcome.captures)
            let outcomes = outcome.assertions.map { outcome in
                AssertionOutcomeView(
                    expression: outcome.expression,
                    op: outcome.op,
                    expected: outcome.expected,
                    actual: outcome.actual,
                    pass: outcome.pass
                )
            }
            return SingleRunOutcome(
                state: outcomes.contains { !$0.pass } ? .failed : .passed,
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
        var body: String
        var followRedirects: Bool
        var timeout: Int?
    }

    /// Interpolate variables, apply auth, fill path params and fold query params into the URL.
    static func effectiveRequest(from snapshot: OCRequestSnapshot, variables: [String: String]) -> EffectiveRequest {
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
            followRedirects: snapshot.settings.followRedirects ?? true,
            timeout: snapshot.settings.timeout
        )
    }

    /// Unset secrets this request refers to as `{{name}}`; unrelated unset secrets do not block it.
    static func missingSecrets(usedBy snapshot: OCRequestSnapshot, missing: [String], variables: [String: String]) -> [String] {
        var parts = [snapshot.url, snapshot.bodyData]
        parts += snapshot.params.filter { !$0.disabled }.flatMap { [$0.name, $0.value] }
        parts += snapshot.headers.filter { !$0.disabled }.flatMap { [$0.name, $0.value] }
        switch snapshot.authKind {
        case .basic(let username, let password): parts += [username, password]
        case .bearer(let token): parts.append(token)
        case .apiKey(let key, let value, _): parts += [key, value]
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


