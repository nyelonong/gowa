import Foundation
import UniformTypeIdentifiers

struct MultipartPart: Sendable, Equatable {
    var name: String
    var text: String?
    var file: URL?
    var contentType: String
}

/// A resolved request body, ready to encode.
enum EffectiveBody: Sendable, Equatable {
    case none
    case text(String, contentType: String)
    case form([KVPair])
    case multipart([MultipartPart])
    case file(URL, contentType: String)

    struct KVPair: Sendable, Equatable {
        var name: String
        var value: String
    }

    /// Readable form for history and diffs; files show their paths.
    var summary: String {
        switch self {
        case .none: ""
        case .text(let text, _): text
        case .form(let pairs): Self.urlEncoded(pairs)
        case .multipart(let parts):
            parts.map { "\($0.name)=\($0.file.map { "@" + $0.path } ?? $0.text ?? "")" }.joined(separator: "\n")
        case .file(let url, _): "@" + url.path
        }
    }

    static func urlEncoded(_ pairs: [KVPair]) -> String {
        pairs.map {
            ($0.name.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.name) + "=" +
                ($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)
        }.joined(separator: "&")
    }

    /// Encoded bytes and their default Content-Type. Reads files from disk.
    func encoded(boundary: String = "gowa-" + UUID().uuidString) throws -> (data: Data?, contentType: String?) {
        switch self {
        case .none:
            return (nil, nil)
        case .text(let text, let contentType):
            return (Data(text.utf8), contentType)
        case .form(let pairs):
            return (Data(Self.urlEncoded(pairs).utf8), "application/x-www-form-urlencoded")
        case .multipart(let parts):
            var data = Data()
            for part in parts {
                data.append(Data("--\(boundary)\r\n".utf8))
                if let file = part.file {
                    let filename = file.lastPathComponent.replacingOccurrences(of: "\"", with: "")
                    data.append(Data("Content-Disposition: form-data; name=\"\(Self.quoted(part.name))\"; filename=\"\(filename)\"\r\n".utf8))
                    data.append(Data("Content-Type: \(part.contentType.isEmpty ? Self.mimeType(for: file) : part.contentType)\r\n\r\n".utf8))
                    data.append(try Self.read(file))
                } else {
                    data.append(Data("Content-Disposition: form-data; name=\"\(Self.quoted(part.name))\"\r\n".utf8))
                    if !part.contentType.isEmpty {
                        data.append(Data("Content-Type: \(part.contentType)\r\n".utf8))
                    }
                    data.append(Data("\r\n".utf8))
                    data.append(Data((part.text ?? "").utf8))
                }
                data.append(Data("\r\n".utf8))
            }
            data.append(Data("--\(boundary)--\r\n".utf8))
            return (data, "multipart/form-data; boundary=\(boundary)")
        case .file(let url, let contentType):
            return (try Self.read(url), contentType.isEmpty ? Self.mimeType(for: url) : contentType)
        }
    }

    private static func quoted(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r\n", with: " ")
    }

    private static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw RequestBodyError.unreadableFile(url.path)
        }
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Resolves a stored path: absolute, `~`, or relative to the collection folder.
    static func resolvePath(_ path: String, base: URL?) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || base == nil {
            return URL(fileURLWithPath: expanded)
        }
        return base!.appendingPathComponent(expanded).standardizedFileURL
    }
}

enum RequestBodyError: LocalizedError, Equatable {
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let path): "Can't read the file \(path)"
        }
    }
}
