import Foundation
@testable import ReqlingKit
import SwiftProtobuf
import XCTest

/// The codec fixture's descriptor set, a JSON message exercising every field shape, and comparisons that see through
/// SwiftProtobuf's representation-sensitive `Any` equality.
enum CodecFixtures {
    static func registry() throws -> DescriptorRegistry {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "codec_test", withExtension: "binpb", subdirectory: "Fixtures"))
        return try DescriptorRegistry(descriptorSet: Data(contentsOf: url))
    }

    /// Every scalar at an extreme, escapes and a surrogate pair, packed and repeated values, all three map key types,
    /// a oneof message member, proto3 `optional` at zero, recursion, `json_name`, and every well-known type. NaN is
    /// left out because it would make message equality fail; `testFloatingPointSpecialValuesRoundTrip` covers it.
    static let richEverythingJSON = #"""
    {
      "scalars": {
        "d": 1.5, "f": -2.25, "i32": -42, "i64": "-9223372036854775808", "u32": 4294967295,
        "u64": "18446744073709551615", "s32": -2147483648, "s64": "9223372036854775807", "fx32": 4294967295,
        "fx64": "18446744073709551615", "sfx32": -2147483648, "sfx64": "-9223372036854775808", "flag": true,
        "text": "héllo \"wörld\"\n😀 / \\", "data": "AAEC/w=="
      },
      "color": "COLOR_GREEN",
      "packedNumbers": [1, -1, 2147483647, -2147483648, 0],
      "tags": ["a", "", "c"],
      "rows": [{"i32": 1}, {}, {"text": "x", "s64": "-3"}],
      "counts": {"a": 1, "b": -2, "": 0},
      "byId": {"-5": {"flag": true}, "9223372036854775807": {}},
      "flags": {"true": "yes", "false": "no"},
      "choiceScalars": {"u64": "7"},
      "maybe": 0,
      "nested": {"mood": "MOOD_CALM", "children": [{"children": [{"mood": 1}]}, {}]},
      "customName": "renamed",
      "colors": ["COLOR_RED", 2, "COLOR_UNSPECIFIED"],
      "packedDoubles": [0.1, -0.0, "Infinity", "-Infinity", 1e300, 5e-324],
      "at": "2024-02-29T12:34:56.789+02:00",
      "elapsed": "-1.000000001s",
      "mask": "user.displayName,photo",
      "attributes": {"name": "Ada", "age": 36, "tags": ["x", null, true], "nested": {"deep": {}}},
      "value": [1, "two", {"three": 3}],
      "list": [null, false, 2.5],
      "wrappedInt64": "-12",
      "wrappedString": "",
      "wrappedBool": false,
      "wrappedBytes": "AQ==",
      "wrappedDouble": 0,
      "nothing": {},
      "extra": {"@type": "type.googleapis.com/reqling.test.v1.Scalars", "i32": 5, "text": "inside"},
      "wrappedFloat": 1.25,
      "wrappedInt32": -7,
      "wrappedUint32": 7,
      "wrappedUint64": "18446744073709551615",
      "colorById": {"1": "COLOR_RED", "4000000000": "COLOR_GREEN", "9": 9},
      "extras": [
        {"@type": "type.googleapis.com/google.protobuf.Duration", "value": "3s"},
        {"@type": "type.googleapis.com/google.protobuf.Struct", "value": {"k": "v", "n": [1]}},
        {"@type": "type.googleapis.com/google.protobuf.Any", "value": {"@type": "type.googleapis.com/google.protobuf.Int32Value", "value": 3}},
        {"@type": "type.googleapis.com/reqling.test.v1.Everything.Nested", "mood": "MOOD_CALM", "children": [{}]},
        {"@type": "type.googleapis.com/google.protobuf.Empty"},
        {}
      ]
    }
    """#

    /// Compares everything but the `Any` fields with `==`, and those by unpacking them: SwiftProtobuf calls an `Any`
    /// parsed from JSON unequal to the same `Any` parsed from binary.
    static func assertEquivalent(
        _ actual: Reqling_Test_V1_Everything,
        _ expected: Reqling_Test_V1_Everything,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(withoutAnys(actual), withoutAnys(expected), file: file, line: line)
        XCTAssertEqual(actual.hasExtra, expected.hasExtra, file: file, line: line)
        try assertAnysEqual([actual.extra] + actual.extras, [expected.extra] + expected.extras, file: file, line: line)
    }

    private static func withoutAnys(_ message: Reqling_Test_V1_Everything) -> Reqling_Test_V1_Everything {
        var rest = message
        rest.clearExtra()
        rest.extras = []
        return rest
    }

    static func assertAnysEqual(
        _ actual: [Google_Protobuf_Any],
        _ expected: [Google_Protobuf_Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualAny, expectedAny) in zip(actual, expected) {
            XCTAssertEqual(actualAny.typeURL, expectedAny.typeURL, file: file, line: line)
            guard !expectedAny.typeURL.isEmpty else {
                XCTAssertTrue(actualAny.value.isEmpty, file: file, line: line)
                continue
            }
            let type = try XCTUnwrap(Google_Protobuf_Any.messageType(forTypeURL: expectedAny.typeURL), file: file, line: line)
            let actualMessage = try type.init(serializedBytes: actualAny.value)
            let expectedMessage = try type.init(serializedBytes: expectedAny.value)
            XCTAssertTrue(
                actualMessage.isEqualTo(message: expectedMessage),
                "\(actualMessage) is not \(expectedMessage)",
                file: file,
                line: line
            )
        }
    }

    /// A hand-built field, for schemas the generated fixture cannot express (proto2, editions, name clashes).
    static func field(
        _ name: String,
        _ number: Int32,
        _ type: Google_Protobuf_FieldDescriptorProto.TypeEnum,
        label: Google_Protobuf_FieldDescriptorProto.Label = .optional,
        typeName: String = "",
        jsonName: String? = nil
    ) -> Google_Protobuf_FieldDescriptorProto {
        Google_Protobuf_FieldDescriptorProto.with {
            $0.name = name
            $0.number = number
            $0.type = type
            $0.label = label
            $0.typeName = typeName
            if let jsonName {
                $0.jsonName = jsonName
            }
        }
    }

    static func message(_ name: String, _ fields: [Google_Protobuf_FieldDescriptorProto]) -> Google_Protobuf_DescriptorProto {
        Google_Protobuf_DescriptorProto.with {
            $0.name = name
            $0.field = fields
        }
    }

    static func file(
        _ package: String,
        syntax: String,
        _ messages: [Google_Protobuf_DescriptorProto]
    ) -> Google_Protobuf_FileDescriptorProto {
        Google_Protobuf_FileDescriptorProto.with {
            $0.name = "\(package).proto"
            $0.package = package
            $0.syntax = syntax
            $0.messageType = messages
        }
    }

    /// Compares JSON structurally, member order included, so goldens can be written compactly.
    static func assertJSON(_ actual: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try ProtoJSONParser.parse(actual), try ProtoJSONParser.parse(expected), file: file, line: line)
    }

    /// Asserts `body` throws a `GRPCCodecError` at `path` whose message contains `fragment`.
    static func assertCodecError<Result>(
        path: String?,
        containing fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Result
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let codecError = error as? GRPCCodecError else {
                return XCTFail("Expected a GRPCCodecError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(codecError.path, path, file: file, line: line)
            XCTAssertTrue(
                codecError.message.contains(fragment),
                "`\(codecError.message)` does not contain `\(fragment)`",
                file: file,
                line: line
            )
        }
    }
}

/// One encode input and the error it should raise.
struct CodecErrorCase {
    let json: String
    let path: String?
    let fragment: String

    init(_ json: String, _ path: String?, _ fragment: String) {
        self.json = json
        self.path = path
        self.fragment = fragment
    }
}

extension SwiftProtobuf.Message {
    /// The message's wire bytes as the codec takes them.
    func wireBytes() throws -> [UInt8] {
        try serializedBytes()
    }
}
