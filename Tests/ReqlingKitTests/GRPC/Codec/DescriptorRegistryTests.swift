import Foundation
@testable import ReqlingKit
import SwiftProtobuf
import XCTest

final class DescriptorRegistryTests: XCTestCase {
    func testResolvesMessagesEnumsAndServicesIncludingNestedAndImportedTypes() throws {
        let registry = try CodecFixtures.registry()

        XCTAssertEqual(registry.message("reqling.test.v1.Everything")?.name, "Everything")
        XCTAssertEqual(registry.message(".reqling.test.v1.Everything.Nested")?.name, "Nested")
        XCTAssertEqual(registry.enumType("reqling.test.v1.Everything.Nested.Mood")?.value.map(\.name), ["MOOD_UNSPECIFIED", "MOOD_CALM"])
        XCTAssertEqual(registry.enumType("reqling.test.v1.Color")?.value.count, 3)
        XCTAssertNotNil(registry.message("google.protobuf.Timestamp"))
        XCTAssertNotNil(registry.message("google.protobuf.Struct.FieldsEntry"))
        XCTAssertNil(registry.message("reqling.test.v1.Nested"))

        XCTAssertEqual(registry.services.map(\.fullName), ["reqling.test.v1.EchoService"])
        let bidi = try XCTUnwrap(registry.method("/reqling.test.v1.EchoService/Bidi"))
        XCTAssertEqual(bidi.inputType, "reqling.test.v1.EchoMessage")
        XCTAssertEqual(bidi.kind, GRPCMethodKind(clientStreams: true, serverStreams: true))
        XCTAssertNil(registry.method("reqling.test.v1.EchoService/Missing"))
    }

    func testSchemaIndexesFieldsByNumberAndBothNames() throws {
        let schema = try XCTUnwrap(try CodecFixtures.registry().schema("reqling.test.v1.Everything"))

        let renamed = try XCTUnwrap(schema.field(named: "customName"))
        XCTAssertEqual(schema.field(named: "renamed")?.number, renamed.number)
        XCTAssertEqual(schema.field(number: 14)?.jsonName, "customName")
        XCTAssertEqual(schema.field(named: "packed_numbers")?.jsonName, "packedNumbers")
        XCTAssertEqual(schema.field(named: "wrappedUint64")?.name, "wrapped_uint64")
        XCTAssertNil(schema.field(named: "packednumbers"))

        XCTAssertEqual(schema.field(named: "counts")?.isMap, true)
        XCTAssertEqual(schema.field(named: "rows")?.isMap, false)
        XCTAssertEqual(schema.field(named: "nested")?.typeName, "reqling.test.v1.Everything.Nested")
        // Presence: proto3 `optional`, oneof members, and messages have it; plain scalars do not.
        XCTAssertEqual(schema.field(named: "maybe")?.hasPresence, true)
        XCTAssertEqual(schema.field(named: "choiceColor")?.hasPresence, true)
        XCTAssertEqual(schema.field(named: "scalars")?.hasPresence, true)
        XCTAssertEqual(schema.field(named: "color")?.hasPresence, false)
        XCTAssertEqual(schema.field(named: "choiceText")?.oneofIndex, schema.field(named: "choiceColor")?.oneofIndex)
        XCTAssertNotEqual(schema.field(named: "maybe")?.oneofIndex, schema.field(named: "choiceColor")?.oneofIndex)
    }

    func testDerivesJSONNamesWhenDescriptorsOmitThem() {
        XCTAssertEqual(FieldSchema.jsonName(for: "user_display_name"), "userDisplayName")
        XCTAssertEqual(FieldSchema.jsonName(for: "_leading__double_"), "LeadingDouble")
        XCTAssertEqual(FieldSchema.jsonName(for: "v2_api"), "v2Api")
    }

    func testMergingLetsTheOtherRegistryOverrideAType() throws {
        var first = Google_Protobuf_FileDescriptorProto()
        first.name = "a.proto"
        first.package = "pkg"
        first.messageType = [Google_Protobuf_DescriptorProto.with { $0.name = "Thing" }]
        var second = first
        second.name = "b.proto"
        second.messageType[0].field = [Google_Protobuf_FieldDescriptorProto.with {
            $0.name = "id"
            $0.number = 1
            $0.type = .string
            $0.label = .optional
        }]

        let merged = DescriptorRegistry(files: [first]).merging(DescriptorRegistry(files: [second]))

        XCTAssertEqual(merged.schema("pkg.Thing")?.fields.map(\.name), ["id"])
        XCTAssertEqual(merged.files.map(\.name), ["a.proto", "b.proto"])
    }
}
