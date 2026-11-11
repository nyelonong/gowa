import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

/// Where a gRPC request goes. `grpcs://` and `https://` use TLS, `grpc://`
/// and `http://` don't; a bare `host:port` uses TLS only on port 443.
struct GrpcTarget: Equatable, Sendable {
    var host: String
    var port: Int
    var tls: Bool

    static func parse(_ text: String) throws -> GrpcTarget {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var tls: Bool?
        for (prefix, secure) in [("grpcs://", true), ("https://", true), ("grpc://", false), ("http://", false)] where rest.lowercased().hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
            tls = secure
        }
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        guard !rest.isEmpty else { throw GrpcError.badTarget(text) }
        var host = rest
        var port: Int?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) }
        } else if let colon = rest.lastIndex(of: ":") {
            host = String(rest[..<colon])
            port = Int(rest[rest.index(after: colon)...])
            if port == nil { throw GrpcError.badTarget(text) }
        }
        let secure = tls ?? (port == 443 || port == nil)
        return GrpcTarget(host: host, port: port ?? (secure ? 443 : 80), tls: secure)
    }
}

enum GrpcError: LocalizedError, Equatable {
    case badTarget(String)
    case noMethod(String)
    case reflection(String)
    case descriptors(String)
    case badMessage(String)

    var errorDescription: String? {
        switch self {
        case .badTarget(let text): "Can't read the gRPC address \"\(text)\". Use host:port, grpc://host:port, or grpcs://host:port."
        case .noMethod(let name): "The server doesn't describe the method \(name). Load methods again or check the name (package.Service/Method)."
        case .reflection(let detail): "Server reflection failed: \(detail)"
        case .descriptors(let detail): detail
        case .badMessage(let detail): "The message isn't valid: \(detail)"
        }
    }
}

struct GrpcResult: Sendable {
    var status: String
    var statusMessage: String
    var ok: Bool
    var responses: [String]
    var headers: [(name: String, value: String)]
    var trailers: [(name: String, value: String)]
    var elapsed: Duration
}

private struct RawSerializer: MessageSerializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: [UInt8]) throws -> Bytes { Bytes(message) }
}

private struct RawDeserializer: MessageDeserializer {
    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> [UInt8] {
        serializedMessageBytes.withUnsafeBytes { Array($0) }
    }
}

/// Dynamic gRPC calls: the schema comes from server reflection or a
/// descriptor set, and messages are JSON converted with ProtoCodec.
enum GrpcClient {
    struct Security: Sendable {
        var verifyTLS = true
        var clientCertificate: (certificateDER: [UInt8], privateKeyDER: [UInt8])?
    }

    static func transport(_ target: GrpcTarget, security: Security) throws -> HTTP2ClientTransport.Posix {
        let transportSecurity: HTTP2ClientTransport.Posix.TransportSecurity
        if target.tls {
            transportSecurity = .tls { config in
                if !security.verifyTLS { config.serverCertificateVerification = .noVerification }
                if let certificate = security.clientCertificate {
                    config.certificateChain = [.bytes(certificate.certificateDER, format: .der)]
                    config.privateKey = .bytes(certificate.privateKeyDER, format: .der)
                }
            }
        } else {
            transportSecurity = .plaintext
        }
        return try HTTP2ClientTransport.Posix(target: .dns(host: target.host, port: target.port), transportSecurity: transportSecurity)
    }

    static func metadata(_ pairs: [(name: String, value: String)]) -> Metadata {
        var metadata = Metadata()
        for (name, value) in pairs where !name.isEmpty {
            let key = name.lowercased()
            if key.hasSuffix("-bin"), let data = Data(base64Encoded: value) {
                metadata.addBinary(Array(data), forKey: key)
            } else {
                metadata.addString(value, forKey: key)
            }
        }
        return metadata
    }

    static func pairs(_ metadata: Metadata) -> [(name: String, value: String)] {
        metadata.map { ($0.key, $0.value.encoded()) }
    }

    /// Calls any method kind over one stream: every message in `messages` is
    /// sent in order, then the stream closes and all responses are collected.
    static func invoke(
        target: GrpcTarget,
        security: Security,
        method: ProtoSchema.Method,
        schema: ProtoSchema,
        encoded: [[UInt8]],
        metadata: [(name: String, value: String)],
        timeout: Duration?,
        onResponse: @escaping @Sendable (String) -> Void
    ) async throws -> GrpcResult {
        let codec = ProtoCodec(schema: schema)
        let descriptor = MethodDescriptor(fullyQualifiedService: method.service, method: method.name)
        var options = CallOptions.defaults
        options.timeout = timeout
        let request = StreamingClientRequest(of: [UInt8].self, metadata: self.metadata(metadata)) { writer in
            for message in encoded { try await writer.write(message) }
        }
        let clock = ContinuousClock()
        let start = clock.now
        let collector = ResponseCollector()
        do {
            try await withGRPCClient(transport: try transport(target, security: security)) { client in
                try await client.bidirectionalStreaming(
                    request: request,
                    descriptor: descriptor,
                    serializer: RawSerializer(),
                    deserializer: RawDeserializer(),
                    options: options
                ) { response in
                    collector.headers = pairs(response.metadata)
                    for try await part in response.bodyParts {
                        switch part {
                        case .message(let bytes):
                            let json = try codec.decode(bytes, as: method.output)
                            let text = JSONPath.render([json])
                            collector.append(text)
                            onResponse(text)
                        case .trailingMetadata(let trailers):
                            collector.trailers = pairs(trailers)
                        }
                    }
                }
            }
            return GrpcResult(status: "OK", statusMessage: "", ok: true, responses: collector.responses,
                              headers: collector.headers, trailers: collector.trailers, elapsed: start.duration(to: clock.now))
        } catch let error as RPCError {
            return GrpcResult(status: statusName(error.code.description), statusMessage: error.message, ok: false, responses: collector.responses,
                              headers: collector.headers, trailers: pairs(error.metadata), elapsed: start.duration(to: clock.now))
        }
    }

    private final class ResponseCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _responses: [String] = []
        private var _headers: [(name: String, value: String)] = []
        private var _trailers: [(name: String, value: String)] = []

        var responses: [String] { lock.withLock { _responses } }
        var headers: [(name: String, value: String)] {
            get { lock.withLock { _headers } }
            set { lock.withLock { _headers = newValue } }
        }
        var trailers: [(name: String, value: String)] {
            get { lock.withLock { _trailers } }
            set { lock.withLock { _trailers = newValue } }
        }

        func append(_ text: String) { lock.withLock { _responses.append(text) } }
    }

    /// `notFound` → `NOT_FOUND`, the names gRPC documentation uses.
    static func statusName(_ camel: String) -> String {
        camel.reduce(into: "") { result, character in
            if character.isUppercase { result += "_" }
            result += character.uppercased()
        }
    }

    /// JSON text to request messages; client- and bidi-streaming methods take a JSON array of messages.
    static func encode(_ json: String, method: ProtoSchema.Method, schema: ProtoSchema) throws -> [[UInt8]] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        } catch {
            throw GrpcError.badMessage("it must be JSON")
        }
        let messages: [Any] = method.clientStreaming ? ((parsed as? [Any]) ?? [parsed]) : [parsed]
        let codec = ProtoCodec(schema: schema)
        do {
            return try messages.map { try codec.encode(json: $0, as: method.input) }
        } catch {
            throw GrpcError.badMessage(error.localizedDescription)
        }
    }

    // MARK: Server reflection

    /// Asks the server for its services and the file descriptors that define them.
    static func reflect(target: GrpcTarget, security: Security, metadata: [(name: String, value: String)]) async throws -> ProtoSchema {
        do {
            return try await reflect(target: target, security: security, metadata: metadata, service: "grpc.reflection.v1.ServerReflection")
        } catch let error as RPCError where error.code == .unimplemented {
            return try await reflect(target: target, security: security, metadata: metadata, service: "grpc.reflection.v1alpha.ServerReflection")
        } catch let error as RPCError {
            throw GrpcError.reflection("\(error.code): \(error.message)")
        }
    }

    private static func reflect(target: GrpcTarget, security: Security, metadata: [(name: String, value: String)], service: String) async throws -> ProtoSchema {
        let (requests, continuation) = AsyncStream<[UInt8]>.makeStream()
        let state = ReflectionState()
        continuation.yield(ReflectionWire.listServices())
        state.pending = 1

        let request = StreamingClientRequest(of: [UInt8].self, metadata: self.metadata(metadata)) { writer in
            for await message in requests { try await writer.write(message) }
        }
        try await withGRPCClient(transport: try transport(target, security: security)) { client in
            try await client.bidirectionalStreaming(
                request: request,
                descriptor: MethodDescriptor(fullyQualifiedService: service, method: "ServerReflectionInfo"),
                serializer: RawSerializer(),
                deserializer: RawDeserializer(),
                options: .defaults
            ) { response in
                for try await part in response.bodyParts {
                    guard case .message(let bytes) = part else { continue }
                    let reply = try ReflectionWire.parse(bytes)
                    var next: [[UInt8]] = []
                    state.lock.withLock {
                        state.pending -= 1
                        switch reply {
                        case .services(let names):
                            for name in names where name != "grpc.reflection.v1.ServerReflection" && name != "grpc.reflection.v1alpha.ServerReflection" {
                                next.append(ReflectionWire.fileContainingSymbol(name))
                            }
                        case .files(let files):
                            for file in files where state.files[file.name] == nil {
                                state.files[file.name] = file
                                for dependency in file.dependency where state.files[dependency] == nil && !state.requested.contains(dependency) {
                                    state.requested.insert(dependency)
                                    next.append(ReflectionWire.fileByFilename(dependency))
                                }
                            }
                        case .error(let message):
                            state.errors.append(message)
                        }
                        state.pending += next.count
                    }
                    for message in next { continuation.yield(message) }
                    if state.lock.withLock({ state.pending }) == 0 {
                        continuation.finish()
                    }
                }
            }
        }
        let files = state.lock.withLock { Array(state.files.values) }
        if files.isEmpty {
            throw GrpcError.reflection(state.errors.first ?? "the server listed no services")
        }
        return ProtoSchema(files: files)
    }

    private final class ReflectionState: @unchecked Sendable {
        let lock = NSLock()
        var pending = 0
        var files: [String: Google_Protobuf_FileDescriptorProto] = [:]
        var requested: Set<String> = []
        var errors: [String] = []
    }

    // MARK: Descriptor files

    /// Reads a descriptor set (`.pb`, `.protoset`, `.binpb`, `.desc`), or
    /// compiles a `.proto` with `protoc` or `buf` when one is installed.
    static func loadDescriptors(at url: URL, importPaths: [URL]) throws -> ProtoSchema {
        let data: Data
        if url.pathExtension.lowercased() == "proto" {
            data = try compileProto(url, importPaths: importPaths)
        } else {
            guard let contents = try? Data(contentsOf: url) else { throw GrpcError.descriptors("Can't read \(url.path)") }
            data = contents
        }
        do {
            let set = try Google_Protobuf_FileDescriptorSet(serializedBytes: data)
            guard !set.file.isEmpty else { throw GrpcError.descriptors("\(url.lastPathComponent) has no file descriptors") }
            return ProtoSchema(files: set.file)
        } catch let error as GrpcError {
            throw error
        } catch {
            throw GrpcError.descriptors("\(url.lastPathComponent) isn't a protobuf descriptor set: \(error.localizedDescription)")
        }
    }

    private static func compileProto(_ url: URL, importPaths: [URL]) throws -> Data {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("gowa-\(UUID().uuidString).binpb")
        defer { try? FileManager.default.removeItem(at: output) }
        let includes = ([url.deletingLastPathComponent()] + importPaths).map { "-I" + $0.path }
        let attempts: [(String, [String])] = [
            ("protoc", ["--include_imports", "--descriptor_set_out=" + output.path] + includes + [url.path]),
            ("buf", ["build", url.path, "-o", output.path]),
        ]
        var tried: [String] = []
        for (tool, arguments) in attempts {
            guard let executable = which(tool) else { continue }
            tried.append(tool)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = url.deletingLastPathComponent()
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let message = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let data = try? Data(contentsOf: output) { return data }
            throw GrpcError.descriptors("\(tool) couldn't compile \(url.lastPathComponent): \(String(decoding: message, as: UTF8.self).prefix(500))")
        }
        _ = tried
        throw GrpcError.descriptors("Reading a .proto file needs protoc or buf on your PATH. Install one, or point Gowa at a descriptor set (protoc --include_imports --descriptor_set_out=api.binpb), or use server reflection.")
    }

    private static func which(_ tool: String) -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/go/bin", NSHomeDirectory() + "/Projects/go/bin"]
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Hand-encoded `grpc.reflection.v1` messages (identical on the wire to v1alpha).
enum ReflectionWire {
    enum Reply {
        case services([String])
        case files([Google_Protobuf_FileDescriptorProto])
        case error(String)
    }

    private static func request(field: Int32, value: String) -> [UInt8] {
        var out: [UInt8] = []
        ProtoWire.tag(field, .lengthDelimited, into: &out)
        ProtoWire.varint(UInt64(value.utf8.count), into: &out)
        out += Array(value.utf8)
        return out
    }

    static func listServices() -> [UInt8] { request(field: 7, value: "") }
    static func fileContainingSymbol(_ symbol: String) -> [UInt8] { request(field: 4, value: symbol) }
    static func fileByFilename(_ name: String) -> [UInt8] { request(field: 3, value: name) }

    static func parse(_ bytes: [UInt8]) throws -> Reply {
        var reader = ProtoWire.Reader(bytes: bytes)
        while let (number, type) = try reader.nextTag() {
            switch number {
            case 4:
                var inner = ProtoWire.Reader(bytes: try reader.lengthDelimited())
                var files: [Google_Protobuf_FileDescriptorProto] = []
                while let (field, fieldType) = try inner.nextTag() {
                    if field == 1 {
                        files.append(try Google_Protobuf_FileDescriptorProto(serializedBytes: try inner.lengthDelimited()))
                    } else {
                        try inner.skip(fieldType)
                    }
                }
                return .files(files)
            case 6:
                var inner = ProtoWire.Reader(bytes: try reader.lengthDelimited())
                var names: [String] = []
                while let (field, fieldType) = try inner.nextTag() {
                    guard field == 1 else { try inner.skip(fieldType); continue }
                    var service = ProtoWire.Reader(bytes: try inner.lengthDelimited())
                    while let (serviceField, serviceType) = try service.nextTag() {
                        if serviceField == 1 {
                            names.append(String(decoding: try service.lengthDelimited(), as: UTF8.self))
                        } else {
                            try service.skip(serviceType)
                        }
                    }
                }
                return .services(names)
            case 7:
                var inner = ProtoWire.Reader(bytes: try reader.lengthDelimited())
                var message = "error"
                while let (field, fieldType) = try inner.nextTag() {
                    if field == 2 { message = String(decoding: try inner.lengthDelimited(), as: UTF8.self) } else { try inner.skip(fieldType) }
                }
                return .error(message)
            default:
                try reader.skip(type)
            }
        }
        return .error("empty reflection response")
    }
}
