import Foundation
import SwiftProtobuf
import Testing
@testable import gowa

private func field(_ name: String, _ number: Int32, _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
                   repeated: Bool = false, typeName: String = "") -> Google_Protobuf_FieldDescriptorProto {
    var field = Google_Protobuf_FieldDescriptorProto()
    field.name = name
    field.jsonName = name
    field.number = number
    field.type = type
    field.label = repeated ? .repeated : .optional
    if !typeName.isEmpty { field.typeName = typeName }
    return field
}

private func schema() -> ProtoSchema {
    var labelsEntry = Google_Protobuf_DescriptorProto()
    labelsEntry.name = "LabelsEntry"
    labelsEntry.field = [field("key", 1, .string), field("value", 2, .string)]
    labelsEntry.options.mapEntry = true

    var inner = Google_Protobuf_DescriptorProto()
    inner.name = "Inner"
    inner.field = [field("note", 1, .string)]

    var item = Google_Protobuf_DescriptorProto()
    item.name = "Item"
    item.nestedType = [labelsEntry]
    item.field = [
        field("name", 1, .string), field("id", 2, .int64), field("scores", 3, .int32, repeated: true),
        field("labels", 4, .message, repeated: true, typeName: ".shop.Item.LabelsEntry"),
        field("status", 5, .enum, typeName: ".shop.Status"), field("inner", 6, .message, typeName: ".shop.Inner"),
        field("at", 7, .message, typeName: ".google.protobuf.Timestamp"), field("blob", 8, .bytes),
        field("ratio", 9, .double), field("on", 10, .bool), field("delta", 11, .sint32),
        field("count", 12, .message, typeName: ".google.protobuf.Int32Value"),
    ]

    var status = Google_Protobuf_EnumDescriptorProto()
    status.name = "Status"
    status.value = [("UNKNOWN", Int32(0)), ("ACTIVE", Int32(1))].map { name, number in
        var value = Google_Protobuf_EnumValueDescriptorProto()
        value.name = name
        value.number = number
        return value
    }

    var method = Google_Protobuf_MethodDescriptorProto()
    method.name = "Get"
    method.inputType = ".shop.Item"
    method.outputType = ".shop.Item"
    method.serverStreaming = true
    var service = Google_Protobuf_ServiceDescriptorProto()
    service.name = "Shop"
    service.method = [method]

    var file = Google_Protobuf_FileDescriptorProto()
    file.name = "shop.proto"
    file.package = "shop"
    file.syntax = "proto3"
    file.messageType = [item, inner]
    file.enumType = [status]
    file.service = [service]
    return ProtoSchema(files: [file])
}

@Test("JSON encodes to the exact protobuf wire bytes")
func protoEncodeBytes() throws {
    let codec = ProtoCodec(schema: schema())
    #expect(try codec.encode(json: ["name": "a", "id": "150"], as: "shop.Item") == [0x0A, 0x01, 0x61, 0x10, 0x96, 0x01])
    #expect(try codec.encode(json: ["scores": [3, 270]], as: "shop.Item") == [0x1A, 0x03, 0x03, 0x8E, 0x02])
    #expect(try codec.encode(json: ["delta": -2], as: "shop.Item") == [0x58, 0x03])
    #expect(try codec.encode(json: ["status": "ACTIVE"], as: "shop.Item") == [0x28, 0x01])
}

@Test("messages round-trip through binary with maps, nesting, enums, and well-known types")
func protoRoundTrip() throws {
    let codec = ProtoCodec(schema: schema())
    let json: [String: Any] = [
        "name": "mug", "id": "9007199254740993", "scores": [1, 2], "labels": ["color": "red"],
        "status": "ACTIVE", "inner": ["note": "hi"], "at": "2024-01-02T03:04:05.250Z",
        "blob": Data("xyz".utf8).base64EncodedString(), "ratio": 0.5, "on": true, "delta": -7, "count": 3,
    ]
    let decoded = try codec.decode(try codec.encode(json: json, as: "shop.Item"), as: "shop.Item") as! [String: Any]
    #expect(decoded["name"] as? String == "mug")
    #expect(decoded["id"] as? String == "9007199254740993")
    #expect((decoded["scores"] as? [Int32]) == [1, 2])
    #expect(decoded["labels"] as? [String: String] == ["color": "red"])
    #expect(decoded["status"] as? String == "ACTIVE")
    #expect((decoded["inner"] as? [String: Any])?["note"] as? String == "hi")
    #expect(decoded["at"] as? String == "2024-01-02T03:04:05.250Z")
    #expect(decoded["blob"] as? String == "eHl6")
    #expect(decoded["ratio"] as? Double == 0.5)
    #expect(decoded["on"] as? Bool == true)
    #expect(decoded["delta"] as? Int32 == -7)
    #expect(decoded["count"] as? Int32 == 3)
}

@Test("proto3 decoding fills defaults; unknown fields and types are reported")
func protoDefaultsAndErrors() throws {
    let codec = ProtoCodec(schema: schema())
    let empty = try codec.decode([], as: "shop.Item") as! [String: Any]
    #expect(empty["name"] as? String == "")
    #expect(empty["id"] as? String == "0")
    #expect(empty["status"] as? String == "UNKNOWN")
    #expect(empty["on"] as? Bool == false)
    #expect { try codec.encode(json: ["nope": 1], as: "shop.Item") } throws: { ($0 as? ProtoError) == .unknownField("shop.Item", "nope") }
    #expect { try codec.encode(json: [:], as: "shop.Missing") } throws: { ($0 as? ProtoError) == .unknownMessage("shop.Missing") }
    #expect { try codec.decode([0x0A, 0x05, 0x61], as: "shop.Item") } throws: { ($0 as? ProtoError) == .truncated }
}

@Test("schema lists methods with streaming kinds; templates cover every field")
func protoSchemaAndTemplate() {
    let schema = schema()
    #expect(schema.methods.map(\.fullName) == ["shop.Shop/Get"])
    #expect(schema.method("/shop.Shop/Get")?.kind == "server-streaming")
    let template = ProtoCodec(schema: schema).template(for: "shop.Item") as! [String: Any]
    #expect(Set(template.keys) == ["name", "id", "scores", "labels", "status", "inner", "at", "blob", "ratio", "on", "delta", "count"])
}

@Test("gRPC addresses pick TLS from the scheme or port 443")
func grpcTargets() throws {
    #expect(try GrpcTarget.parse("localhost:50051") == GrpcTarget(host: "localhost", port: 50051, tls: false))
    #expect(try GrpcTarget.parse("grpcs://api.test") == GrpcTarget(host: "api.test", port: 443, tls: true))
    #expect(try GrpcTarget.parse("api.test:443") == GrpcTarget(host: "api.test", port: 443, tls: true))
    #expect(try GrpcTarget.parse("grpc://[::1]:9000/") == GrpcTarget(host: "::1", port: 9000, tls: false))
    #expect(throws: GrpcError.self) { try GrpcTarget.parse("host:abc") }
    #expect(GrpcClient.statusName("notFound") == "NOT_FOUND")
}

@Test("reflection replies decode service lists and errors")
func reflectionWire() throws {
    var service: [UInt8] = []
    ProtoWire.tag(1, .lengthDelimited, into: &service)
    ProtoWire.varint(3, into: &service)
    service += Array("a.B".utf8)
    var list: [UInt8] = []
    ProtoWire.tag(1, .lengthDelimited, into: &list)
    ProtoWire.varint(UInt64(service.count), into: &list)
    list += service
    var reply: [UInt8] = []
    ProtoWire.tag(6, .lengthDelimited, into: &reply)
    ProtoWire.varint(UInt64(list.count), into: &reply)
    reply += list
    guard case .services(let names) = try ReflectionWire.parse(reply) else { Issue.record("expected services"); return }
    #expect(names == ["a.B"])
    #expect(ReflectionWire.listServices() == [0x3A, 0x00])
}

@MainActor
@Test("grpc items round-trip with method, metadata, and message variants")
func grpcItemRoundTrip() {
    let doc = OpenCollectionDocument(root: ["items": [[
        "info": ["name": "Check", "type": "grpc"],
        "grpc": ["url": "localhost:50051", "method": "grpc.health.v1.Health/Check", "methodType": "unary",
                 "message": [["title": "a", "selected": true, "message": "{\"service\": \"x\"}"]]],
    ]]])
    var snapshot = doc.grpcSnapshot(at: [0])!
    #expect(snapshot.message == "{\"service\": \"x\"}")
    snapshot.metadata = [OCHeader(name: "x-trace", value: "1", disabled: false)]
    snapshot.message = "{}"
    doc.updateGrpc(at: [0], snapshot)
    #expect(doc.grpcSnapshot(at: [0]) == snapshot)
    #expect(doc.enumerate()[0].kind == "grpc")
}
