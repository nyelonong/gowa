import Foundation

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    var millisecondsText: String {
        String(format: "%.0f ms", milliseconds)
    }
}

struct CaptureOutcome: Sendable, Equatable {
    var name: String
    var value: String?
    var scope: String

    var storesInEnvironment: Bool { scope == "environment" }
}

struct ExecutionOutcome: Sendable {
    var effective: AppState.EffectiveRequest
    var response: HTTPResult
    var captures: [CaptureOutcome]
    var assertions: [OpenCollectionDocument.AssertionOutcome]
    var tests: [ScriptTestResult] = []
    var logs: [ScriptLog] = []
    /// Values scripts set with `bru.setVar` (session) and `bru.setEnvVar` (environment).
    var runtimeVariables: [String: String] = [:]
    var environmentVariables: [String: String] = [:]
    var scriptError: String?

    var passed: Bool {
        assertions.allSatisfy(\.pass) && tests.allSatisfy(\.passed) && scriptError == nil
    }
}

enum ExecutionError: LocalizedError {
    case missingSecrets([String])
    case script(String, logs: [ScriptLog])

    var errorDescription: String? {
        switch self {
        case .missingSecrets(let names):
            let list = names.map { "\"\($0)\"" }.joined(separator: ", ")
            return "Secret \(list) has no stored value. Open Environments to set it — secret values live in the macOS Keychain, never in the collection file."
        case .script(let message, _):
            return "The request was not sent: \(message)"
        }
    }
}

/// The one send pipeline shared by the editor, the folder runner, and the CLI:
/// inheritance, variables, interpolation, the HTTP call, captures, and checks.
@MainActor
struct RequestExecutor {
    let document: OpenCollectionDocument?
    let environment: String?
    var cookies: CookieJar?
    var oauth: OAuth2Client?

    func variables(at path: NodePath?, session: [String: String]) -> (values: [String: String], missingSecrets: [String]) {
        let resolution = document?.resolveVariables(in: environment) ?? (values: [:], missingSecrets: [])
        var values = document?.layeredVariables(at: path, environment: resolution.values) ?? resolution.values
        for (name, value) in session {
            values[name] = value
        }
        return (values, resolution.missingSecrets)
    }

    func prepare(_ snapshot: OCRequestSnapshot, at path: NodePath?, session: [String: String], headersInherited: Bool = false) throws -> (snapshot: OCRequestSnapshot, effective: AppState.EffectiveRequest, variables: [String: String]) {
        var snapshot = snapshot
        if let path, let document {
            document.applyInheritance(to: &snapshot, at: path, headers: !headersInherited)
        }
        let resolution = variables(at: path, session: session)
        let missing = AppState.missingSecrets(usedBy: snapshot, missing: resolution.missingSecrets, variables: resolution.values)
        if !missing.isEmpty {
            throw ExecutionError.missingSecrets(missing)
        }
        let base = document?.url?.deletingLastPathComponent()
        return (snapshot, AppState.effectiveRequest(from: snapshot, variables: resolution.values, baseDirectory: base), resolution.values)
    }

    /// Adds the OAuth 2.0 token as the configured header or query parameter.
    func applyOAuth2(_ config: OCOAuth2, to effective: inout AppState.EffectiveRequest) async throws {
        let client = oauth ?? OAuth2Client(collectionID: document?.documentID ?? "cli")
        let token = try await client.token(for: config, interactive: false)
        let value = token.value(source: config.tokenSource)
        if !config.tokenQuery.isEmpty {
            effective.url = AppState.appendQuery(effective.url, [(name: config.tokenQuery, value: value)])
        } else {
            let header = config.tokenHeader.isEmpty ? "Authorization" : config.tokenHeader
            let bearer = header.caseInsensitiveCompare("Authorization") == .orderedSame ? "Bearer \(value)" : value
            effective.headers.removeAll { $0.name.caseInsensitiveCompare(header) == .orderedSame }
            effective.headers.append((name: header, value: bearer))
        }
    }

    func scripts(_ snapshot: OCRequestSnapshot, at path: NodePath?, types: [String]) -> [OCScript] {
        types.flatMap { type in
            (document?.inheritedScripts(at: path, type: type) ?? []) + snapshot.scripts.filter { $0.type == type }
        }
    }

    func execute(_ snapshot: OCRequestSnapshot, at path: NodePath?, session: [String: String], onEvent: (@Sendable (SSEEvent) -> Void)? = nil) async throws -> ExecutionOutcome {
        var session = session
        var snapshot = snapshot
        var scriptLogs: [ScriptLog] = []
        var runtimeSets: [String: String] = [:]
        var environmentSets: [String: String] = [:]

        let before = scripts(snapshot, at: path, types: ["before-request"])
        if !before.isEmpty {
            let initial = try prepare(snapshot, at: path, session: session)
            let request = ScriptRequest(
                name: snapshot.name,
                method: initial.snapshot.method,
                url: snapshot.url,
                headers: initial.snapshot.headers,
                body: snapshot.bodyData
            )
            let outcome = ScriptRunner.run(before, request: request, response: nil, variables: initial.variables)
            scriptLogs += outcome.logs
            if let error = outcome.error {
                throw ExecutionError.script(error, logs: scriptLogs)
            }
            // The script saw the inherited headers; keep them (or its edits of them).
            snapshot.headers = initial.snapshot.headers
            if let changed = outcome.request, changed != request {
                snapshot.method = changed.method
                snapshot.url = changed.url
                snapshot.headers = changed.headers
                snapshot.bodyData = changed.body
            }
            runtimeSets = outcome.runtimeVariables
            environmentSets = outcome.environmentVariables
            session.merge(environmentSets) { _, new in new }
            session.merge(runtimeSets) { _, new in new }
        }

        // Scripts saw (and may have removed) the inherited headers already.
        let prepared = try prepare(snapshot, at: path, session: session, headersInherited: !before.isEmpty)
        var effective = prepared.effective
        if case .oauth2(let config) = prepared.snapshot.authKind {
            try await applyOAuth2(config.interpolated(prepared.variables), to: &effective)
        }
        let network = try document.map {
            try NetworkOptions.resolve(
                $0.networkSettings,
                variables: prepared.variables,
                baseDirectory: $0.url?.deletingLastPathComponent(),
                cookies: cookies
            )
        } ?? .none
        let client = HTTPClient(
            followRedirects: effective.followRedirects,
            timeout: effective.timeout.map { TimeInterval($0) / 1000 } ?? 30,
            network: network
        )
        let encoded = try effective.payload.encoded()
        var headers = effective.headers
        if let contentType = encoded.contentType, effective.header("Content-Type") == nil {
            headers.append((name: "Content-Type", value: contentType))
        }
        let response = try await client.send(
            method: effective.method,
            urlText: effective.url,
            body: encoded.data,
            headers: headers,
            onEvent: onEvent
        )
        try Task.checkCancellation()

        let captures = prepared.snapshot.captures
            .filter { !$0.disabled }
            .map { capture in
                CaptureOutcome(
                    name: capture.variableName,
                    value: OpenCollectionDocument.evaluateCapture(capture.expression, body: response.body),
                    scope: capture.scope
                )
            }
        let assertions = prepared.snapshot.assertions
            .filter { !$0.disabled }
            .map { OpenCollectionDocument.evaluateAssertion($0, response: response) }

        var outcome = ExecutionOutcome(
            effective: effective,
            response: response,
            captures: captures,
            assertions: assertions,
            logs: scriptLogs,
            runtimeVariables: runtimeSets,
            environmentVariables: environmentSets
        )
        let after = scripts(prepared.snapshot, at: path, types: ["after-response", "tests"])
        if !after.isEmpty {
            var variables = prepared.variables
            for capture in captures { if let value = capture.value { variables[capture.name] = value } }
            let result = ScriptRunner.run(after, request: nil, response: response, variables: variables)
            outcome.tests = result.tests
            outcome.logs += result.logs
            outcome.runtimeVariables.merge(result.runtimeVariables) { _, new in new }
            outcome.environmentVariables.merge(result.environmentVariables) { _, new in new }
            outcome.scriptError = result.error
        }
        return outcome
    }
}
