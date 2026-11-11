import Foundation
import SwiftProtobuf

typealias FieldDescriptor = Google_Protobuf_FieldDescriptorProto

/// Messages, enums, and services from a set of file descriptors (server
/// reflection or a descriptor set), addressed by fully qualified name.
struct ProtoSchema: Sendable {
    struct Method: Sendable, Equatable, Hashable {
        var service: String
        var name: String
        var input: String
        var output: String
        var clientStreaming: Bool
        var serverStreaming: Bool

        var fullName: String { "\(service)/\(name)" }

        var kind: String {
            switch (clientStreaming, serverStreaming) {
            case (false, false): "unary"
            case (false, true): "server-streaming"
            case (true, false): "client-streaming"
            case (true, true): "bidi-streaming"
            }
        }
    }

    private(set) var messages: [String: Google_Protobuf_DescriptorProto] = [:]
    private(set) var enums: [String: Google_Protobuf_EnumDescriptorProto] = [:]
    private(set) var methods: [Method] = []
    private(set) var proto3Files: Set<String> = []
    private var messageSyntax: [String: Bool] = [:]

    init(files: [Google_Protobuf_FileDescriptorProto]) {
        for file in files {
            let package = file.package.isEmpty ? "" : file.package + "."
            let proto3 = file.syntax == "proto3"
            func add(_ message: Google_Protobuf_DescriptorProto, prefix: String) {
                let name = prefix + message.name
                messages[name] = message
                messageSyntax[name] = proto3
                for nested in message.nestedType { add(nested, prefix: name + ".") }
                for nested in message.enumType { enums[name + "." + nested.name] = nested }
            }
            for message in file.messageType { add(message, prefix: package) }
            for value in file.enumType { enums[package + value.name] = value }
            for service in file.service {
                for method in service.method {
                    methods.append(Method(
                        service: package + service.name,
                        name: method.name,
                        input: Self.strip(method.inputType),
                        output: Self.strip(method.outputType),
                        clientStreaming: method.clientStreaming,
                        serverStreaming: method.serverStreaming
                    ))
                }
            }
        }
        methods.sort { $0.fullName < $1.fullName }
    }

    static func strip(_ typeName: String) -> String {
        typeName.hasPrefix(".") ? String(typeName.dropFirst()) : typeName
    }

    func isProto3(_ message: String) -> Bool { messageSyntax[message] ?? true }

    func method(_ fullName: String) -> Method? {
        let normalized = fullName.hasPrefix("/") ? String(fullName.dropFirst()) : fullName
        return methods.first { $0.fullName == normalized }
    }

    func isMapEntry(_ field: FieldDescriptor) -> Bool {
        field.type == .message && messages[Self.strip(field.typeName)]?.options.mapEntry == true
    }
}

enum ProtoError: LocalizedError, Equatable {
    case unknownMessage(String)
    case unknownField(String, String)
    case badValue(String, String)
    case truncated

    var errorDescription: String? {
        switch self {
        case .unknownMessage(let name): "Unknown message type \(name)"
        case .unknownField(let message, let field): "\(message) has no field \"\(field)\""
        case .badValue(let field, let detail): "Field \(field): \(detail)"
        case .truncated: "The message bytes ended early"
        }
    }
}

/// Protobuf binary ⇄ JSON (proto3 JSON mapping) for messages known only at
/// runtime, including the common well-known types.
struct ProtoCodec {
    let schema: ProtoSchema

    // MARK: JSON → binary

    func encode(json: Any, as messageName: String) throws -> [UInt8] {
        if let special = try encodeWellKnown(json, messageName) { return special }
        guard let message = schema.messages[messageName] else { throw ProtoError.unknownMessage(messageName) }
        guard let object = json as? [String: Any] else {
            throw ProtoError.badValue(messageName, "expected a JSON object")
        }
        for key in object.keys where !message.field.contains(where: { $0.jsonName == key || $0.name == key }) {
            throw ProtoError.unknownField(messageName, key)
        }
        var out: [UInt8] = []
        for field in message.field.sorted(by: { $0.number < $1.number }) {
            guard let value = object[field.jsonName] ?? object[field.name], !(value is NSNull) else { continue }
            try encodeField(field, value, into: &out)
        }
        return out
    }

    private func encodeField(_ field: FieldDescriptor, _ value: Any, into out: inout [UInt8]) throws {
        if schema.isMapEntry(field) {
            guard let object = value as? [String: Any] else { throw ProtoError.badValue(field.name, "expected an object for a map") }
            let entry = schema.messages[ProtoSchema.strip(field.typeName)]!
            let keyField = entry.field.first { $0.number == 1 }!
            let valueField = entry.field.first { $0.number == 2 }!
            for (key, item) in object.sorted(by: { $0.key < $1.key }) {
                var body: [UInt8] = []
                try encodeSingle(keyField, mapKey(key, keyField), into: &body)
                try encodeSingle(valueField, item, into: &body)
                ProtoWire.tag(field.number, .lengthDelimited, into: &out)
                ProtoWire.varint(UInt64(body.count), into: &out)
                out += body
            }
            return
        }
        if field.label == .repeated {
            guard let array = value as? [Any] else { throw ProtoError.badValue(field.name, "expected an array") }
            if ProtoWire.isPackable(field.type) {
                var body: [UInt8] = []
                for item in array { try encodeScalar(field, item, into: &body) }
                ProtoWire.tag(field.number, .lengthDelimited, into: &out)
                ProtoWire.varint(UInt64(body.count), into: &out)
                out += body
            } else {
                for item in array { try encodeSingle(field, item, into: &out) }
            }
            return
        }
        try encodeSingle(field, value, into: &out)
    }

    private func mapKey(_ key: String, _ field: FieldDescriptor) throws -> Any {
        switch field.type {
        case .string: return key
        case .bool: return key == "true"
        default:
            guard let number = Int64(key) ?? UInt64(key).map(Int64.init(bitPattern:)) else {
                throw ProtoError.badValue(field.name, "map key \(key) isn't a number")
            }
            return NSNumber(value: number)
        }
    }

    private func encodeSingle(_ field: FieldDescriptor, _ value: Any, into out: inout [UInt8]) throws {
        switch field.type {
        case .message, .group:
            let body = try encode(json: value, as: ProtoSchema.strip(field.typeName))
            ProtoWire.tag(field.number, .lengthDelimited, into: &out)
            ProtoWire.varint(UInt64(body.count), into: &out)
            out += body
        case .string:
            guard let text = value as? String else { throw ProtoError.badValue(field.name, "expected a string") }
            ProtoWire.tag(field.number, .lengthDelimited, into: &out)
            ProtoWire.varint(UInt64(text.utf8.count), into: &out)
            out += Array(text.utf8)
        case .bytes:
            guard let text = value as? String, let data = Data(base64Encoded: Self.standardBase64(text)) else {
                throw ProtoError.badValue(field.name, "expected base64 bytes")
            }
            ProtoWire.tag(field.number, .lengthDelimited, into: &out)
            ProtoWire.varint(UInt64(data.count), into: &out)
            out += Array(data)
        default:
            ProtoWire.tag(field.number, ProtoWire.wireType(field.type), into: &out)
            try encodeScalar(field, value, into: &out)
        }
    }

    /// Scalar payload only (no tag), for single and packed values.
    private func encodeScalar(_ field: FieldDescriptor, _ value: Any, into out: inout [UInt8]) throws {
        func integer() throws -> Int64 {
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                guard number.doubleValue == number.doubleValue.rounded() else { throw ProtoError.badValue(field.name, "expected an integer") }
                return number.int64Value
            }
            if let text = value as? String, let number = Int64(text) { return number }
            throw ProtoError.badValue(field.name, "expected an integer")
        }
        func unsigned() throws -> UInt64 {
            if let text = value as? String, let number = UInt64(text) { return number }
            let signed = try integer()
            guard signed >= 0 else { throw ProtoError.badValue(field.name, "expected a non-negative integer") }
            return UInt64(signed)
        }
        func double() throws -> Double {
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue }
            if let text = value as? String {
                switch text {
                case "NaN": return .nan
                case "Infinity": return .infinity
                case "-Infinity": return -.infinity
                default: if let number = Double(text) { return number }
                }
            }
            throw ProtoError.badValue(field.name, "expected a number")
        }
        switch field.type {
        case .int32, .int64: ProtoWire.varint(UInt64(bitPattern: try integer()), into: &out)
        case .uint32, .uint64: ProtoWire.varint(try unsigned(), into: &out)
        case .sint32, .sint64:
            let number = try integer()
            ProtoWire.varint(UInt64(bitPattern: (number << 1) ^ (number >> 63)), into: &out)
        case .bool:
            guard let flag = value as? Bool else { throw ProtoError.badValue(field.name, "expected true or false") }
            ProtoWire.varint(flag ? 1 : 0, into: &out)
        case .enum:
            ProtoWire.varint(UInt64(bitPattern: Int64(try enumNumber(field, value))), into: &out)
        case .fixed32: ProtoWire.fixed32(UInt32(truncatingIfNeeded: try unsigned()), into: &out)
        case .sfixed32: ProtoWire.fixed32(UInt32(bitPattern: Int32(truncatingIfNeeded: try integer())), into: &out)
        case .float: ProtoWire.fixed32(Float(try double()).bitPattern, into: &out)
        case .fixed64: ProtoWire.fixed64(try unsigned(), into: &out)
        case .sfixed64: ProtoWire.fixed64(UInt64(bitPattern: try integer()), into: &out)
        case .double: ProtoWire.fixed64(try double().bitPattern, into: &out)
        default: throw ProtoError.badValue(field.name, "unsupported type")
        }
    }

    private func enumNumber(_ field: FieldDescriptor, _ value: Any) throws -> Int32 {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.int32Value }
        if let name = value as? String,
           let match = schema.enums[ProtoSchema.strip(field.typeName)]?.value.first(where: { $0.name == name }) {
            return match.number
        }
        throw ProtoError.badValue(field.name, "unknown enum value \(value)")
    }

    // MARK: binary → JSON

    func decode(_ bytes: [UInt8], as messageName: String) throws -> Any {
        if let special = try decodeWellKnown(bytes, messageName) { return special }
        guard let message = schema.messages[messageName] else { throw ProtoError.unknownMessage(messageName) }
        var object: [String: Any] = [:]
        var reader = ProtoWire.Reader(bytes: bytes)
        while let (number, wireType) = try reader.nextTag() {
            guard let field = message.field.first(where: { $0.number == number }) else {
                try reader.skip(wireType)
                continue
            }
            let key = field.jsonName.isEmpty ? field.name : field.jsonName
            if schema.isMapEntry(field) {
                let body = try reader.lengthDelimited()
                let entry = try decode(body, as: ProtoSchema.strip(field.typeName)) as? [String: Any] ?? [:]
                let entryMessage = schema.messages[ProtoSchema.strip(field.typeName)]!
                let keyName = entryMessage.field.first { $0.number == 1 }.map { $0.jsonName.isEmpty ? $0.name : $0.jsonName } ?? "key"
                let valueName = entryMessage.field.first { $0.number == 2 }.map { $0.jsonName.isEmpty ? $0.name : $0.jsonName } ?? "value"
                var map = object[key] as? [String: Any] ?? [:]
                map["\(entry[keyName] ?? "")"] = entry[valueName] ?? NSNull()
                object[key] = map
            } else if field.label == .repeated {
                var array = object[key] as? [Any] ?? []
                if wireType == .lengthDelimited, ProtoWire.isPackable(field.type) {
                    var packed = ProtoWire.Reader(bytes: try reader.lengthDelimited())
                    while !packed.isAtEnd { array.append(try decodeScalar(field, ProtoWire.wireType(field.type), &packed)) }
                } else {
                    array.append(try decodeValue(field, wireType, &reader))
                }
                object[key] = array
            } else {
                object[key] = try decodeValue(field, wireType, &reader)
            }
        }
        if schema.isProto3(messageName) {
            for field in message.field where object[field.jsonName.isEmpty ? field.name : field.jsonName] == nil
                && !field.proto3Optional && !field.hasOneofIndex {
                object[field.jsonName.isEmpty ? field.name : field.jsonName] = defaultValue(field)
            }
        }
        return object
    }

    private func defaultValue(_ field: FieldDescriptor) -> Any {
        if schema.isMapEntry(field) { return [String: Any]() }
        if field.label == .repeated { return [Any]() }
        switch field.type {
        case .message, .group: return NSNull()
        case .string, .bytes: return ""
        case .bool: return false
        case .enum: return schema.enums[ProtoSchema.strip(field.typeName)]?.value.first?.name ?? 0
        case .int64, .uint64, .sint64, .fixed64, .sfixed64: return "0"
        default: return 0
        }
    }

    private func decodeValue(_ field: FieldDescriptor, _ wireType: ProtoWire.WireType, _ reader: inout ProtoWire.Reader) throws -> Any {
        switch field.type {
        case .message, .group:
            return try decode(try reader.lengthDelimited(), as: ProtoSchema.strip(field.typeName))
        case .string:
            return String(decoding: try reader.lengthDelimited(), as: UTF8.self)
        case .bytes:
            return Data(try reader.lengthDelimited()).base64EncodedString()
        default:
            return try decodeScalar(field, wireType, &reader)
        }
    }

    private func decodeScalar(_ field: FieldDescriptor, _ wireType: ProtoWire.WireType, _ reader: inout ProtoWire.Reader) throws -> Any {
        switch field.type {
        case .int32: return Int32(truncatingIfNeeded: Int64(bitPattern: try reader.varint()))
        case .int64: return String(Int64(bitPattern: try reader.varint()))
        case .uint32: return UInt32(truncatingIfNeeded: try reader.varint())
        case .uint64: return String(try reader.varint())
        case .sint32, .sint64:
            let raw = try reader.varint()
            let value = Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
            return field.type == .sint32 ? Int32(truncatingIfNeeded: value) as Any : String(value) as Any
        case .bool: return try reader.varint() != 0
        case .enum:
            let number = Int32(truncatingIfNeeded: Int64(bitPattern: try reader.varint()))
            return schema.enums[ProtoSchema.strip(field.typeName)]?.value.first { $0.number == number }?.name ?? number
        case .fixed32: return try reader.fixed32()
        case .sfixed32: return Int32(bitPattern: try reader.fixed32())
        case .float: return Self.jsonNumber(Double(Float(bitPattern: try reader.fixed32())))
        case .fixed64: return String(try reader.fixed64())
        case .sfixed64: return String(Int64(bitPattern: try reader.fixed64()))
        case .double: return Self.jsonNumber(Double(bitPattern: try reader.fixed64()))
        default:
            try reader.skip(wireType)
            return NSNull()
        }
    }

    private static func jsonNumber(_ value: Double) -> Any {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
        return value
    }

    static func standardBase64(_ text: String) -> String {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return base
    }

    // MARK: Well-known types

    private static let wrappers: [String: Google_Protobuf_FieldDescriptorProto.TypeEnum] = [
        "google.protobuf.DoubleValue": .double, "google.protobuf.FloatValue": .float,
        "google.protobuf.Int64Value": .int64, "google.protobuf.UInt64Value": .uint64,
        "google.protobuf.Int32Value": .int32, "google.protobuf.UInt32Value": .uint32,
        "google.protobuf.BoolValue": .bool, "google.protobuf.StringValue": .string,
        "google.protobuf.BytesValue": .bytes,
    ]

    private func wrapperField(_ type: Google_Protobuf_FieldDescriptorProto.TypeEnum) -> FieldDescriptor {
        var field = FieldDescriptor()
        field.name = "value"
        field.jsonName = "value"
        field.number = 1
        field.type = type
        field.label = .optional
        return field
    }

    private func encodeWellKnown(_ json: Any, _ name: String) throws -> [UInt8]? {
        if let type = Self.wrappers[name] {
            var out: [UInt8] = []
            try encodeSingle(wrapperField(type), json, into: &out)
            return out
        }
        switch name {
        case "google.protobuf.Timestamp":
            guard let text = json as? String, let parsed = Self.parseTimestamp(text) else {
                throw ProtoError.badValue(name, "expected an RFC 3339 time like 2024-01-02T03:04:05Z")
            }
            return Self.secondsNanos(parsed.seconds, parsed.nanos)
        case "google.protobuf.Duration":
            guard let text = json as? String, text.hasSuffix("s"), let seconds = Double(text.dropLast()) else {
                throw ProtoError.badValue(name, "expected a duration like \"1.5s\"")
            }
            let whole = Int64(seconds.rounded(.towardZero))
            return Self.secondsNanos(whole, Int32(((seconds - Double(whole)) * 1e9).rounded()))
        case "google.protobuf.Empty":
            return []
        case "google.protobuf.FieldMask":
            guard let text = json as? String else { throw ProtoError.badValue(name, "expected a comma-separated string") }
            var out: [UInt8] = []
            for path in text.split(separator: ",") {
                let snake = path.reduce(into: "") { result, character in
                    if character.isUppercase { result += "_" + character.lowercased() } else { result.append(character) }
                }
                ProtoWire.tag(1, .lengthDelimited, into: &out)
                ProtoWire.varint(UInt64(snake.utf8.count), into: &out)
                out += Array(snake.utf8)
            }
            return out
        case "google.protobuf.Struct", "google.protobuf.Value", "google.protobuf.ListValue":
            let message: SwiftProtobuf.Message
            let data = try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
            switch name {
            case "google.protobuf.Struct": message = try Google_Protobuf_Struct(jsonUTF8Data: data)
            case "google.protobuf.ListValue": message = try Google_Protobuf_ListValue(jsonUTF8Data: data)
            default: message = try Google_Protobuf_Value(jsonUTF8Data: data)
            }
            return Array(try message.serializedData())
        default:
            return nil
        }
    }

    private func decodeWellKnown(_ bytes: [UInt8], _ name: String) throws -> Any? {
        if let type = Self.wrappers[name] {
            let object = try ProtoCodec(schema: ProtoSchema(files: [Self.wrapperFile(type)])).decode(bytes, as: "gowa.Wrapper")
            return (object as? [String: Any])?["value"] ?? NSNull()
        }
        switch name {
        case "google.protobuf.Timestamp":
            let value = try Google_Protobuf_Timestamp(serializedBytes: bytes)
            return String(data: try value.jsonUTF8Data(), encoding: .utf8)!.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        case "google.protobuf.Duration":
            let value = try Google_Protobuf_Duration(serializedBytes: bytes)
            return String(data: try value.jsonUTF8Data(), encoding: .utf8)!.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        case "google.protobuf.Empty":
            return [String: Any]()
        case "google.protobuf.FieldMask":
            let value = try Google_Protobuf_FieldMask(serializedBytes: bytes)
            return String(data: try value.jsonUTF8Data(), encoding: .utf8)!.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        case "google.protobuf.Struct":
            return try JSONSerialization.jsonObject(with: try Google_Protobuf_Struct(serializedBytes: bytes).jsonUTF8Data(), options: [.fragmentsAllowed])
        case "google.protobuf.Value":
            return try JSONSerialization.jsonObject(with: try Google_Protobuf_Value(serializedBytes: bytes).jsonUTF8Data(), options: [.fragmentsAllowed])
        case "google.protobuf.ListValue":
            return try JSONSerialization.jsonObject(with: try Google_Protobuf_ListValue(serializedBytes: bytes).jsonUTF8Data(), options: [.fragmentsAllowed])
        case "google.protobuf.Any":
            let value = try Google_Protobuf_Any(serializedBytes: bytes)
            let inner = ProtoSchema.strip(String(value.typeURL.split(separator: "/").last ?? ""))
            if schema.messages[inner] != nil, var object = try decode(Array(value.value), as: inner) as? [String: Any] {
                object["@type"] = value.typeURL
                return object
            }
            return ["@type": value.typeURL, "value": value.value.base64EncodedString()]
        default:
            return nil
        }
    }

    private static func wrapperFile(_ type: Google_Protobuf_FieldDescriptorProto.TypeEnum) -> Google_Protobuf_FileDescriptorProto {
        var field = FieldDescriptor()
        field.name = "value"
        field.jsonName = "value"
        field.number = 1
        field.type = type
        field.label = .optional
        var message = Google_Protobuf_DescriptorProto()
        message.name = "Wrapper"
        message.field = [field]
        var file = Google_Protobuf_FileDescriptorProto()
        file.package = "gowa"
        file.syntax = "proto3"
        file.messageType = [message]
        return file
    }

    private static func secondsNanos(_ seconds: Int64, _ nanos: Int32) -> [UInt8] {
        var out: [UInt8] = []
        if seconds != 0 {
            ProtoWire.tag(1, .varint, into: &out)
            ProtoWire.varint(UInt64(bitPattern: seconds), into: &out)
        }
        if nanos != 0 {
            ProtoWire.tag(2, .varint, into: &out)
            ProtoWire.varint(UInt64(bitPattern: Int64(nanos)), into: &out)
        }
        return out
    }

    static func parseTimestamp(_ text: String) -> (seconds: Int64, nanos: Int32)? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = formatter.date(from: text) ?? plain.date(from: text) else { return nil }
        let interval = date.timeIntervalSince1970
        let seconds = Int64(interval.rounded(.down))
        var nanos: Int32 = 0
        if let dot = text.firstIndex(of: "."), let end = text[dot...].firstIndex(where: { !$0.isNumber && $0 != "." }) {
            let digits = String(text[text.index(after: dot)..<end].prefix(9))
            nanos = Int32(digits.padding(toLength: 9, withPad: "0", startingAt: 0)) ?? 0
        }
        return (seconds, nanos)
    }

    // MARK: Templates

    /// A JSON skeleton of a message with every field at its default, for the editor.
    func template(for messageName: String, depth: Int = 0) -> Any {
        if Self.wrappers[messageName] != nil { return NSNull() }
        switch messageName {
        case "google.protobuf.Timestamp": return ISO8601DateFormatter().string(from: Date())
        case "google.protobuf.Duration": return "1s"
        case "google.protobuf.Struct": return [String: Any]()
        default: break
        }
        guard depth < 4, let message = schema.messages[messageName] else { return [String: Any]() }
        var object: [String: Any] = [:]
        for field in message.field {
            let key = field.jsonName.isEmpty ? field.name : field.jsonName
            if schema.isMapEntry(field) {
                object[key] = [String: Any]()
            } else if field.label == .repeated {
                object[key] = field.type == .message ? [template(for: ProtoSchema.strip(field.typeName), depth: depth + 1)] : [Any]()
            } else if field.type == .message {
                object[key] = template(for: ProtoSchema.strip(field.typeName), depth: depth + 1)
            } else {
                object[key] = defaultValue(field)
            }
        }
        return object
    }
}

/// Protobuf wire format primitives.
enum ProtoWire {
    enum WireType: UInt64 {
        case varint = 0, fixed64 = 1, lengthDelimited = 2, startGroup = 3, endGroup = 4, fixed32 = 5
    }

    static func wireType(_ type: Google_Protobuf_FieldDescriptorProto.TypeEnum) -> WireType {
        switch type {
        case .double, .fixed64, .sfixed64: .fixed64
        case .float, .fixed32, .sfixed32: .fixed32
        case .string, .bytes, .message: .lengthDelimited
        case .group: .startGroup
        default: .varint
        }
    }

    static func isPackable(_ type: Google_Protobuf_FieldDescriptorProto.TypeEnum) -> Bool {
        ![.string, .bytes, .message, .group].contains(type)
    }

    static func tag(_ number: Int32, _ type: WireType, into out: inout [UInt8]) {
        varint(UInt64(number) << 3 | type.rawValue, into: &out)
    }

    static func varint(_ value: UInt64, into out: inout [UInt8]) {
        var value = value
        while value >= 0x80 {
            out.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
    }

    static func fixed32(_ value: UInt32, into out: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { out += $0 }
    }

    static func fixed64(_ value: UInt64, into out: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { out += $0 }
    }

    struct Reader {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func nextTag() throws -> (Int32, WireType)? {
            guard !isAtEnd else { return nil }
            let key = try varint()
            guard let type = WireType(rawValue: key & 7) else { throw ProtoError.truncated }
            return (Int32(truncatingIfNeeded: key >> 3), type)
        }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard offset < bytes.count, shift < 64 else { throw ProtoError.truncated }
                let byte = bytes[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
        }

        mutating func fixed32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw ProtoError.truncated }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func fixed64() throws -> UInt64 {
            guard offset + 8 <= bytes.count else { throw ProtoError.truncated }
            defer { offset += 8 }
            return bytes[offset..<offset + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }

        mutating func lengthDelimited() throws -> [UInt8] {
            guard let length = Int(exactly: try varint()), length <= bytes.count - offset else { throw ProtoError.truncated }
            defer { offset += length }
            return Array(bytes[offset..<offset + length])
        }

        mutating func skip(_ type: WireType) throws {
            switch type {
            case .varint: _ = try varint()
            case .fixed64: _ = try fixed64()
            case .fixed32: _ = try fixed32()
            case .lengthDelimited: _ = try lengthDelimited()
            case .startGroup, .endGroup: throw ProtoError.badValue("group", "groups aren't supported")
            }
        }
    }
}
