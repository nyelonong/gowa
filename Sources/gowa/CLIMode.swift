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
                }
                environment = args[index + 1]
                index += 1
            case "--filter":
                guard index + 1 < args.count else {
                    fail("--filter requires a value")
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
            }
            index += 1
        }

        guard let path else {
            fail("missing collection file — usage: gowa run <collection.yml> [--env NAME]")
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

        let executor = RequestExecutor(document: document, environment: envName, cookies: CookieJar(fileURL: nil))
        for node in requests {
            if let filter, !node.name.contains(filter) { continue }
            guard let snapshot = document.requestSnapshot(at: node.path) else { continue }
            let method = snapshot.method.uppercased()
            let clock = ContinuousClock()
            let start = clock.now

            do {
                let outcome = try await executor.execute(snapshot, at: node.path, session: sessionVariables)
                var capturedNotes: [String] = []
                for capture in outcome.captures {
                    if let value = capture.value {
                        sessionVariables[capture.name] = value
                        capturedNotes.append("{{\(capture.name)}} ← captured")
                    } else {
                        capturedNotes.append("{{\(capture.name)}} ← NOT FOUND")
                    }
                }
                for (name, value) in outcome.environmentVariables { sessionVariables[name] = value }
                for (name, value) in outcome.runtimeVariables { sessionVariables[name] = value }
                let checksFailed = !outcome.passed
                let marker = checksFailed ? "✗" : "✔"
                print("\(marker) \(method) \(node.name) — HTTP \(outcome.response.status) (\(outcome.response.elapsed.millisecondsText))")
                for note in capturedNotes {
                    print("    \(note)")
                }
                for assertion in outcome.assertions {
                    let symbol = assertion.pass ? "✔" : "✗"
                    var line = "      \(symbol) \(assertion.expression) \(assertion.op)"
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
                if checksFailed {
                    failed += 1
                } else {
                    passed += 1
                }
            } catch {
                print("✗ \(method) \(node.name) — \(error.localizedDescription) (\(start.duration(to: clock.now).millisecondsText))")
                failed += 1
            }
        }

        print("\n\(passed) passed, \(failed) failed of \(requests.count) requests")
        return failed == 0 ? 0 : 1
    }
}
