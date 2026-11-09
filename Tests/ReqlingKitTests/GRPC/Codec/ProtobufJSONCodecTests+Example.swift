import Foundation
@testable import ReqlingKit
import SwiftProtobuf
import XCTest

extension ProtobufJSONCodecTests {
    func testExampleParsesWithSwiftProtobufAndShowsEveryField() throws {
        let example = codec.example(for: Self.everything)

        let parsed = try Reqling_Test_V1_Everything(jsonString: example)
        try CodecFixtures.assertEquivalent(Reqling_Test_V1_Everything(serializedBytes: codec.encode(json: example, as: Self.everything)), parsed)
        guard case .object(let members) = try OrderedJSONParser.parse(example) else {
            return XCTFail("Not an object: \(example)")
        }
        let keys = members.map(\.key)
        let expectedKeys = [
            "scalars", "color", "packedNumbers", "tags", "rows", "counts", "byId", "flags", "choiceText", "maybe", "nested",
            "customName", "colors", "packedDoubles", "at", "elapsed", "mask", "attributes", "value", "list", "wrappedInt64",
            "wrappedString", "wrappedBool", "wrappedBytes", "wrappedDouble", "nothing", "extra", "wrappedFloat", "wrappedInt32",
            "wrappedUint32", "wrappedUint64", "colorById", "extras"
        ]
        XCTAssertEqual(keys, expectedKeys)
        XCTAssertTrue(parsed.hasMaybe)
        XCTAssertEqual(parsed.choice, .choiceText(""))
    }

    func testExamplePlaceholdersAndRecursionGuard() throws {
        let example = try OrderedJSONParser.parse(codec.example(for: Self.everything))
        guard case .object(let members) = example else {
            return XCTFail("Not an object")
        }
        let values = Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(values["color"], .string("COLOR_UNSPECIFIED"))
        XCTAssertEqual(values["counts"], .object([OrderedJSONMember(key: "key", value: .number("0"))]))
        XCTAssertEqual(values["byId"].flatMap(Self.firstKey), "0")
        XCTAssertEqual(values["flags"].flatMap(Self.firstKey), "false")
        XCTAssertEqual(values["at"], .string("1970-01-01T00:00:00Z"))
        XCTAssertEqual(values["elapsed"], .string("0s"))
        XCTAssertEqual(values["wrappedInt64"], .string("0"))
        XCTAssertEqual(values["value"], .null)
        XCTAssertEqual(values["extras"], .array([.object([])]))
        // `Nested.children` contains `Nested` itself, so the guard stops one level in.
        try CodecFixtures.assertJSON(
            OrderedJSON.object([OrderedJSONMember(key: "nested", value: values["nested"] ?? .null)]).prettyPrinted(),
            #"{"nested": {"mood": "MOOD_UNSPECIFIED", "children": [{}]}}"#
        )
    }

    func testExampleForScalarsUnknownAndWellKnownTypes() throws {
        XCTAssertEqual(codec.example(for: "nope.Missing"), "{}")
        XCTAssertEqual(codec.example(for: "google.protobuf.Timestamp"), #""1970-01-01T00:00:00Z""#)
        XCTAssertEqual(codec.example(for: "google.protobuf.UInt64Value"), #""0""#)
        XCTAssertEqual(codec.example(for: "reqling.test.v1.EchoMessage"), """
        {
          "text": "",
          "index": 0
        }
        """)
        let scalars = codec.example(for: ".\(Self.scalars)")
        XCTAssertEqual(try Reqling_Test_V1_Scalars(jsonString: scalars), Reqling_Test_V1_Scalars())
        try CodecFixtures.assertJSON(scalars, #"""
        {
          "d": 0, "f": 0, "i32": 0, "i64": "0", "u32": 0, "u64": "0", "s32": 0, "s64": "0", "fx32": 0, "fx64": "0",
          "sfx32": 0, "sfx64": "0", "flag": false, "text": "", "data": ""
        }
        """#)
    }

    func testExampleStaysSmallForMutuallyReferencingTypes() throws {
        // Nine types that each hold all the others once made factorially many paths and a 24 MB example.
        let names = (0..<9).map { "T\($0)" }
        let messages = names.map { name in
            CodecFixtures.message(name, [CodecFixtures.field("label", 1, .string)] + names.enumerated().compactMap { index, other in
                other == name ? nil : CodecFixtures.field(other.lowercased(), Int32(index + 2), .message, typeName: ".mesh.\(other)")
            })
        }
        let mesh = ProtobufJSONCodec(registry: DescriptorRegistry(files: [CodecFixtures.file("mesh", syntax: "proto3", messages)]))

        let example = mesh.example(for: "mesh.T0")

        XCTAssertLessThan(example.utf8.count, 100_000)
        XCTAssertNoThrow(try mesh.encode(json: example, as: "mesh.T0"))
    }

    func testExampleDepthIsCapped() throws {
        let chain = (0..<40).map { index in
            CodecFixtures.message("C\(index)", [CodecFixtures.field("next", 1, .message, typeName: ".chain.C\(index + 1)")])
        }
        let codec = ProtobufJSONCodec(registry: DescriptorRegistry(files: [CodecFixtures.file("chain", syntax: "proto3", chain)]))

        let example = try OrderedJSONParser.parse(codec.example(for: "chain.C0"))

        // 32 expanded levels, then `{}`.
        XCTAssertEqual(Self.objectDepth(example), ProtobufJSONCodec.ExampleBudget.maxDepth + 1)
    }

    private static func objectDepth(_ json: OrderedJSON) -> Int {
        guard case .object(let members) = json else {
            return 0
        }
        return 1 + (members.map { objectDepth($0.value) }.max() ?? 0)
    }

    private static func firstKey(_ json: OrderedJSON) -> String? {
        guard case .object(let members) = json else {
            return nil
        }
        return members.first?.key
    }
}
