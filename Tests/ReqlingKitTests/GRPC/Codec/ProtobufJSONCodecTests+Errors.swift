import Foundation
@testable import ReqlingKit
import SwiftProtobuf
import XCTest

extension ProtobufJSONCodecTests {
    func testUnknownFieldsAndDuplicatesNameTheirPath() {
        CodecFixtures.assertCodecError(path: "scalars.bogus", containing: "Unknown field of reqling.test.v1.Scalars") {
            try codec.encode(json: #"{"scalars": {"i32": 1, "bogus": 2}}"#, as: Self.everything)
        }
        CodecFixtures.assertCodecError(path: "packed_numbers", containing: "more than once") {
            try codec.encode(json: #"{"packedNumbers": [], "packed_numbers": []}"#, as: Self.everything)
        }
        CodecFixtures.assertCodecError(path: "choiceColor", containing: "`choiceText` already is") {
            try codec.encode(json: #"{"choiceText": "a", "choiceScalars": null, "choiceColor": 1}"#, as: Self.everything)
        }
    }

    func testWrongTypesNameTheirPath() {
        let cases: [CodecErrorCase] = [
            CodecErrorCase(#"{"rows": [{}, {"i32": true}]}"#, "rows[1].i32", "Expected int32 as a number or string, got a boolean"),
            CodecErrorCase(#"{"scalars": {"flag": "true"}}"#, "scalars.flag", "Expected a boolean, got a string"),
            CodecErrorCase(#"{"scalars": {"text": 1}}"#, "scalars.text", "Expected a string, got a number"),
            CodecErrorCase(#"{"scalars": {"data": "not base64!"}}"#, "scalars.data", "Not valid base64"),
            CodecErrorCase(#"{"scalars": {"i64": "12abc"}}"#, "scalars.i64", "is not a number"),
            CodecErrorCase(#"{"scalars": {"d": "1,5"}}"#, "scalars.d", "is not a number"),
            CodecErrorCase(#"{"tags": "a"}"#, "tags", "Expected an array, got a string"),
            CodecErrorCase(#"{"tags": ["a", null]}"#, "tags[1]", "got null"),
            CodecErrorCase(#"{"counts": []}"#, "counts", "Expected an object, got an array"),
            CodecErrorCase(#"{"counts": {"a": "x"}}"#, #"counts["a"]"#, "is not a number"),
            CodecErrorCase(#"{"byId": {"x": {}}}"#, #"byId["x"]"#, "is not a number"),
            CodecErrorCase(#"{"byId": {"1": {"u32": -1}}}"#, #"byId["1"].u32"#, "out of range for uint32"),
            CodecErrorCase(#"{"flags": {"yes": "a"}}"#, #"flags["yes"]"#, "`true` or `false`"),
            CodecErrorCase(
                #"{"nested": {"children": [{}, {"children": [{"mood": "MOOD_ANGRY"}]}]}}"#, "nested.children[1].children[0].mood", "MOOD_ANGRY"
            ),
            CodecErrorCase(#"{"attributes": {"a": {"b": [1, 1e999]}}}"#, #"attributes["a"]["b"][1]"#, "out of range"),
            CodecErrorCase(#"{"scalars": []}"#, "scalars", "Expected an object for reqling.test.v1.Scalars, got an array")
        ]
        for testCase in cases {
            CodecFixtures.assertCodecError(path: testCase.path, containing: testCase.fragment) {
                try codec.encode(json: testCase.json, as: Self.everything)
            }
        }
    }

    func testOutOfRangeAndFractionalNumbersAreRejected() {
        let cases: [(field: String, value: String)] = [
            ("i32", "2147483648"), ("i32", "-2147483649"), ("u32", "4294967296"), ("u32", "-1"), ("i64", #""9223372036854775808""#),
            ("u64", "18446744073709551616"), ("u64", "1e20"), ("f", "3.5e38"), ("d", "1e309")
        ]
        for testCase in cases {
            CodecFixtures.assertCodecError(path: "scalars.\(testCase.field)", containing: "is out of range") {
                try codec.encode(json: #"{"scalars": {"\#(testCase.field)": \#(testCase.value)}}"#, as: Self.everything)
            }
        }
        for (field, value) in [("s32", "1.5"), ("fx64", "1e-1"), ("i64", #""0.5""#)] {
            CodecFixtures.assertCodecError(path: "scalars.\(field)", containing: "is not an integer") {
                try codec.encode(json: #"{"scalars": {"\#(field)": \#(value)}}"#, as: Self.everything)
            }
        }
        CodecFixtures.assertCodecError(path: nil, containing: "Invalid JSON") {
            try codec.encode(json: #"{"scalars": {"i32": 01}}"#, as: Self.everything)
        }
        CodecFixtures.assertCodecError(path: "color", containing: "out of range for enum number") {
            try codec.encode(json: #"{"color": 2147483648}"#, as: Self.everything)
        }
    }

    func testEnumsAcceptNamesOrNumbersAndRejectUnknownNames() throws {
        let decoded = try Reqling_Test_V1_Everything(
            serializedBytes: codec.encode(json: #"{"color": 1, "colors": ["COLOR_GREEN", 7]}"#, as: Self.everything)
        )
        XCTAssertEqual(decoded.color, .red)
        XCTAssertEqual(decoded.colors, [.green, .UNRECOGNIZED(7)])

        CodecFixtures.assertCodecError(path: "color", containing: "`COLOR_PURPLE` is not a value of reqling.test.v1.Color") {
            try codec.encode(json: #"{"color": "COLOR_PURPLE"}"#, as: Self.everything)
        }
        CodecFixtures.assertCodecError(path: "colors[0]", containing: "an enum name or number") {
            try codec.encode(json: #"{"colors": [true]}"#, as: Self.everything)
        }
    }

    func testInvalidJSONReportsLineAndColumn() {
        CodecFixtures.assertCodecError(path: nil, containing: "line 2, column 16: expected `,`") {
            try codec.encode(json: "{\n  \"tags\": [\"é\" \"b\"]\n}", as: Self.everything)
        }
        let malformed = [
            "", "{", "{\"a\" 1}", "[1,]", "{\"a\": 1,}", "\"\\x\"", "\"\\ud800\"", "tru", "1 2", "{\"a\": .5}", "\"tab\there\""
        ]
        for json in malformed {
            CodecFixtures.assertCodecError(path: nil, containing: "Invalid JSON") {
                try codec.encode(json: json, as: Self.everything)
            }
        }
        let tooDeep = String(repeating: "[", count: 101) + String(repeating: "]", count: 101)
        CodecFixtures.assertCodecError(path: nil, containing: "nesting deeper than 100") {
            try codec.encode(json: #"{"list": \#(tooDeep)}"#, as: Self.everything)
        }
    }

    func testUnknownMessageTypesAndMalformedBytesThrow() {
        CodecFixtures.assertCodecError(path: nil, containing: "`nope.Message` is not defined") {
            try codec.encode(json: "{}", as: "nope.Message")
        }
        CodecFixtures.assertCodecError(path: nil, containing: "`nope.Message` is not defined") {
            try codec.decode([], as: "nope.Message")
        }
        let malformed: [(bytes: [UInt8], fragment: String)] = [
            ([0x08], "truncated varint"),
            ([0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01], "longer than 10 bytes"),
            ([0x0A, 0x05, 0x01], "runs past the end"),
            ([0x09, 0x01, 0x02], "truncated fixed-width"),
            ([0x0F], "unknown wire type 7"),
            ([0x00], "invalid field number 0"),
            ([0x0C], "end-group tag without a matching start"),
            ([0x0B, 0x08, 0x01], "never closed"),
            ([0x0B, 0x14], "ends with the tag of group 2")
        ]
        for testCase in malformed {
            CodecFixtures.assertCodecError(path: nil, containing: testCase.fragment) {
                try codec.decode(testCase.bytes, as: Self.everything)
            }
        }
    }

    func testDecodeRejectsInvalidUTF8AtItsPath() {
        // rows (5) holding one Scalars whose text (14) is the lone byte 0xFF.
        let bytes: [UInt8] = [0x2A, 0x03, 0x72, 0x01, 0xFF]

        CodecFixtures.assertCodecError(path: "rows[0].text", containing: "invalid UTF-8") {
            try codec.decode(bytes, as: Self.everything)
        }
    }

    func testDeepMessageNestingIsBounded() throws {
        // Each Struct level is two messages deep (Struct, then Value), so 60 JSON levels pass 100 messages.
        let deepStruct = String(repeating: #"{"a": "#, count: 60) + "1" + String(repeating: "}", count: 60)
        XCTAssertThrowsError(try codec.encode(json: #"{"value": \#(deepStruct)}"#, as: Self.everything)) { error in
            XCTAssertEqual((error as? GRPCCodecError)?.message, "Messages are nested more than 100 levels deep")
        }

        var nested = Reqling_Test_V1_Everything.Nested()
        for _ in 0..<150 {
            var parent = Reqling_Test_V1_Everything.Nested()
            parent.children = [nested]
            nested = parent
        }
        XCTAssertThrowsError(try codec.decode(nested.wireBytes(), as: "reqling.test.v1.Everything.Nested")) { error in
            XCTAssertEqual((error as? GRPCCodecError)?.message, "Messages are nested more than 100 levels deep")
        }
    }

    /// An `Any` holding an `Any` reaches the well-known-type path directly, which once skipped the depth check and
    /// let a hostile server overflow the stack.
    func testNestedAnysAreDepthBounded() throws {
        let anyURL = "type.googleapis.com/google.protobuf.Any"
        func nestedAny(levels: Int) -> [UInt8] {
            var payload: [UInt8] = []
            var typeURL = "type.googleapis.com/google.protobuf.Int32Value"
            for _ in 0..<levels {
                var writer = WireWriter()
                writer.write(.lengthDelimited(ArraySlice(typeURL.utf8)), number: 1)
                writer.write(.lengthDelimited(payload[...]), number: 2)
                payload = writer.bytes
                typeURL = anyURL
            }
            return payload
        }

        XCTAssertTrue(try codec.decode(nestedAny(levels: 50), as: "google.protobuf.Any").contains("Int32Value"))
        XCTAssertThrowsError(try codec.decode(nestedAny(levels: 1000), as: "google.protobuf.Any")) { error in
            XCTAssertEqual((error as? GRPCCodecError)?.message, "Messages are nested more than 100 levels deep")
        }

        // The JSON parser caps nesting first, so build the deep value directly to reach the encoder's own check.
        var json = OrderedJSON.object([])
        for _ in 0..<150 {
            json = .object([OrderedJSONMember(key: "@type", value: .string(anyURL)), OrderedJSONMember(key: "value", value: json)])
        }
        XCTAssertThrowsError(try codec.encodeMessage(json, typeName: "google.protobuf.Any", depth: 0)) { error in
            XCTAssertEqual((error as? GRPCCodecError)?.message, "Messages are nested more than 100 levels deep")
        }
    }
}
