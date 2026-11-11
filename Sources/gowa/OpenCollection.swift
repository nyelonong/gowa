import CryptoKit
import Foundation
import Yams

enum OCError: LocalizedError {
    case invalidFormat(String)
    case noFile
    case notARequest

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let detail): "Invalid OpenCollection file: \(detail)"
        case .noFile: "Collection has no file on disk yet"
        case .notARequest: "Not an HTTP request"
        }
    }
}

// MARK: - Paths and node snapshots

/// Address of an item inside the collection: index path through nested `items` arrays.
typealias NodePath = [Int]

struct OCNode: Identifiable {
    let path: NodePath
    let name: String
    let isFolder: Bool
    let method: String?
    let url: String?
    var kind: String = "http"

    var id: String { path.map(String.init).joined(separator: ".") }
}

// MARK: - Typed request snapshot

struct OCParam: Equatable, Sendable {
    var name: String
    var value: String
    var kind: String // "query" | "path"
    var disabled: Bool
}

struct OCHeader: Equatable, Sendable {
    var name: String
    var value: String
    var disabled: Bool
}

enum OAuthKind: Equatable, Sendable {
    case none
    case inherit
    case basic(username: String, password: String)
    case bearer(token: String)
    case apiKey(key: String, value: String, placement: String)
    case preserved // any other spec auth type: kept as-is in the document
}

struct OCCapture: Equatable, Sendable {
    var variableName: String
    var expression: String // spec jsonq selector, e.g. $.access_token
    var scope: String // "runtime" (session) | "environment" (persisted)
    var disabled: Bool
}

struct OCAssertion: Equatable, Sendable {
    var expression: String // res.status, res.body.path, res.headers.Name, res.time
    var op: String // eq, neq, gt, gte, lt, lte, contains, startsWith, endsWith, isString, isNumber, isBoolean, exists, notExists
    var value: String
    var disabled: Bool
}

/// A form-urlencoded or multipart field. Multipart `file` parts hold a path,
/// relative to the collection file when it lives beside it.
struct OCFormField: Equatable, Sendable {
    var name: String
    var value: String
    var kind: String = "text" // "text" | "file"
    var contentType: String = ""
    var disabled: Bool = false
}

struct OCSettings: Equatable, Sendable {
    var followRedirects: Bool?
    var timeout: Int?
}

struct OCRequestSnapshot: Sendable {
    var name: String
    var method: String
    var url: String
    var params: [OCParam]
    var headers: [OCHeader]
    var bodyType: String?
    var bodyData: String
    var authKind: OAuthKind
    var settings: OCSettings
    var captures: [OCCapture] = []
    var assertions: [OCAssertion] = []
    var docs: String?
    var formFields: [OCFormField] = []
    var filePath: String = ""
    var fileContentType: String = ""
    var graphqlVariables: String = ""

    var isGraphQL: Bool { bodyType == "graphql" }
}

/// Collection- or folder-level `request` defaults that requests inherit.
struct OCDefaults: Equatable, Sendable {
    var headers: [OCHeader] = []
    var auth: OAuthKind = .inherit
    var variables: [OCVariable] = []
    var docs: String?
}

// MARK: - Environments

struct OCVariable: Equatable, Sendable, Identifiable {
    var name: String
    var value: String
    var secret: Bool
    var disabled: Bool

    var id: String { name }
}

struct OCEnvironmentSnapshot: Identifiable, Equatable, Sendable {
    var name: String
    var variables: [OCVariable]

    var id: String { name }
}

// MARK: - Document

/// Wrapper over the parsed OpenCollection YAML dictionary. Dictionary-first:
/// edits mutate the underlying tree so unknown spec sections survive a
/// load/save round-trip untouched.
@MainActor
final class OpenCollectionDocument {
    private(set) var url: URL?
    var root: [String: Any]

    static let specVersion = "1.0.0"

    init(root: [String: Any] = [:], url: URL? = nil) {
        self.root = root
        self.url = url
    }

    // MARK: Loading / saving

    static func load(from url: URL) throws -> OpenCollectionDocument {
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let parsed = try Yams.load(yaml: text) as? [String: Any] else {
            throw OCError.invalidFormat("not a YAML mapping")
        }
        let doc = OpenCollectionDocument(root: parsed, url: url)
        if doc.root["opencollection"] == nil {
            doc.root["opencollection"] = OpenCollectionDocument.specVersion
        }
        return doc
    }

    func save() throws {
        guard let url else { throw OCError.noFile }
        try save(to: url)
    }

    func save(to url: URL) throws {
        self.url = url
        _ = documentID // ensure the stable id exists before the output copy
        var output = root
        stripSecretsForSave(into: &output)
        let text = try Yams.dump(object: output, sortKeys: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Secret values are stored in the macOS Keychain and stripped from the
    /// written YAML — the committed file contains variable names only.
    private func stripSecretsForSave(into output: inout [String: Any]) {
        guard var config = output["config"] as? [String: Any],
              let environments = config["environments"] as? [[String: Any]]
        else { return }

        var updated: [[String: Any]] = []
        for var environment in environments {
            let envName = environment["name"] as? String ?? ""
            if var variables = environment["variables"] as? [[String: Any]] {
                for index in variables.indices {
                    guard variables[index]["secret"] as? Bool == true,
                          let value = variables[index]["value"] as? String,
                          !value.isEmpty
                    else { continue }
                    let name = variables[index]["name"] as? String ?? ""
                    Keychain.setValue(value, account: secretAccount(env: envName, variable: name))
                    variables[index]["value"] = ""
                }
                environment["variables"] = variables
            }
            updated.append(environment)
        }
        config["environments"] = updated
        output["config"] = config
    }

    // MARK: - Secret accounts

    /// Stable identity for keychain accounts: lives under the spec's
    /// `extensions` block so it survives file renames and moves.
    var documentID: String {
        var extensions = root["extensions"] as? [String: Any] ?? [:]
        var gowa = extensions["gowa"] as? [String: Any] ?? [:]
        if let existing = gowa["id"] as? String, !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        gowa["id"] = fresh
        extensions["gowa"] = gowa
        root["extensions"] = extensions
        return fresh
    }

    func secretAccount(env: String, variable: String) -> String {
        "\(documentID).\(env).\(variable)"
    }

    /// Resolves the active environment into interpolation values. Secret
    /// variables read from the Keychain; values imported from YAML still
    /// work until the next save migrates them. `missingSecrets` lists secret
    /// variables with no stored value.
    func resolveVariables(in environmentName: String?) -> (values: [String: String], missingSecrets: [String]) {
        guard let environmentName,
              let environment = environments.first(where: { $0.name == environmentName })
        else { return ([:], []) }

        var values: [String: String] = [:]
        var missing: [String] = []
        for variable in environment.variables where !variable.disabled && !variable.name.isEmpty {
            if variable.secret {
                if let stored = Keychain.value(account: secretAccount(env: environment.name, variable: variable.name)) {
                    values[variable.name] = stored
                } else if !variable.value.isEmpty {
                    values[variable.name] = variable.value
                } else {
                    missing.append(variable.name)
                }
            } else {
                values[variable.name] = variable.value
            }
        }
        return (values, missing)
    }

    // MARK: Info

    private func info(_ key: String) -> String? {
        root[key] as? String
    }

    var name: String {
        get { (root["info"] as? [String: Any]).flatMap { $0["name"] as? String } ?? "Untitled collection" }
        set { setInfoField("name", newValue) }
    }

    private func setInfoField(_ key: String, _ value: String) {
        var info = (root["info"] as? [String: Any]) ?? [:]
        info[key] = value
        root["info"] = info
    }

    // MARK: Tree enumeration

    private func items(at path: NodePath) -> [[String: Any]] {
        var current = root["items"] as? [[String: Any]] ?? []
        for index in path {
            guard index < current.count else { return [] }
            current = current[index]["items"] as? [[String: Any]] ?? []
        }
        return current
    }

    private func item(at path: NodePath) -> [String: Any]? {
        var level = root["items"] as? [[String: Any]] ?? []
        var current: [String: Any]?
        for index in path {
            guard index < level.count else { return nil }
            current = level[index]
            level = current?["items"] as? [[String: Any]] ?? []
        }
        return current
    }

    private func parentLevel(for path: NodePath) -> [[String: Any]]? {
        guard path.count > 1 else { return root["items"] as? [[String: Any]] }
        return items(at: Array(path.dropLast()))
    }

    func enumerate() -> [OCNode] {
        var nodes: [OCNode] = []
        func walk(_ items: [[String: Any]], _ basePath: NodePath) {
            for (index, item) in items.enumerated() {
                let path = basePath + [index]
                let info = item["info"] as? [String: Any] ?? [:]
                let isFolder = (info["type"] as? String) == "folder"
                let kind = info["type"] as? String ?? "http"
                let details = Self.details(of: item) ?? [:]
                nodes.append(OCNode(
                    path: path,
                    name: info["name"] as? String ?? "Untitled",
                    isFolder: isFolder,
                    method: details["method"] as? String,
                    url: details["url"] as? String,
                    kind: kind
                ))
                if isFolder {
                    walk(item["items"] as? [[String: Any]] ?? [], path)
                }
            }
        }
        walk(root["items"] as? [[String: Any]] ?? [], [])
        return nodes
    }

    // MARK: Mutations

    func addFolder(under parent: NodePath?, name: String) -> NodePath {
        let folder: [String: Any] = [
            "info": ["name": name, "type": "folder"],
            "items": [[String: Any]](),
        ]
        return append(folder, under: parent)
    }

    func addRequest(under parent: NodePath?, snapshot: OCRequestSnapshot) -> NodePath {
        let key = snapshot.isGraphQL ? "graphql" : "http"
        var item: [String: Any] = [
            "info": ["name": snapshot.name, "type": key],
            key: buildHTTP(snapshot, preserving: [:]),
        ]
        writeSettings(snapshot, into: &item)
        writeRuntime(snapshot, into: &item, preserving: item)
        if let docs = snapshot.docs, !docs.isEmpty { item["docs"] = docs }
        return append(item, under: parent)
    }

    func rename(at path: NodePath, to name: String) {
        guard var item = item(at: path) else { return }
        var info = item["info"] as? [String: Any] ?? [:]
        info["name"] = name
        item["info"] = info
        write(item, at: path)
    }

    func delete(at path: NodePath) {
        guard var level = parentLevel(for: path), let last = path.last, last < level.count else { return }
        level.remove(at: last)
        writeItems(level, at: Array(path.dropLast()))
    }

    func duplicate(at path: NodePath) {
        guard var level = parentLevel(for: path), let last = path.last, last < level.count else { return }
        level.insert(level[last], at: last + 1)
        writeItems(level, at: Array(path.dropLast()))
    }

    private func append(_ entry: [String: Any], under parent: NodePath?) -> NodePath {
        if let parent {
            var parentItem = item(at: parent) ?? [:]
            var items = parentItem["items"] as? [[String: Any]] ?? []
            items.append(entry)
            parentItem["items"] = items
            write(parentItem, at: parent)
            return parent + [items.count - 1]
        } else {
            var items = root["items"] as? [[String: Any]] ?? []
            items.append(entry)
            root["items"] = items
            return [items.count - 1]
        }
    }

    private func write(_ item: [String: Any], at path: NodePath) {
        guard let last = path.last else { root = item; return }
        guard var level = parentLevel(for: path), last < level.count else { return }
        level[last] = item
        writeItems(level, at: Array(path.dropLast()))
    }

    private func writeItems(_ items: [[String: Any]], at parent: NodePath) {
        if parent.isEmpty {
            root["items"] = items
        } else {
            var parentItem = item(at: parent) ?? [:]
            parentItem["items"] = items
            write(parentItem, at: parent)
        }
    }

    // MARK: Request reading / writing

    /// Protocol block of a request item: `http` or `graphql`.
    nonisolated static func details(of item: [String: Any]) -> [String: Any]? {
        (item["http"] as? [String: Any]) ?? (item["graphql"] as? [String: Any])
    }

    func requestSnapshot(at path: NodePath) -> OCRequestSnapshot? {
        guard let item = item(at: path), let http = Self.details(of: item) else { return nil }
        let isGraphQL = item["http"] == nil
        let info = item["info"] as? [String: Any] ?? [:]
        let settings = item["settings"] as? [String: Any] ?? http["settings"] as? [String: Any] ?? [:]
        var snapshot = OCRequestSnapshot(
            name: info["name"] as? String ?? "Untitled",
            method: http["method"] as? String ?? (isGraphQL ? "POST" : "GET"),
            url: http["url"] as? String ?? "",
            params: (http["params"] as? [[String: Any]] ?? []).map {
                OCParam(
                    name: $0["name"] as? String ?? "",
                    value: $0["value"] as? String ?? "",
                    kind: $0["type"] as? String ?? "query",
                    disabled: $0["disabled"] as? Bool ?? false
                )
            },
            headers: (http["headers"] as? [[String: Any]] ?? []).map {
                OCHeader(
                    name: $0["name"] as? String ?? "",
                    value: $0["value"] as? String ?? "",
                    disabled: $0["disabled"] as? Bool ?? false
                )
            },
            bodyType: nil,
            bodyData: "",
            authKind: readAuth(http),
            settings: OCSettings(
                followRedirects: settings["followRedirects"] as? Bool,
                timeout: (settings["timeout"] as? NSNumber)?.intValue
            ),
            captures: Self.readCaptures(item),
            assertions: Self.readAssertions(item),
            docs: Self.readDocs(item["docs"])
        )
        if isGraphQL {
            let body = Self.selectedVariant(http["body"], key: "body") ?? [:]
            snapshot.bodyType = "graphql"
            snapshot.bodyData = body["query"] as? String ?? ""
            snapshot.graphqlVariables = body["variables"] as? String ?? ""
        } else if let body = Self.selectedVariant(http["body"], key: "body") {
            Self.readBody(body, into: &snapshot)
        }
        return snapshot
    }

    /// A body or message may be one value or a list of titled variants.
    nonisolated static func selectedVariant(_ raw: Any?, key: String) -> [String: Any]? {
        if let single = raw as? [String: Any] { return single }
        guard let variants = raw as? [[String: Any]], !variants.isEmpty else { return nil }
        let chosen = variants.first { $0["selected"] as? Bool == true } ?? variants[0]
        return chosen[key] as? [String: Any]
    }

    nonisolated static func readBody(_ body: [String: Any], into snapshot: inout OCRequestSnapshot) {
        let type = body["type"] as? String ?? "json"
        snapshot.bodyType = type
        switch type {
        case "form-urlencoded":
            if let raw = body["data"] as? String {
                snapshot.formFields = raw.split(separator: "&").map { pair in
                    let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    return OCFormField(
                        name: parts[0].removingPercentEncoding ?? parts[0],
                        value: parts.count > 1 ? (parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]) : ""
                    )
                }
            } else {
                snapshot.formFields = (body["data"] as? [[String: Any]] ?? []).map {
                    OCFormField(name: $0["name"] as? String ?? "", value: $0["value"] as? String ?? "", disabled: $0["disabled"] as? Bool ?? false)
                }
            }
        case "multipart-form":
            snapshot.formFields = (body["data"] as? [[String: Any]] ?? []).flatMap { part -> [OCFormField] in
                let values: [String] = (part["value"] as? [String]) ?? [(part["value"] as? String) ?? ""]
                return values.map { value in
                    OCFormField(
                        name: part["name"] as? String ?? "",
                        value: value,
                        kind: part["type"] as? String ?? "text",
                        contentType: part["contentType"] as? String ?? "",
                        disabled: part["disabled"] as? Bool ?? false
                    )
                }
            }
        case "file":
            let files = body["data"] as? [[String: Any]] ?? []
            let chosen = files.first { $0["selected"] as? Bool == true } ?? files.first ?? [:]
            snapshot.filePath = chosen["filePath"] as? String ?? ""
            snapshot.fileContentType = chosen["contentType"] as? String ?? ""
        default:
            snapshot.bodyData = body["data"] as? String ?? ""
        }
    }

    nonisolated static func bodyDict(_ snapshot: OCRequestSnapshot, existing: [String: Any]?) -> [String: Any] {
        let type = snapshot.bodyType ?? "json"
        switch type {
        case "form-urlencoded":
            return ["type": type, "data": snapshot.formFields.map { field -> [String: Any] in
                var entry: [String: Any] = ["name": field.name, "value": field.value]
                if field.disabled { entry["disabled"] = true }
                return entry
            }]
        case "multipart-form":
            return ["type": type, "data": snapshot.formFields.map { field -> [String: Any] in
                var entry: [String: Any] = ["name": field.name, "value": field.value, "type": field.kind]
                if !field.contentType.isEmpty { entry["contentType"] = field.contentType }
                if field.disabled { entry["disabled"] = true }
                return entry
            }]
        case "file":
            var files = (existing?["type"] as? String == "file" ? existing?["data"] as? [[String: Any]] : nil) ?? []
            let entry: [String: Any] = ["filePath": snapshot.filePath, "contentType": snapshot.fileContentType, "selected": true]
            if let index = files.firstIndex(where: { $0["selected"] as? Bool == true }) ?? (files.isEmpty ? nil : 0) {
                files[index].merge(entry) { _, new in new }
            } else {
                files = [entry]
            }
            return ["type": type, "data": files]
        default:
            return ["type": type, "data": snapshot.bodyData]
        }
    }

    private static func readAssertions(_ item: [String: Any]) -> [OCAssertion] {
        let runtime = item["runtime"] as? [String: Any] ?? [:]
        return (runtime["assertions"] as? [[String: Any]] ?? []).map { entry in
            OCAssertion(
                expression: entry["expression"] as? String ?? "",
                op: entry["operator"] as? String ?? "eq",
                value: entry["value"] as? String ?? "",
                disabled: entry["disabled"] as? Bool ?? false
            )
        }
    }

    private static func readCaptures(_ item: [String: Any]) -> [OCCapture] {
        let runtime = item["runtime"] as? [String: Any] ?? [:]
        guard let actions = runtime["actions"] as? [[String: Any]] else { return [] }
        return actions.compactMap { action in
            guard action["type"] as? String == "set-variable",
                  let selector = action["selector"] as? [String: Any],
                  let expression = selector["expression"] as? String,
                  let variable = action["variable"] as? [String: Any],
                  let name = variable["name"] as? String
            else { return nil }
            let phase = action["phase"] as? String ?? "after-response"
            guard phase == "after-response" else { return nil } // other phases preserved, not executed
            return OCCapture(
                variableName: name,
                expression: expression,
                scope: variable["scope"] as? String ?? "runtime",
                disabled: action["disabled"] as? Bool ?? false
            )
        }
    }

    func updateRequest(at path: NodePath, snapshot: OCRequestSnapshot) {
        guard var item = item(at: path) else { return }
        var info = item["info"] as? [String: Any] ?? [:]
        info["name"] = snapshot.name
        item["info"] = info

        let key = snapshot.isGraphQL ? "graphql" : "http"
        let previous = Self.details(of: item) ?? [:]
        item.removeValue(forKey: snapshot.isGraphQL ? "http" : "graphql")
        info["type"] = key
        item["info"] = info
        item[key] = buildHTTP(snapshot, preserving: [key: previous])
        writeSettings(snapshot, into: &item)
        writeRuntime(snapshot, into: &item, preserving: item)
        if let docs = snapshot.docs, !docs.isEmpty { item["docs"] = docs } else { item.removeValue(forKey: "docs") }
        write(item, at: path)
    }

    /// Writes Gowa-owned runtime sections (after-response captures, checks)
    /// into `runtime`, preserving foreign content (other phases, scripts,
    /// variables) untouched.
    private func writeRuntime(_ snapshot: OCRequestSnapshot, into item: inout [String: Any], preserving current: [String: Any]) {
        var runtime = current["runtime"] as? [String: Any] ?? [:]

        let actions = runtime["actions"] as? [[String: Any]] ?? []
        let otherActions = actions.filter { ($0["type"] as? String) != "set-variable" || (($0["phase"] as? String) ?? "after-response") != "after-response" }
        var ours: [[String: Any]] = []
        for capture in snapshot.captures where !capture.variableName.isEmpty && !capture.expression.isEmpty {
            ours.append([
                "type": "set-variable",
                "phase": "after-response",
                "selector": ["method": "jsonq", "expression": capture.expression],
                "variable": ["name": capture.variableName, "scope": capture.scope],
                "disabled": capture.disabled,
            ])
        }
        if otherActions.isEmpty && ours.isEmpty {
            runtime.removeValue(forKey: "actions")
        } else {
            runtime["actions"] = otherActions + ours
        }

        let checks: [[String: Any]] = snapshot.assertions
            .filter { !$0.expression.isEmpty }
            .map { assertion in
                var entry: [String: Any] = ["expression": assertion.expression, "operator": assertion.op]
                if !assertion.value.isEmpty { entry["value"] = assertion.value }
                if assertion.disabled { entry["disabled"] = true }
                return entry
            }
        if checks.isEmpty {
            runtime.removeValue(forKey: "assertions")
        } else {
            runtime["assertions"] = checks
        }

        if runtime.isEmpty {
            item.removeValue(forKey: "runtime")
        } else {
            item["runtime"] = runtime
        }
    }

    private func buildHTTP(_ snapshot: OCRequestSnapshot, preserving item: [String: Any]) -> [String: Any] {
        var http = item.values.first as? [String: Any] ?? [:]
        http["method"] = snapshot.method
        http["url"] = snapshot.url
        if !snapshot.params.isEmpty {
            http["params"] = snapshot.params.map {
                ["name": $0.name, "value": $0.value, "type": $0.kind, "disabled": $0.disabled]
            }
        } else {
            http.removeValue(forKey: "params")
        }
        if !snapshot.headers.isEmpty {
            http["headers"] = snapshot.headers.map {
                ["name": $0.name, "value": $0.value, "disabled": $0.disabled]
            }
        } else {
            http.removeValue(forKey: "headers")
        }
        if snapshot.isGraphQL {
            var body: [String: Any] = ["query": snapshot.bodyData]
            if !snapshot.graphqlVariables.isEmpty { body["variables"] = snapshot.graphqlVariables }
            http["body"] = body
        } else if snapshot.method.requestHasBody {
            http["body"] = Self.bodyDict(snapshot, existing: Self.selectedVariant(http["body"], key: "body"))
        } else {
            http.removeValue(forKey: "body")
        }
        if let auth = authDict(snapshot.authKind) {
            http["auth"] = auth
        }
        http.removeValue(forKey: "settings")
        return http
    }

    /// Spec request settings live beside the protocol block, not inside it.
    private func writeSettings(_ snapshot: OCRequestSnapshot, into item: inout [String: Any]) {
        var settings = item["settings"] as? [String: Any] ?? [:]
        settings.removeValue(forKey: "followRedirects")
        settings.removeValue(forKey: "timeout")
        if let follow = snapshot.settings.followRedirects { settings["followRedirects"] = follow }
        if let timeout = snapshot.settings.timeout { settings["timeout"] = timeout }
        if settings.isEmpty { item.removeValue(forKey: "settings") } else { item["settings"] = settings }
    }

    /// Spec `auth` block; nil for `.preserved`, whose original block stays untouched.
    private func authDict(_ kind: OAuthKind) -> [String: Any]? {
        switch kind {
        case .none: ["type": "none"]
        case .inherit: ["type": "inherit"]
        case .basic(let username, let password): ["type": "basic", "username": username, "password": password]
        case .bearer(let token): ["type": "bearer", "token": token]
        case .apiKey(let key, let value, let placement): ["type": "apikey", "key": key, "value": value, "placement": placement]
        case .preserved: nil
        }
    }

    private func readAuthDict(_ auth: [String: Any]) -> OAuthKind {
        guard let type = auth["type"] as? String else { return .none }
        switch type {
        case "none": return .none
        case "inherit": return .inherit
        case "basic": return .basic(username: auth["username"] as? String ?? "", password: auth["password"] as? String ?? "")
        case "bearer": return .bearer(token: auth["token"] as? String ?? "")
        case "apikey":
            return .apiKey(
                key: auth["key"] as? String ?? "",
                value: auth["value"] as? String ?? "",
                placement: auth["placement"] as? String ?? "header"
            )
        default: return .preserved
        }
    }

    private func readAuth(_ details: [String: Any]) -> OAuthKind {
        guard let auth = details["auth"] as? [String: Any] else { return .none }
        return readAuthDict(auth)
    }

    // MARK: Environments

    var environments: [OCEnvironmentSnapshot] {
        get {
            let config = root["config"] as? [String: Any] ?? [:]
            return (config["environments"] as? [[String: Any]] ?? []).map { env in
                OCEnvironmentSnapshot(
                    name: env["name"] as? String ?? "Untitled",
                    variables: (env["variables"] as? [[String: Any]] ?? []).map {
                        OCVariable(
                            name: $0["name"] as? String ?? "",
                            value: $0["value"] as? String ?? "",
                            secret: $0["secret"] as? Bool ?? false,
                            disabled: $0["disabled"] as? Bool ?? false
                        )
                    }
                )
            }
        }
        set {
            var config = root["config"] as? [String: Any] ?? [:]
            config["environments"] = newValue.map { env in
                var dict: [String: Any] = ["name": env.name]
                if !env.variables.isEmpty {
                    dict["variables"] = env.variables.map { variable in
                        var variableDict: [String: Any] = ["name": variable.name, "value": variable.value]
                        if variable.secret { variableDict["secret"] = true }
                        if variable.disabled { variableDict["disabled"] = true }
                        return variableDict
                    }
                }
                return dict
            }
            root["config"] = config
        }
    }

    func variables(in environmentName: String?) -> [String: String] {
        guard let environmentName else { return [:] }
        let env = environments.first { $0.name == environmentName }
        var map: [String: String] = [:]
        for variable in env?.variables ?? [] where !variable.disabled && !variable.name.isEmpty {
            map[variable.name] = variable.value
        }
        return map
    }

    // MARK: Interpolation

    /// Evaluate a spec jsonq selector (e.g. `$.data.token`, `$.items[0].id`)
    /// against a JSON body. Returns nil when the path misses or the body
    /// isn't JSON.
    nonisolated static func evaluateCapture(_ expression: String, body: Data) -> String? {
        guard let value = evaluateCaptureValue(expression, body: body) else { return nil }
        return scalarString(value) ?? String(data: body, encoding: .utf8)
    }

    /// Full-fidelity variant: returns dictionaries/arrays too, so `exists`
    /// checks work for object values.
    nonisolated static func evaluateCaptureValue(_ expression: String, body: Data) -> Any? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("$") else { return nil }
        let path = String(trimmed.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !path.isEmpty else {
            // `$` alone = the whole document
            return try? JSONSerialization.jsonObject(with: body)
        }

        var components: [String] = []
        for raw in path.split(separator: ".").flatMap({ Self.expandIndex($0) }) {
            components.append(raw)
        }

        guard var current: Any = try? JSONSerialization.jsonObject(with: body) else { return nil }
        for component in components {
            if component.hasPrefix("[") && component.hasSuffix("]") {
                guard let index = Int(component.dropFirst().dropLast()),
                      let array = current as? [Any],
                      array.indices.contains(index)
                else { return nil }
                current = array[index]
            } else {
                guard let dictionary = current as? [String: Any],
                      let value = dictionary[component]
                else { return nil }
                current = value
            }
        }
        return current
    }

    private nonisolated static func expandIndex(_ component: Substring) -> [String] {
        // "items[0]" → ["items", "[0]"]; "[0]" stays as-is.
        guard let open = component.firstIndex(of: "[") else { return [String(component)] }
        let name = String(component[..<open])
        let bracket = String(component[open...])
        return name.isEmpty ? [bracket] : [name, bracket]
    }

    private nonisolated static func scalarString(_ value: Any) -> String? {
        switch value {
        case let string as String: return string
        case let bool as Bool: return bool ? "true" : "false"
        case let number as NSNumber: return number.stringValue
        case is NSNull: return nil
        default: return nil
        }
    }

    struct AssertionOutcome: Sendable {
        let expression: String
        let op: String
        let expected: String?
        let actual: String?
        let pass: Bool
        let note: String?
    }

    /// Evaluate one check against a response. Expressions:
    /// `res.status`, `res.time` (ms), `res.body`, `res.body.<json path>`,
    /// `res.headers.<name>`.
    nonisolated static func evaluateAssertion(_ assertion: OCAssertion, response: HTTPResult) -> AssertionOutcome {
        let expression = assertion.expression.trimmingCharacters(in: .whitespaces)
        let actual: String?
        var note: String?

        if expression == "res.status" {
            actual = String(response.status)
        } else if expression == "res.time" {
            actual = String(format: "%.0f", response.elapsed.milliseconds)
        } else if expression == "res.body" {
            actual = String(data: response.body, encoding: .utf8)
        } else if expression.hasPrefix("res.body.") {
            let path = String(expression.dropFirst("res.body.".count))
            let raw = evaluateCaptureValue("$." + path, body: response.body)
            actual = raw.flatMap { scalarString($0) } ?? (raw != nil ? "<non-scalar>" : nil)
        } else if expression.hasPrefix("res.headers.") {
            let name = String(expression.dropFirst("res.headers.".count)).lowercased()
            actual = response.headers.first { $0.name.lowercased() == name }?.value
        } else {
            actual = nil
            note = "unsupported expression"
        }

        return AssertionOutcome(
            expression: assertion.expression,
            op: assertion.op,
            expected: assertion.value.isEmpty ? nil : assertion.value,
            actual: actual,
            pass: compare(actual: actual, op: assertion.op, expected: assertion.value),
            note: note
        )
    }

    nonisolated static func compare(actual: String?, op: String, expected: String) -> Bool {
        switch op {
        case "exists":
            return actual != nil
        case "notExists":
            return actual == nil
        case "isString":
            return actual != nil && Double(actual!) == nil && !(actual == "true" || actual == "false")
        case "isNumber":
            return actual != nil && Double(actual!) != nil
        case "isBoolean":
            return actual == "true" || actual == "false"
        case "isNull":
            return actual == nil
        default:
            break
        }
        guard let actual else { return false }

        switch op {
        case "eq": return actual == expected || numericEqual(actual, expected)
        case "neq": return !(actual == expected || numericEqual(actual, expected))
        case "contains": return actual.contains(expected)
        case "startsWith": return actual.hasPrefix(expected)
        case "endsWith": return actual.hasSuffix(expected)
        case "gt", "gte", "lt", "lte":
            guard let a = Double(actual), let b = Double(expected) else { return false }
            switch op {
            case "gt": return a > b
            case "gte": return a >= b
            case "lt": return a < b
            case "lte": return a <= b
            default: return false
            }
        default:
            return false
        }
    }

    private nonisolated static func numericEqual(_ a: String, _ b: String) -> Bool {
        guard let x = Double(a), let y = Double(b) else { return false }
        return x == y
    }

    // MARK: - Request defaults inheritance

    func isFolder(_ path: NodePath) -> Bool {
        (item(at: path)?["info"] as? [String: Any])?["type"] as? String == "folder"
    }

    /// Defaults for a folder, or for the whole collection when `path` is nil.
    func defaults(at path: NodePath?) -> OCDefaults {
        let owner = path.flatMap { item(at: $0) } ?? root
        let request = owner["request"] as? [String: Any] ?? [:]
        return OCDefaults(
            headers: (request["headers"] as? [[String: Any]] ?? []).map {
                OCHeader(name: $0["name"] as? String ?? "", value: $0["value"] as? String ?? "", disabled: $0["disabled"] as? Bool ?? false)
            },
            auth: (request["auth"] as? [String: Any]).map(readAuthDict) ?? .inherit,
            variables: Self.readVariables(request["variables"]),
            docs: Self.readDocs(owner["docs"])
        )
    }

    func updateDefaults(at path: NodePath?, _ defaults: OCDefaults) {
        var owner = path.flatMap { item(at: $0) } ?? root
        var request = owner["request"] as? [String: Any] ?? [:]
        if defaults.headers.isEmpty {
            request.removeValue(forKey: "headers")
        } else {
            request["headers"] = defaults.headers.map { ["name": $0.name, "value": $0.value, "disabled": $0.disabled] }
        }
        switch defaults.auth {
        case .inherit: request.removeValue(forKey: "auth")
        case .preserved: break
        default: request["auth"] = authDict(defaults.auth)
        }
        if defaults.variables.isEmpty {
            request.removeValue(forKey: "variables")
        } else {
            request["variables"] = defaults.variables.map { variable -> [String: Any] in
                var entry: [String: Any] = ["name": variable.name, "value": variable.value]
                if variable.disabled { entry["disabled"] = true }
                return entry
            }
        }
        if request.isEmpty { owner.removeValue(forKey: "request") } else { owner["request"] = request }
        if let docs = defaults.docs, !docs.isEmpty {
            owner["docs"] = docs
        } else if owner["docs"] is String {
            owner.removeValue(forKey: "docs")
        }
        if let path { write(owner, at: path) } else { root = owner }
    }

    /// Variable entries hold a string or a typed `{type, data}` value.
    nonisolated static func readVariables(_ raw: Any?) -> [OCVariable] {
        (raw as? [[String: Any]] ?? []).map { entry in
            let value: String
            if let text = entry["value"] as? String {
                value = text
            } else if let typed = entry["value"] as? [String: Any] {
                value = typed["data"] as? String ?? ""
            } else {
                value = ""
            }
            return OCVariable(
                name: entry["name"] as? String ?? "",
                value: value,
                secret: false,
                disabled: entry["disabled"] as? Bool ?? false
            )
        }
    }

    nonisolated static func readDocs(_ raw: Any?) -> String? {
        if let text = raw as? String { return text }
        return (raw as? [String: Any])?["content"] as? String
    }

    /// Collection, folder (outermost first), and request variables in
    /// increasing precedence; environment values slot in after the collection.
    func layeredVariables(at path: NodePath?, environment: [String: String]) -> [String: String] {
        var values: [String: String] = [:]
        func apply(_ variables: [OCVariable]) {
            for variable in variables where !variable.disabled && !variable.name.isEmpty {
                values[variable.name] = variable.value
            }
        }
        apply(defaults(at: nil).variables)
        values.merge(environment) { _, new in new }
        guard let path else { return values }
        for depth in 1..<max(path.count, 1) {
            let folder = Array(path.prefix(depth))
            if isFolder(folder) { apply(defaults(at: folder).variables) }
        }
        if let item = item(at: path) {
            apply(Self.readVariables((item["runtime"] as? [String: Any])?["variables"]))
        }
        return values
    }


    /// Folder-level and collection-level request defaults (`request` blocks),
    /// ordered outermost → innermost.
    func defaultChain(for path: NodePath) -> [[String: Any]] {
        var chain: [[String: Any]] = []
        if let rootRequest = root["request"] as? [String: Any] { chain.append(rootRequest) }
        var level = root["items"] as? [[String: Any]] ?? []
        var current: [String: Any]?
        for index in path {
            guard index < level.count else { break }
            current = level[index]
            if let request = current?["request"] as? [String: Any],
               (current?["info"] as? [String: Any])?["type"] as? String == "folder" {
                chain.append(request)
            }
            level = current?["items"] as? [[String: Any]] ?? []
        }
        return chain
    }

    /// Resolve `inherit` auth: walk from the innermost folder outward; the
    /// nearest level that sets auth wins, and an explicit `none` stops the walk.
    func resolvedAuth(at path: NodePath) -> OAuthKind? {
        for defaults in defaultChain(for: path).reversed() {
            guard let auth = defaults["auth"] as? [String: Any] else { continue }
            let kind = readAuthDict(auth)
            switch kind {
            case .inherit, .preserved: continue
            default: return kind
            }
        }
        return nil
    }

    /// Merge folder/collection default headers (outermost first) under the
    /// request's own headers, which win on name conflicts.
    func resolvedHeaders(at path: NodePath, requestHeaders: [OCHeader]) -> [OCHeader] {
        var merged: [OCHeader] = []
        for defaults in defaultChain(for: path) {
            guard let headers = defaults["headers"] as? [[String: Any]] else { continue }
            for header in headers {
                let name = header["name"] as? String ?? ""
                guard !name.isEmpty,
                      header["disabled"] as? Bool != true,
                      !merged.contains(where: { $0.name.lowercased() == name.lowercased() })
                else { continue }
                merged.append(OCHeader(name: name, value: header["value"] as? String ?? "", disabled: false))
            }
        }
        for header in requestHeaders {
            if let position = merged.firstIndex(where: { $0.name.lowercased() == header.name.lowercased() }) {
                merged[position] = header
            } else {
                merged.append(header)
            }
        }
        return merged
    }

    /// Fold inheritance into a snapshot before sending.
    func applyInheritance(to snapshot: inout OCRequestSnapshot, at path: NodePath) {
        if case .inherit = snapshot.authKind {
            snapshot.authKind = resolvedAuth(at: path) ?? .none
        }
        snapshot.headers = resolvedHeaders(at: path, requestHeaders: snapshot.headers)
    }

    func effectiveRequest(at path: NodePath, from snapshot: OCRequestSnapshot, variables: [String: String]) -> AppState.EffectiveRequest {
        var snapshot = snapshot
        applyInheritance(to: &snapshot, at: path)
        return AppState.effectiveRequest(from: snapshot, variables: variables)
    }

    nonisolated static func interpolate(_ template: String, _ variables: [String: String]) -> String {
        guard template.contains("{{") else { return template }
        var result = template
        for (name, value) in variables {
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return TemplateFunctions.render(result)
    }

    // MARK: Sample

    static func sample() -> OpenCollectionDocument {
        let doc = OpenCollectionDocument(root: [
            "opencollection": specVersion,
            "info": [
                "name": "Sample Collection",
                "summary": "Created by Gowa",
            ],
            "config": [
                "environments": [
                    [
                        "name": "Production",
                        "variables": [["name": "baseUrl", "value": "https://echo.usebruno.com"]],
                    ]
                ],
            ],
            "items": [],
        ])
        return doc
    }
}

extension String {
    var requestHasBody: Bool {
        ["POST", "PUT", "PATCH"].contains(uppercased())
    }
}
