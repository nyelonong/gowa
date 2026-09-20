import Foundation

/// Headless collection runner: `gowa run <collection.yml> [--env NAME]`.
/// Shares the app's model, HTTP engine, capture, and check evaluators.
/// Exit codes: 0 = all passed, 1 = failures/errors, 2 = usage error.
enum CLIMode {
    nonisolated static func printUsage() {
        print("""
        gowa — HTTP client with OpenCollection collections

        Usage:
          gowa                       Launch the GUI app
          gowa run <collection.yml> [--env NAME]   Run all requests, top to bottom

        Run options:
          --env NAME        Environment whose variables to use (default: first)
          --filter TEXT     Run only requests whose name contains TEXT

        Exit codes: 0 all passed, 1 failures/errors, 2 usage error
        """)
    }

    nonisolated static func run(_ args: [String]) async {
        setbuf(stdout, nil) // unbuffered: CLI output must survive SIGTERM
        var path: String?
        var environment: String?
        var filter: String?

        var index = 0
        while index < args.count {
            switch args[index] {
            case "--env":
                guard index + 1 < args.count else {
                    fail("--env requires a value")
                    return
                }
                environment = args[index + 1]
                index += 1
            case "--filter":
                guard index + 1 < args.count else {
                    fail("--filter requires a value")
                    return
                }
                filter = args[index + 1]
                index += 1
            case "--help", "-h":
                printUsage()
                return
            case let token where !token.hasPrefix("-"):
                if path == nil { path = token }
            case let token:
                fail("unknown argument: \(token)")
                return
            }
            index += 1
        }

        guard let path else {
            fail("missing collection file — usage: gowa run <collection.yml> [--env NAME]")
            return
        }

        let code = await runCollection(at: path, environment: environment, filter: filter)
        exit(code)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("gowa: \(message)\n".utf8))
        exit(2)
    }

    @MainActor
    private static func runCollection(at path: String, environment: String?, filter: String?) async -> Int32 {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            FileHandle.standardError.write(Data("gowa: file not found: \(path)\n".utf8))
            return 2
        }

        let document: OpenCollectionDocument
        do {
            document = try OpenCollectionDocument.load(from: url)
        } catch {
            FileHandle.standardError.write(Data("gowa: \(error.localizedDescription)\n".utf8))
            return 2
        }

        let envName = environment ?? document.environments.first?.name
        print("Running \(document.name) (\(url.lastPathComponent))\(envName.map { " — env: \($0)" } ?? "")\n")

        var sessionVariables: [String: String] = [:]
        let requests = document.enumerate().filter { !$0.isFolder && $0.url != nil }
        var passed = 0
        var failed = 0

        for node in requests {
            if let filter, !node.name.contains(filter) { continue }
            guard let snapshot = document.requestSnapshot(at: node.path) else { continue }

            let resolution = document.resolveVariables(in: envName)
            var variables = resolution.values
            for (name, value) in sessionVariables { variables[name] = value }

            let effective = AppState.effectiveRequest(from: snapshot, variables: variables)
            let method = HTTPMethod(rawValue: effective.method) ?? .GET

            let clock = ContinuousClock()
            let start = clock.now
            var outcomes: [OpenCollectionDocument.AssertionOutcome] = []
            var failureDetail: String?

            do {
                let client = HTTPClient(followRedirects: effective.followRedirects)
                let result = try await client.send(
                    method: method,
                    urlText: effective.url,
                    body: effective.body,
                    headers: effective.headers
                )
                let elapsed = start.duration(to: clock.now)
                let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e18

                // Captures run before checks so chained tokens flow onward.
                var capturedNotes: [String] = []
                for capture in snapshot.captures where !capture.disabled {
                    if let value = OpenCollectionDocument.evaluateCapture(capture.expression, body: result.body) {
                        sessionVariables[capture.variableName] = value
                        capturedNotes.append("{{\(capture.variableName)}} ← captured")
                    } else {
                        capturedNotes.append("{{\(capture.variableName)}} ← NOT FOUND")
                    }
                }

                outcomes = snapshot.assertions
                    .filter { !$0.disabled }
                    .map { OpenCollectionDocument.evaluateAssertion($0, response: result) }
                let checksFailed = outcomes.contains { !$0.pass }

                let marker = checksFailed ? "✗" : "✔"
                print("\(marker) \(method) \(node.name) — HTTP \(result.status) (\(String(format: "%.0f", ms)) ms)")
                for note in capturedNotes {
                    print("    \(note)")
                }
                for outcome in outcomes {
                    let symbol = outcome.pass ? "✔" : "✗"
                    var line = "      \(symbol) \(outcome.expression) \(outcome.op)"
                    if let expected = outcome.expected { line += " [\(expected)]" }
                    if let actual = outcome.actual { line += " — got [\(actual)]" }
                    print(line)
                }
                if checksFailed {
                    failed += 1
                } else {
                    passed += 1
                }
                continue
            } catch {
                failureDetail = error.localizedDescription
            }

            let elapsed = start.duration(to: clock.now)
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e18
            print("✗ \(method) \(node.name) — \(failureDetail ?? "failed") (\(String(format: "%.0f", ms)) ms)")
            failed += 1
        }

        print("\n\(passed) passed, \(failed) failed of \(requests.count) requests")
        return failed == 0 ? 0 : 1
    }
}
