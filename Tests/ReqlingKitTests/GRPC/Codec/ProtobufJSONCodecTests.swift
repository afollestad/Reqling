import Foundation
@testable import ReqlingKit
import SwiftProtobuf
import XCTest

/// Checks the dynamic codec against SwiftProtobuf's generated code for the same `.proto`, which is the oracle for
/// both directions of the proto3 JSON mapping.
final class ProtobufJSONCodecTests: XCTestCase {
    static let everything = "reqling.test.v1.Everything"
    static let scalars = "reqling.test.v1.Scalars"

    var codec = ProtobufJSONCodec(registry: .empty)

    override static func setUp() {
        super.setUp()
        // SwiftProtobuf needs non-WKT payload types registered to transcode Any; registering is idempotent.
        Google_Protobuf_Any.register(messageType: Reqling_Test_V1_Scalars.self)
        Google_Protobuf_Any.register(messageType: Reqling_Test_V1_Everything.Nested.self)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        codec = ProtobufJSONCodec(registry: try CodecFixtures.registry())
    }

    func testEncodeMatchesSwiftProtobufForEveryFieldShape() throws {
        let bytes = try codec.encode(json: CodecFixtures.richEverythingJSON, as: Self.everything)

        let decoded = try Reqling_Test_V1_Everything(serializedBytes: bytes)
        let expected = try Reqling_Test_V1_Everything(jsonString: CodecFixtures.richEverythingJSON)
        try CodecFixtures.assertEquivalent(decoded, expected)
        XCTAssertEqual(decoded.choice, .choiceScalars(expected.choiceScalars))
        XCTAssertTrue(decoded.hasMaybe)
    }

    func testDecodeMatchesSwiftProtobufForEveryFieldShape() throws {
        let original = try Reqling_Test_V1_Everything(jsonString: CodecFixtures.richEverythingJSON)

        let json = try codec.decode(original.wireBytes(), as: Self.everything)

        try CodecFixtures.assertEquivalent(try Reqling_Test_V1_Everything(jsonString: json), original)
    }

    /// SwiftProtobuf keeps unknown fields it parses and writes them back, so each message below carries some at its
    /// own depth: in a repeated element, a map value, and an `Any` payload.
    func testDecodeCountsTheUnknownFieldsItDropsAtEveryDepth() throws {
        let field99Twice: [UInt8] = [0x98, 0x06, 0x01, 0x98, 0x06, 0x02]
        let field100: [UInt8] = [0xA0, 0x06, 0x01]
        var message = try Reqling_Test_V1_Everything(jsonString: #"""
        {"nested": {"children": [{}, {"mood": "MOOD_CALM"}]}, "byId": {"7": {"flag": true}}}
        """#)
        var scalars = Reqling_Test_V1_Scalars()
        scalars.text = "packed"
        message.extra = try Google_Protobuf_Any(message: scalars)
        let clean = try codec.decodeCountingUnknownFields(message.wireBytes(), as: Self.everything)
        XCTAssertEqual(clean.unknownFieldCount, 0)

        message.nested.children[1] = try Self.adding(field99Twice + field100, to: message.nested.children[1])
        message.byID[7] = try Self.adding(field100, to: message.byID[7] ?? Reqling_Test_V1_Scalars())
        message.extra = try Google_Protobuf_Any(message: try Self.adding(field99Twice, to: scalars))
        message = try Self.adding(field99Twice, to: message)
        let decoded = try codec.decodeCountingUnknownFields(message.wireBytes(), as: Self.everything)

        XCTAssertEqual(decoded.json, clean.json)
        XCTAssertEqual(decoded.unknownFieldCount, 2 + 1 + 1 + 1, "Distinct field numbers per message, summed over every message")
    }

    func testDecodeRoundTripsThroughEncode() throws {
        let bytes = try codec.encode(json: CodecFixtures.richEverythingJSON, as: Self.everything)
        let json = try codec.decode(bytes, as: Self.everything)

        XCTAssertEqual(try codec.encode(json: json, as: Self.everything), bytes)
    }

    func testDecodeWritesCanonicalScalarsInDeclarationOrder() throws {
        var scalars = Reqling_Test_V1_Scalars()
        scalars.data = Data([0, 1, 2, 255])
        scalars.text = "line\n\"quoted\" \u{1}"
        scalars.flag = true
        scalars.sfx64 = .min
        scalars.sfx32 = .min
        scalars.fx64 = .max
        scalars.fx32 = .max
        scalars.s64 = .max
        scalars.s32 = .min
        scalars.u64 = .max
        scalars.u32 = .max
        scalars.i64 = .min
        scalars.i32 = -42
        scalars.f = 0.1
        scalars.d = 1e300

        let json = try codec.decode(scalars.wireBytes(), as: Self.scalars)

        XCTAssertEqual(json, """
        {
          "d": 1e+300,
          "f": 0.1,
          "i32": -42,
          "i64": "-9223372036854775808",
          "u32": 4294967295,
          "u64": "18446744073709551615",
          "s32": -2147483648,
          "s64": "9223372036854775807",
          "fx32": 4294967295,
          "fx64": "18446744073709551615",
          "sfx32": -2147483648,
          "sfx64": "-9223372036854775808",
          "flag": true,
          "text": "line\\n\\"quoted\\" \\u0001",
          "data": "AAEC/w=="
        }
        """)
    }

    func testDecodeOmitsImplicitDefaultsButKeepsPresenceFields() throws {
        var message = Reqling_Test_V1_Everything()
        message.maybe = 0
        message.choiceColor = .unspecified
        message.scalars = Reqling_Test_V1_Scalars()
        message.wrappedInt64 = Google_Protobuf_Int64Value()
        message.color = .unspecified

        let json = try codec.decode(message.wireBytes(), as: Self.everything)

        try CodecFixtures.assertJSON(json, #"""
        {"scalars": {}, "choiceColor": "COLOR_UNSPECIFIED", "maybe": 0, "wrappedInt64": "0"}
        """#)
    }

    func testEncodeOmitsImplicitDefaultsAndPacksRepeatedScalars() throws {
        let json = #"""
        {"color": "COLOR_UNSPECIFIED", "scalars": {}, "maybe": 0, "tags": [], "packedNumbers": [1, -1], "renamed": ""}
        """#

        let bytes = try codec.encode(json: json, as: Self.everything)

        // scalars (1): empty message; packed_numbers (3): one record, -1 sign-extended to ten bytes; maybe (12): 0.
        let minusOne: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        XCTAssertEqual(bytes, [0x0A, 0x00, 0x1A, 0x0B, 0x01] + minusOne + [0x60, 0x00])
    }

    func testEncodeAcceptsProtoNamesQuotedNumbersAndExponents() throws {
        let json = #"""
        {
          "packed_numbers": ["1e2", 3.0],
          "renamed": "proto name",
          "wrapped_int64": 5,
          "scalars": {"u64": 12, "i64": "1e3", "d": "1.5", "f": "-Infinity", "fx32": "7", "data": "-_8"}
        }
        """#

        let decoded = try Reqling_Test_V1_Everything(serializedBytes: codec.encode(json: json, as: Self.everything))

        XCTAssertEqual(decoded.packedNumbers, [100, 3])
        XCTAssertEqual(decoded.renamed, "proto name")
        XCTAssertEqual(decoded.wrappedInt64.value, 5)
        XCTAssertEqual(decoded.scalars.u64, 12)
        XCTAssertEqual(decoded.scalars.i64, 1000)
        XCTAssertEqual(decoded.scalars.d, 1.5)
        XCTAssertEqual(decoded.scalars.f, -.infinity)
        XCTAssertEqual(decoded.scalars.fx32, 7)
        // URL-safe, unpadded base64.
        XCTAssertEqual(decoded.scalars.data, Data([0xFB, 0xFF]))
    }

    func testNullMeansDefaultExceptForValue() throws {
        let json = #"{"scalars": null, "color": null, "tags": null, "value": null, "list": [null], "attributes": {"gone": null}}"#

        let decoded = try Reqling_Test_V1_Everything(serializedBytes: codec.encode(json: json, as: Self.everything))

        XCTAssertFalse(decoded.hasScalars)
        XCTAssertEqual(decoded.color, .unspecified)
        XCTAssertTrue(decoded.tags.isEmpty)
        XCTAssertEqual(decoded.value.kind, .nullValue(.nullValue))
        XCTAssertEqual(decoded.list.values.map(\.kind), [.nullValue(.nullValue)])
        XCTAssertEqual(decoded.attributes.fields["gone"]?.kind, .nullValue(.nullValue))
    }

    func testFloatingPointSpecialValuesRoundTrip() throws {
        let bytes = try codec.encode(json: #"{"packedDoubles": ["NaN", "Infinity", "-Infinity", -0.0]}"#, as: Self.everything)
        let decoded = try Reqling_Test_V1_Everything(serializedBytes: bytes)

        XCTAssertTrue(decoded.packedDoubles[0].isNaN)
        XCTAssertEqual(Array(decoded.packedDoubles.dropFirst()), [.infinity, -.infinity, -0.0])
        XCTAssertEqual(decoded.packedDoubles[3].sign, .minus)
        try CodecFixtures.assertJSON(
            codec.decode(bytes, as: Self.everything),
            #"{"packedDoubles": ["NaN", "Infinity", "-Infinity", -0]}"#
        )
    }

    func testTopLevelWellKnownTypesWorkWithoutTheirProtoFiles() throws {
        let bare = ProtobufJSONCodec(registry: .empty)

        XCTAssertEqual(try bare.encode(json: "{}", as: "google.protobuf.Empty"), [])
        XCTAssertEqual(try bare.decode([], as: ".google.protobuf.Empty"), "{}")
        XCTAssertEqual(try bare.decode(bare.encode(json: #""1.5s""#, as: "google.protobuf.Duration"), as: "google.protobuf.Duration"), #""1.500s""#)
        try CodecFixtures.assertJSON(
            bare.decode(bare.encode(json: #"{"a": [1, {"b": null}]}"#, as: "google.protobuf.Struct"), as: "google.protobuf.Struct"),
            #"{"a": [1, {"b": null}]}"#
        )
    }

    /// `message` with `unknown` appended to its wire bytes, which SwiftProtobuf parses into its unknown fields.
    private static func adding<Message: SwiftProtobuf.Message>(_ unknown: [UInt8], to message: Message) throws -> Message {
        try Message(serializedBytes: try message.wireBytes() + unknown)
    }
}
