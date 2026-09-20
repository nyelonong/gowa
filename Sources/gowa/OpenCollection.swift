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
    var docs: String?
}

// MARK: - Environments

struct OCVariable: Equatable, Sendable {
    var name: String
    var value: String
    var secret: Bool
    var disabled: Bool
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
        let text = try Yams.dump(object: root, sortKeys: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
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
                let http = item["http"] as? [String: Any] ?? [:]
                nodes.append(OCNode(
                    path: path,
                    name: info["name"] as? String ?? "Untitled",
                    isFolder: isFolder,
                    method: http["method"] as? String,
                    url: http["url"] as? String
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
        var item: [String: Any] = [
            "info": ["name": snapshot.name, "type": "http"],
            "http": buildHTTP(snapshot, preserving: [:]),
        ]
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

    func requestSnapshot(at path: NodePath) -> OCRequestSnapshot? {
        guard let item = item(at: path), let http = item["http"] as? [String: Any] else { return nil }
        let info = item["info"] as? [String: Any] ?? [:]
        let settings = http["settings"] as? [String: Any] ?? [:]
        return OCRequestSnapshot(
            name: info["name"] as? String ?? "Untitled",
            method: http["method"] as? String ?? "GET",
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
            bodyType: bodyField(item, "type"),
            bodyData: bodyField(item, "data") ?? "",
            authKind: readAuth(item),
            settings: OCSettings(
                followRedirects: settings["followRedirects"] as? Bool,
                timeout: settings["timeout"] as? Int
            ),
            docs: item["docs"] as? String
        )
    }

    /// Body handling: raw families carry `data`; graphql carries `query`.
    private func bodyField(_ item: [String: Any], _ key: String) -> String? {
        guard let body = item["http"] as? [String: Any], let bodyDict = body["body"] as? [String: Any] else { return nil }
        if let value = bodyDict[key] as? String { return value }
        return nil
    }

    func updateRequest(at path: NodePath, snapshot: OCRequestSnapshot) {
        guard var item = item(at: path) else { return }
        var info = item["info"] as? [String: Any] ?? [:]
        info["name"] = snapshot.name
        item["info"] = info

        item["http"] = buildHTTP(snapshot, preserving: item)
        if let docs = snapshot.docs, !docs.isEmpty { item["docs"] = docs } else { item.removeValue(forKey: "docs") }
        write(item, at: path)
    }

    private func buildHTTP(_ snapshot: OCRequestSnapshot, preserving item: [String: Any]) -> [String: Any] {
        var http = item["http"] as? [String: Any] ?? [:]
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
        if snapshot.method.requestHasBody {
            var body: [String: Any] = ["type": snapshot.bodyType ?? "json", "data": snapshot.bodyData]
            if snapshot.bodyType == "graphql", let existing = (item["http"] as? [String: Any])?["body"] as? [String: Any],
               let variables = existing["variables"] {
                body["variables"] = variables
                body.removeValue(forKey: "data")
                body["query"] = snapshot.bodyData
            }
            http["body"] = body
        } else {
            http.removeValue(forKey: "body")
        }
        switch snapshot.authKind {
        case .none: http["auth"] = ["type": "none"]
        case .inherit: http["auth"] = ["type": "inherit"]
        case .basic(let username, let password):
            http["auth"] = ["type": "basic", "username": username, "password": password]
        case .bearer(let token):
            http["auth"] = ["type": "bearer", "token": token]
        case .apiKey(let key, let value, let placement):
            http["auth"] = ["type": "apikey", "key": key, "value": value, "placement": placement]
        case .preserved:
            break // leave the original auth block untouched
        }
        var settings: [String: Any] = [:]
        if let follow = snapshot.settings.followRedirects { settings["followRedirects"] = follow }
        if let timeout = snapshot.settings.timeout { settings["timeout"] = timeout }
        if !settings.isEmpty { http["settings"] = settings } else { http.removeValue(forKey: "settings") }
        return http
    }

    private func readAuth(_ item: [String: Any]) -> OAuthKind {
        guard let auth = (item["http"] as? [String: Any])?["auth"] as? [String: Any],
              let type = auth["type"] as? String
        else { return .none }
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

    /// Substitute `{{name}}` placeholders; unknown variables stay literal.
    nonisolated static func interpolate(_ template: String, _ variables: [String: String]) -> String {
        guard template.contains("{{") else { return template }
        var result = template
        for (name, value) in variables {
            result = result.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return result
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
