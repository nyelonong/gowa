import Foundation
import Observation

/// Spec `grpc` item: address, method, message, metadata, and auth.
struct OCGrpcSnapshot: Equatable, Sendable {
    var name: String
    var url: String
    var method = ""
    var methodType = "unary"
    var protoFilePath = ""
    var metadata: [OCHeader] = []
    var message = "{}"
    var authKind: OAuthKind = .inherit
    var docs: String?

    /// The parts that resolve like an HTTP request: variables, inherited auth and headers.
    var asRequest: OCRequestSnapshot {
        OCRequestSnapshot(
            name: name, method: "POST", url: url, params: [], headers: metadata,
            bodyType: "text", bodyData: message, authKind: authKind,
            settings: OCSettings(followRedirects: nil, timeout: nil), docs: nil
        )
    }
}

extension OpenCollectionDocument {
    func grpcSnapshot(at path: NodePath) -> OCGrpcSnapshot? {
        guard let item = item(at: path), let details = item["grpc"] as? [String: Any] else { return nil }
        let info = item["info"] as? [String: Any] ?? [:]
        let message: String
        if let text = details["message"] as? String {
            message = text
        } else if let variants = details["message"] as? [[String: Any]], !variants.isEmpty {
            let chosen = variants.first { $0["selected"] as? Bool == true } ?? variants[0]
            message = chosen["message"] as? String ?? (chosen["message"] as? [String: Any])?["message"] as? String ?? "{}"
        } else {
            message = "{}"
        }
        return OCGrpcSnapshot(
            name: info["name"] as? String ?? "Untitled",
            url: details["url"] as? String ?? "",
            method: details["method"] as? String ?? "",
            methodType: details["methodType"] as? String ?? "unary",
            protoFilePath: details["protoFilePath"] as? String ?? "",
            metadata: (details["metadata"] as? [[String: Any]] ?? []).map {
                OCHeader(name: $0["name"] as? String ?? "", value: $0["value"] as? String ?? "", disabled: $0["disabled"] as? Bool ?? false)
            },
            message: message,
            authKind: (details["auth"] as? [String: Any]).map(readAuthDict) ?? .inherit,
            docs: Self.readDocs(item["docs"])
        )
    }

    func updateGrpc(at path: NodePath, _ snapshot: OCGrpcSnapshot) {
        guard var item = item(at: path) else { return }
        var info = item["info"] as? [String: Any] ?? [:]
        info["name"] = snapshot.name
        info["type"] = "grpc"
        item["info"] = info
        item["grpc"] = grpcDetails(snapshot, existing: item["grpc"] as? [String: Any] ?? [:])
        if let docs = snapshot.docs, !docs.isEmpty { item["docs"] = docs } else { item.removeValue(forKey: "docs") }
        write(item, at: path)
    }

    func addGrpc(under parent: NodePath?, _ snapshot: OCGrpcSnapshot) -> NodePath {
        append(["info": ["name": snapshot.name, "type": "grpc"], "grpc": grpcDetails(snapshot, existing: [:])], under: parent)
    }

    private func grpcDetails(_ snapshot: OCGrpcSnapshot, existing: [String: Any]) -> [String: Any] {
        var details = existing
        details["url"] = snapshot.url
        details["method"] = snapshot.method
        details["methodType"] = snapshot.methodType
        if snapshot.protoFilePath.isEmpty { details.removeValue(forKey: "protoFilePath") } else { details["protoFilePath"] = snapshot.protoFilePath }
        if snapshot.metadata.isEmpty {
            details.removeValue(forKey: "metadata")
        } else {
            details["metadata"] = snapshot.metadata.map { ["name": $0.name, "value": $0.value, "disabled": $0.disabled] }
        }
        if var variants = details["message"] as? [[String: Any]], !variants.isEmpty {
            let index = variants.firstIndex { $0["selected"] as? Bool == true } ?? 0
            variants[index]["message"] = snapshot.message
            details["message"] = variants
        } else {
            details["message"] = snapshot.message
        }
        if let auth = authDict(snapshot.authKind, existing: details["auth"] as? [String: Any]) { details["auth"] = auth }
        return details
    }
}

/// State of the selected gRPC request: its schema, the call in flight, and the result.
@MainActor
@Observable
final class GrpcSession {
    var schema: ProtoSchema?
    var schemaSource = ""
    var loadingSchema = false
    var calling = false
    var result: GrpcResult?
    var liveResponses: [String] = []
    var error: String?
    var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        task = nil
        schema = nil
        schemaSource = ""
        loadingSchema = false
        calling = false
        result = nil
        liveResponses = []
        error = nil
    }
}
