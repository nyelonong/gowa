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
}

enum ExecutionError: LocalizedError {
    case missingSecrets([String])

    var errorDescription: String? {
        switch self {
        case .missingSecrets(let names):
            let list = names.map { "\"\($0)\"" }.joined(separator: ", ")
            return "Secret \(list) has no stored value. Open Environments to set it — secret values live in the macOS Keychain, never in the collection file."
        }
    }
}

/// The one send pipeline shared by the editor, the folder runner, and the CLI:
/// inheritance, variables, interpolation, the HTTP call, captures, and checks.
@MainActor
struct RequestExecutor {
    let document: OpenCollectionDocument?
    let environment: String?

    func variables(at path: NodePath?, session: [String: String]) -> (values: [String: String], missingSecrets: [String]) {
        let resolution = document?.resolveVariables(in: environment) ?? (values: [:], missingSecrets: [])
        var values = document?.layeredVariables(at: path, environment: resolution.values) ?? resolution.values
        for (name, value) in session {
            values[name] = value
        }
        return (values, resolution.missingSecrets)
    }

    func prepare(_ snapshot: OCRequestSnapshot, at path: NodePath?, session: [String: String]) throws -> (snapshot: OCRequestSnapshot, effective: AppState.EffectiveRequest) {
        var snapshot = snapshot
        if let path, let document {
            document.applyInheritance(to: &snapshot, at: path)
        }
        let resolution = variables(at: path, session: session)
        let missing = AppState.missingSecrets(usedBy: snapshot, missing: resolution.missingSecrets, variables: resolution.values)
        if !missing.isEmpty {
            throw ExecutionError.missingSecrets(missing)
        }
        return (snapshot, AppState.effectiveRequest(from: snapshot, variables: resolution.values))
    }

    func execute(_ snapshot: OCRequestSnapshot, at path: NodePath?, session: [String: String]) async throws -> ExecutionOutcome {
        let prepared = try prepare(snapshot, at: path, session: session)
        let effective = prepared.effective
        let client = HTTPClient(
            followRedirects: effective.followRedirects,
            timeout: effective.timeout.map { TimeInterval($0) / 1000 } ?? 30
        )
        let response = try await client.send(
            method: HTTPMethod(rawValue: effective.method) ?? .GET,
            urlText: effective.url,
            body: effective.body,
            headers: effective.headers
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

        return ExecutionOutcome(effective: effective, response: response, captures: captures, assertions: assertions)
    }
}
