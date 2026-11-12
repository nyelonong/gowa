import Foundation

/// Headless commands: `gowa run` runs a collection's requests and `gowa list`
/// prints its tree. Both share the app's model and send pipeline.
/// Exit codes: 0 = all passed, 1 = failures/errors, 2 = usage error.
enum CLIMode {
    nonisolated static func printUsage() {
        print("""
        gowa — HTTP client with OpenCollection collections

        Usage:
          gowa                                  Launch the GUI app
          gowa run <collection.yml> [options]   Run requests, top to bottom
          gowa list <collection.yml> [--json]   Show folders, requests, and environments

        Run options:
          --env NAME        Environment whose variables to use (default: first)
          --id ID           Run only this request, or every request in this folder (IDs from `gowa list`)
          --filter TEXT     Run only requests whose name contains TEXT
          --json            Print one JSON report with each response's status, headers, and body

        Exit codes: 0 all passed, 1 failures/errors, 2 usage error
        """)
    }

    struct Options {
        var path: String?
        var environment: String?
        var id: String?
        var filter: String?
        var json = false
        var help = false
    }

    nonisolated static func parse(_ args: [String], valueFlags: Set<String>, boolFlags: Set<String>) throws(CLIError) -> Options {
        var options = Options()
        var index = 0
        while index < args.count {
            let token = args[index]
            if valueFlags.contains(token) {
                guard index + 1 < args.count else { throw CLIError("\(token) requires a value") }
                let value = args[index + 1]
                switch token {
                case "--env": options.environment = value
                case "--id": options.id = value
                case "--filter": options.filter = value
                default: break
                }
                index += 2
                continue
            }
            if boolFlags.contains(token) {
                if token == "--json" { options.json = true }
            } else if token == "--help" || token == "-h" {
                options.help = true
            } else if token.hasPrefix("-") {
                throw CLIError("unknown argument: \(token)")
            } else if options.path == nil {
                options.path = token
            } else {
                throw CLIError("unexpected argument: \(token)")
            }
            index += 1
        }
        return options
    }

    struct CLIError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    nonisolated static func run(_ args: [String]) async {
        setbuf(stdout, nil) // unbuffered: CLI output must survive SIGTERM
        let options: Options
        do {
            options = try parse(args, valueFlags: ["--env", "--id", "--filter"], boolFlags: ["--json"])
        } catch {
            fail(error.message)
        }
        if options.help { printUsage(); return }
        guard let path = options.path else {
            fail("missing collection file — usage: gowa run <collection.yml> [--env NAME]")
        }
        exit(await runCollection(at: path, options: options))
    }

    nonisolated static func list(_ args: [String]) async {
        let options: Options
        do {
            options = try parse(args, valueFlags: [], boolFlags: ["--json"])
        } catch {
            fail(error.message)
        }
        if options.help { printUsage(); return }
        guard let path = options.path else {
            fail("missing collection file — usage: gowa list <collection.yml> [--json]")
        }
        exit(await listCollection(at: path, json: options.json))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("gowa: \(message)\n".utf8))
        exit(2)
    }

    @MainActor
    private static func load(_ path: String) -> OpenCollectionDocument? {
        guard FileManager.default.fileExists(atPath: path) else {
            FileHandle.standardError.write(Data("gowa: file not found: \(path)\n".utf8))
            return nil
        }
        do {
            return try OpenCollectionDocument.load(from: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("gowa: \(error.localizedDescription)\n".utf8))
            return nil
        }
    }

    @MainActor
    private static func listCollection(at path: String, json: Bool) async -> Int32 {
        guard let document = load(path) else { return 2 }
        if json {
            print(CLIReport.encode(CLIReport.tree(document)))
        } else {
            print(CLIReport.treeText(document), terminator: "")
        }
        return 0
    }

    @MainActor
    private static func runCollection(at path: String, options: Options) async -> Int32 {
        guard let document = load(path) else { return 2 }
        let url = URL(fileURLWithPath: path)
        if let environment = options.environment, !document.environments.contains(where: { $0.name == environment }) {
            let known = document.environments.map(\.name).joined(separator: ", ")
            FileHandle.standardError.write(Data("gowa: no environment named \"\(environment)\"\(known.isEmpty ? "" : " — available: \(known)")\n".utf8))
            return 2
        }

        let envName = options.environment ?? document.environments.first?.name
        let all = document.enumerate()
        let requests = CLIReport.select(all, id: options.id, filter: options.filter)
        if let id = options.id, requests.isEmpty {
            let reason = all.contains(where: { $0.id == id })
                ? "nothing to run under id \(id) — only HTTP and GraphQL requests run"
                : "no item with id \(id) — see `gowa list`"
            FileHandle.standardError.write(Data("gowa: \(reason)\n".utf8))
            return 2
        }
        let locations = CLIReport.locations(all)
        let json = options.json
        if !json {
            print("Running \(document.name) (\(url.lastPathComponent))\(envName.map { " — env: \($0)" } ?? "")\n")
        }

        var sessionVariables: [String: String] = [:]
        var passed = 0
        var failed = 0
        var reports: [[String: Any]] = []

        let executor = RequestExecutor(document: document, environment: envName, cookies: CookieJar(fileURL: nil))
        for node in requests {
            guard let snapshot = document.requestSnapshot(at: node.path) else { continue }
            let method = snapshot.method.uppercased()
            let location = locations[node.id] ?? node.name
            let clock = ContinuousClock()
            let start = clock.now

            do {
                let outcome = try await executor.execute(snapshot, at: node.path, session: sessionVariables)
                for capture in outcome.captures {
                    if let value = capture.value { sessionVariables[capture.name] = value }
                }
                for (name, value) in outcome.environmentVariables { sessionVariables[name] = value }
                for (name, value) in outcome.runtimeVariables { sessionVariables[name] = value }
                if outcome.passed { passed += 1 } else { failed += 1 }
                if json {
                    reports.append(CLIReport.result(id: node.id, location: location, method: method, url: snapshot.url, outcome: outcome))
                } else {
                    printText(node: node, method: method, outcome: outcome)
                }
            } catch {
                failed += 1
                let elapsed = start.duration(to: clock.now)
                if json {
                    reports.append(CLIReport.failure(id: node.id, location: location, method: method, url: snapshot.url, error: CLIReport.describe(error), elapsed: elapsed))
                } else {
                    print("✗ \(method) \(node.name) — \(error.localizedDescription) (\(elapsed.millisecondsText))")
                }
            }
        }

        if json {
            print(CLIReport.encode([
                "collection": document.name,
                "environment": envName ?? NSNull(),
                "passed": passed,
                "failed": failed,
                "total": requests.count,
                "requests": reports,
            ]))
        } else {
            print("\n\(passed) passed, \(failed) failed of \(requests.count) requests")
        }
        return failed == 0 ? 0 : 1
    }

    private static func printText(node: OCNode, method: String, outcome: ExecutionOutcome) {
        print("\(outcome.passed ? "✔" : "✗") \(method) \(node.name) — HTTP \(outcome.response.status) (\(outcome.response.elapsed.millisecondsText))")
        for capture in outcome.captures {
            print("    {{\(capture.name)}} ← \(capture.value == nil ? "NOT FOUND" : "captured")")
        }
        for assertion in outcome.assertions {
            var line = "      \(assertion.pass ? "✔" : "✗") \(assertion.expression) \(assertion.op)"
            if let expected = assertion.expected { line += " [\(expected)]" }
            if let actual = assertion.actual { line += " — got [\(actual)]" }
            print(line)
        }
        for test in outcome.tests {
            print("      \(test.passed ? "✔" : "✗") \(test.name)\(test.error.map { " — \($0)" } ?? "")")
        }
        if let scriptError = outcome.scriptError {
            print("      ✗ \(scriptError)")
        }
        for log in outcome.logs {
            print("      [\(log.level)] \(log.message)")
        }
    }
}

/// Machine-readable output for `gowa list --json` and `gowa run --json`.
/// Request URLs are the unresolved templates and request headers are left
/// out, so Gowa itself prints no variable or secret values; response data
/// and script output (logs, test messages) are reported as received.
enum CLIReport {
    static let bodyLimit = 1 << 20
    static let actualLimit = 4096

    /// An invalid URL error quotes the resolved URL, which can hold secret values.
    static func describe(_ error: Error) -> String {
        if case HTTPError.invalidURL = error {
            return "Invalid URL after filling in variables — check the values used in it"
        }
        return error.localizedDescription
    }

    static func runnable(_ node: OCNode) -> Bool {
        !node.isFolder && (node.kind == "http" || node.kind == "graphql")
    }

    static func select(_ nodes: [OCNode], id: String?, filter: String?) -> [OCNode] {
        nodes.filter { node in
            guard runnable(node) else { return false }
            if let id, node.id != id, !node.id.hasPrefix(id + ".") { return false }
            if let filter, !node.name.contains(filter) { return false }
            return true
        }
    }

    /// Slash-joined folder path for each node, keyed by node ID.
    static func locations(_ nodes: [OCNode]) -> [String: String] {
        var result: [String: String] = [:]
        for node in nodes {
            let parent = node.path.count > 1 ? result[node.path.dropLast().map(String.init).joined(separator: ".")] : nil
            result[node.id] = parent.map { "\($0)/\(node.name)" } ?? node.name
        }
        return result
    }

    @MainActor
    static func tree(_ document: OpenCollectionDocument) -> [String: Any] {
        let nodes = document.enumerate()
        let locations = locations(nodes)
        return [
            "collection": document.name,
            "environments": document.environments.map(\.name),
            "items": nodes.map { node -> [String: Any] in
                var item: [String: Any] = [
                    "id": node.id,
                    "name": node.name,
                    "path": locations[node.id] ?? node.name,
                    "kind": node.isFolder ? "folder" : node.kind,
                ]
                if !node.isFolder {
                    item["runnable"] = runnable(node)
                    if let method = node.method { item["method"] = method.uppercased() }
                    if let url = node.url { item["url"] = url }
                }
                return item
            },
        ]
    }

    @MainActor
    static func treeText(_ document: OpenCollectionDocument) -> String {
        let nodes = document.enumerate()
        let environments = document.environments.map(\.name)
        var text = document.name
        if !environments.isEmpty { text += " — environments: " + environments.joined(separator: ", ") }
        text += "\n\n"
        let idWidth = nodes.map(\.id.count).max() ?? 0
        for node in nodes {
            let indent = String(repeating: "  ", count: node.path.count - 1)
            let id = node.id.padding(toLength: idWidth + 2, withPad: " ", startingAt: 0)
            if node.isFolder {
                text += "\(id)\(indent)\(node.name)/\n"
            } else {
                let label = node.kind == "http" ? (node.method ?? "GET").uppercased() : node.kind
                text += "\(id)\(indent)\(label.padding(toLength: 7, withPad: " ", startingAt: 0)) \(node.name)"
                if let url = node.url, !url.isEmpty { text += "  \(url)" }
                text += "\n"
            }
        }
        return text
    }

    static func result(id: String, location: String, method: String, url: String, outcome: ExecutionOutcome) -> [String: Any] {
        let response = outcome.response
        var report: [String: Any] = [
            "id": id,
            "path": location,
            "method": method,
            "url": url,
            "passed": outcome.passed,
            "status": response.status,
            "statusText": response.statusPhrase,
            "timeMs": Int(response.elapsed.milliseconds.rounded()),
            "response": [
                "headers": response.headers.map { ["name": $0.name, "value": $0.value] },
                "body": body(response.body),
            ] as [String: Any],
            "captures": outcome.captures.map { ["name": $0.name, "found": $0.value != nil, "scope": $0.scope] as [String: Any] },
            "assertions": outcome.assertions.map { assertion -> [String: Any] in
                var entry: [String: Any] = ["expression": assertion.expression, "operator": assertion.op, "passed": assertion.pass]
                if let expected = assertion.expected { entry["expected"] = expected }
                if let actual = assertion.actual {
                    entry["actual"] = actual.count > actualLimit ? String(actual.prefix(actualLimit)) + "…" : actual
                }
                return entry
            },
            "tests": outcome.tests.map { test -> [String: Any] in
                var entry: [String: Any] = ["name": test.name, "passed": test.passed]
                if let error = test.error { entry["error"] = error }
                return entry
            },
            "logs": outcome.logs.map { ["level": $0.level, "message": $0.message] },
        ]
        if let scriptError = outcome.scriptError { report["scriptError"] = scriptError }
        return report
    }

    static func failure(id: String, location: String, method: String, url: String, error: String, elapsed: Duration) -> [String: Any] {
        [
            "id": id,
            "path": location,
            "method": method,
            "url": url,
            "passed": false,
            "error": error,
            "timeMs": Int(elapsed.milliseconds.rounded()),
        ]
    }

    /// UTF-8 text when the (possibly cut) body decodes, base64 otherwise.
    static func body(_ data: Data, limit: Int = bodyLimit) -> [String: Any] {
        let truncated = data.count > limit
        var slice = truncated ? data.prefix(limit) : data
        var text = String(data: slice, encoding: .utf8)
        if text == nil, truncated {
            // A cut can split a multi-byte character; drop up to 3 trailing bytes.
            for _ in 0..<3 where text == nil && !slice.isEmpty {
                slice = slice.dropLast()
                text = String(data: slice, encoding: .utf8)
            }
        }
        var result: [String: Any] = ["bytes": data.count, "truncated": truncated]
        if let text {
            result["encoding"] = "utf8"
            result["text"] = text
        } else {
            result["encoding"] = "base64"
            result["base64"] = data.prefix(limit).base64EncodedString()
        }
        return result
    }

    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
