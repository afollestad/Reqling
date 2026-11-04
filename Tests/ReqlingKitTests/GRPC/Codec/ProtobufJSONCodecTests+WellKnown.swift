import Foundation
@testable import ReqlingKit
import SwiftProtobuf
import XCTest

extension ProtobufJSONCodecTests {
    func testTimestampEncodesLikeSwiftProtobuf() throws {
        let inputs = [
            "1970-01-01T00:00:00Z", "2024-02-29T12:34:56.789Z", "2024-01-01T01:00:00+01:00", "1969-12-31T23:59:59.5-00:30",
            "0001-01-01T00:00:00Z", "9999-12-31T23:59:59.999999999Z", "2000-02-29T00:00:00.123456Z"
        ]
        for input in inputs {
            let bytes = try codec.encode(json: "\"\(input)\"", as: "google.protobuf.Timestamp")
            XCTAssertEqual(
                try Google_Protobuf_Timestamp(serializedBytes: bytes),
                try Google_Protobuf_Timestamp(jsonString: "\"\(input)\""),
                input
            )
        }
    }

    func testTimestampDecodesToUTCWithZeroThreeSixOrNineDigits() throws {
        let goldens: [(Google_Protobuf_Timestamp, String)] = [
            (.init(seconds: 0, nanos: 0), "1970-01-01T00:00:00Z"),
            (.init(seconds: 0, nanos: 10_000_000), "1970-01-01T00:00:00.010Z"),
            (.init(seconds: 1, nanos: 1000), "1970-01-01T00:00:01.000001Z"),
            (.init(seconds: -1, nanos: 999_999_999), "1969-12-31T23:59:59.999999999Z"),
            (.init(seconds: 951_782_400, nanos: 0), "2000-02-29T00:00:00Z"),
            (.init(seconds: -62_135_596_800, nanos: 0), "0001-01-01T00:00:00Z"),
            (.init(seconds: 253_402_300_799, nanos: 999_999_999), "9999-12-31T23:59:59.999999999Z")
        ]
        for (timestamp, golden) in goldens {
            XCTAssertEqual(try codec.decode(timestamp.wireBytes(), as: "google.protobuf.Timestamp"), "\"\(golden)\"")
        }
        let outOfRange = Google_Protobuf_Timestamp(seconds: 253_402_300_800, nanos: 0)
        CodecFixtures.assertCodecError(path: nil, containing: "outside the valid range") {
            try codec.decode(outOfRange.wireBytes(), as: "google.protobuf.Timestamp")
        }
    }

    func testTimestampRejectsMalformedAndOutOfRangeText() {
        let inputs = [
            "1970-01-01T00:00:00z", "1970-01-01t00:00:00Z", "1970-01-01 00:00:00Z", "1970-01-01T00:00:00", "1970-02-30T00:00:00Z",
            "1970-01-01T24:00:00Z", "10000-01-01T00:00:00Z", "0000-12-31T00:00:00Z", "1970-01-01T00:00:00.Z",
            "1970-01-01T00:00:00.1234567890Z", "1970-01-01T00:00:00+0100", "0001-01-01T00:00:00+00:01"
        ]
        for input in inputs {
            CodecFixtures.assertCodecError(path: "at", containing: input) {
                try codec.encode(json: #"{"at": "\#(input)"}"#, as: Self.everything)
            }
        }
    }

    func testDurationEncodesLikeSwiftProtobufAndDecodesCanonically() throws {
        for input in ["1.5s", "-0.5s", "0s", "315576000000s", "-315576000000.999999999s", "0.000000001s", "1.010s"] {
            let bytes = try codec.encode(json: "\"\(input)\"", as: "google.protobuf.Duration")
            XCTAssertEqual(try Google_Protobuf_Duration(serializedBytes: bytes), try Google_Protobuf_Duration(jsonString: "\"\(input)\""), input)
        }
        let goldens: [(Google_Protobuf_Duration, String)] = [
            (.init(seconds: 1, nanos: 500_000_000), "1.500s"), (.init(seconds: 0, nanos: -500_000_000), "-0.500s"),
            (.init(seconds: 0, nanos: 0), "0s"), (.init(seconds: -1, nanos: -1), "-1.000000001s"), (.init(seconds: 3, nanos: 1000), "3.000001s")
        ]
        for (duration, golden) in goldens {
            XCTAssertEqual(try codec.decode(duration.wireBytes(), as: "google.protobuf.Duration"), "\"\(golden)\"")
        }
    }

    func testDurationRejectsMalformedMixedSignAndOutOfRangeValues() {
        for input in ["1.5", "1.5S", "+1s", ".5s", "1.s", "1.0000000001s", "315576000001s", "- 1s"] {
            CodecFixtures.assertCodecError(path: "elapsed", containing: input) {
                try codec.encode(json: #"{"elapsed": "\#(input)"}"#, as: Self.everything)
            }
        }
        let mixedSigns = Google_Protobuf_Duration(seconds: 1, nanos: -1)
        CodecFixtures.assertCodecError(path: nil, containing: "outside the valid range") {
            try codec.decode(mixedSigns.wireBytes(), as: "google.protobuf.Duration")
        }
    }

    func testFieldMaskUsesCamelCasePathsJoinedByCommas() throws {
        let mask = try Google_Protobuf_FieldMask(serializedBytes: codec.encode(json: #""user.displayName,photo""#, as: "google.protobuf.FieldMask"))
        XCTAssertEqual(mask.paths, ["user.display_name", "photo"])
        XCTAssertEqual(try codec.encode(json: #""""#, as: "google.protobuf.FieldMask"), [])

        let decoded = Google_Protobuf_FieldMask(protoPaths: ["foo_bar.baz_qux2", "x"])
        XCTAssertEqual(try codec.decode(decoded.wireBytes(), as: "google.protobuf.FieldMask"), #""fooBar.bazQux2,x""#)

        for input in ["user_name", "a,,b", "a b"] {
            CodecFixtures.assertCodecError(path: "mask", containing: "field mask") {
                try codec.encode(json: #"{"mask": "\#(input)"}"#, as: Self.everything)
            }
        }
        for path in ["fooBar", "foo__bar", "foo_1", "trailing_"] {
            let unrepresentable = Google_Protobuf_FieldMask(protoPaths: [path])
            CodecFixtures.assertCodecError(path: nil, containing: "no lowerCamelCase form") {
                try codec.decode(unrepresentable.wireBytes(), as: "google.protobuf.FieldMask")
            }
        }
    }

    func testStructValueAndListValueArePlainJSON() throws {
        let json = #"""
        {
          "attributes": {"name": "Ada", "scores": [1, 2.5, -0.25], "meta": {"ok": true, "none": null}, "empty": {}},
          "value": {"nested": [[], {}, "x"]},
          "list": ["a", 1, false, null, [{"deep": [null]}]]
        }
        """#

        let bytes = try codec.encode(json: json, as: Self.everything)

        XCTAssertEqual(try Reqling_Test_V1_Everything(serializedBytes: bytes), try Reqling_Test_V1_Everything(jsonString: json))
        // Struct keys keep their wire order, which this codec wrote in input order.
        try CodecFixtures.assertJSON(codec.decode(bytes, as: Self.everything), json)
        for scalar in ["1", "\"s\"", "true", "null"] {
            XCTAssertEqual(try codec.decode(codec.encode(json: scalar, as: "google.protobuf.Value"), as: "google.protobuf.Value"), scalar)
        }
    }

    func testValueRejectsNumbersJSONCannotHold() {
        CodecFixtures.assertCodecError(path: "value", containing: "out of range") {
            try codec.encode(json: #"{"value": 1e999}"#, as: Self.everything)
        }
        let nan = Google_Protobuf_Value(numberValue: .nan)
        CodecFixtures.assertCodecError(path: nil, containing: "NaN") {
            try codec.decode(nan.wireBytes(), as: "google.protobuf.Value")
        }
    }

    func testWrappersAreBareValuesAndEmptyIsAnEmptyObject() throws {
        var message = Reqling_Test_V1_Everything()
        message.wrappedInt64 = Google_Protobuf_Int64Value(-12)
        message.wrappedString = Google_Protobuf_StringValue("s")
        message.wrappedBool = Google_Protobuf_BoolValue(false)
        message.wrappedBytes = Google_Protobuf_BytesValue(Data([1]))
        message.wrappedDouble = Google_Protobuf_DoubleValue(0.5)
        message.nothing = Google_Protobuf_Empty()
        message.wrappedFloat = Google_Protobuf_FloatValue(1.25)
        message.wrappedInt32 = Google_Protobuf_Int32Value(-7)
        message.wrappedUint32 = Google_Protobuf_UInt32Value(7)
        message.wrappedUint64 = Google_Protobuf_UInt64Value(.max)

        let json = try codec.decode(message.wireBytes(), as: Self.everything)

        try CodecFixtures.assertJSON(json, #"""
        {
          "wrappedInt64": "-12", "wrappedString": "s", "wrappedBool": false, "wrappedBytes": "AQ==", "wrappedDouble": 0.5,
          "nothing": {}, "wrappedFloat": 1.25, "wrappedInt32": -7, "wrappedUint32": 7, "wrappedUint64": "18446744073709551615"
        }
        """#)
        XCTAssertEqual(try Reqling_Test_V1_Everything(serializedBytes: codec.encode(json: json, as: Self.everything)), message)
    }

    func testAnyHoldsMessageFieldsOrAWellKnownValue() throws {
        let scalars = Reqling_Test_V1_Scalars.with {
            $0.i32 = 5
            $0.text = "inside"
        }
        let cases: [(any SwiftProtobuf.Message, String)] = [
            (scalars, #"{"@type": "type.googleapis.com/reqling.test.v1.Scalars", "i32": 5, "text": "inside"}"#),
            (
                Google_Protobuf_Duration(seconds: 1, nanos: 500_000_000),
                #"{"@type": "type.googleapis.com/google.protobuf.Duration", "value": "1.500s"}"#
            ),
            (Google_Protobuf_Empty(), #"{"@type": "type.googleapis.com/google.protobuf.Empty"}"#),
            (Google_Protobuf_Any(), #"{}"#)
        ]
        for (payload, golden) in cases {
            var message = Reqling_Test_V1_Everything()
            message.extra = try payload is Google_Protobuf_Any ? Google_Protobuf_Any() : Google_Protobuf_Any(message: payload)

            let json = try codec.decode(message.wireBytes(), as: Self.everything)
            try CodecFixtures.assertJSON(json, #"{"extra": \#(golden)}"#)

            let reencoded = try Reqling_Test_V1_Everything(serializedBytes: codec.encode(json: json, as: Self.everything))
            try CodecFixtures.assertAnysEqual([reencoded.extra], [message.extra])
        }
    }

    func testAnyAcceptsAnEmptyPayloadInEitherForm() throws {
        for json in [#"{"@type": "x/google.protobuf.Empty"}"#, #"{"@type": "x/google.protobuf.Empty", "value": {}}"#] {
            let decoded = try Reqling_Test_V1_Everything(serializedBytes: codec.encode(json: #"{"extra": \#(json)}"#, as: Self.everything))
            XCTAssertEqual(decoded.extra.typeURL, "x/google.protobuf.Empty")
            XCTAssertTrue(decoded.extra.value.isEmpty)
        }
    }

    func testAnyResolvesTheTypeURLsLastSegment() throws {
        let json = #"{"extra": {"@type": "example.com/schemas/reqling.test.v1.Scalars", "flag": true}}"#

        let decoded = try Reqling_Test_V1_Everything(serializedBytes: codec.encode(json: json, as: Self.everything))

        XCTAssertEqual(decoded.extra.typeURL, "example.com/schemas/reqling.test.v1.Scalars")
        XCTAssertEqual(try Reqling_Test_V1_Scalars(serializedBytes: decoded.extra.value).flag, true)
        try CodecFixtures.assertJSON(codec.decode(decoded.wireBytes(), as: Self.everything), json)
    }

    func testAnyNamesMissingAndMalformedTypes() throws {
        let missing = #"{"extra": {"@type": "type.googleapis.com/nope.Missing", "a": 1}}"#
        CodecFixtures.assertCodecError(path: "extra.@type", containing: "`nope.Missing` is not defined in the loaded schema") {
            try codec.encode(json: missing, as: Self.everything)
        }
        var message = Reqling_Test_V1_Everything()
        message.extra = Google_Protobuf_Any()
        message.extra.typeURL = "type.googleapis.com/nope.Missing"
        message.extra.value = Data([0x08, 0x01])
        CodecFixtures.assertCodecError(path: "extra.@type", containing: "`nope.Missing` is not defined in the loaded schema") {
            try codec.decode(message.wireBytes(), as: Self.everything)
        }
        CodecFixtures.assertCodecError(path: "extras[0].@type", containing: "not a type URL") {
            try codec.encode(json: #"{"extras": [{"@type": "reqling.test.v1.Scalars"}]}"#, as: Self.everything)
        }
        CodecFixtures.assertCodecError(path: "extra", containing: "needs an `@type`") {
            try codec.encode(json: #"{"extra": {"i32": 1}}"#, as: Self.everything)
        }
        CodecFixtures.assertCodecError(path: "extra", containing: "takes its JSON form in `value`") {
            try codec.encode(json: #"{"extra": {"@type": "x/google.protobuf.Duration", "value": "1s", "more": 1}}"#, as: Self.everything)
        }
        CodecFixtures.assertCodecError(path: "extra.value", containing: "duration") {
            try codec.encode(json: #"{"extra": {"@type": "x/google.protobuf.Duration", "value": 1}}"#, as: Self.everything)
        }
    }
}
