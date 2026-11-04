import Foundation
@testable import ReqlingKit
import SwiftProtobuf
import XCTest

/// Decoding rules that SwiftProtobuf's own serializer never exercises, written as raw bytes.
extension ProtobufJSONCodecTests {
    func testDecodeAcceptsUnpackedAndPackedRepeatedScalars() throws {
        // packed_numbers (3): 1 and 2 unpacked, then 3 and 4 packed; packed_doubles (16): 0.5 unpacked.
        let bytes: [UInt8] = [0x18, 0x01, 0x18, 0x02, 0x1A, 0x02, 0x03, 0x04, 0x81, 0x01] + Self.littleEndian(0.5)

        try CodecFixtures.assertJSON(codec.decode(bytes, as: Self.everything), #"{"packedNumbers": [1, 2, 3, 4], "packedDoubles": [0.5]}"#)
    }

    func testDecodeSkipsUnknownFieldsAndGroups() throws {
        let unknown: [UInt8] = [
            0x98, 0x06, 0x01, // 99: varint
            0xA2, 0x06, 0x02, 0xAB, 0xCD, // 100: length-delimited
            0xAD, 0x06, 0x01, 0x02, 0x03, 0x04, // 101: fixed32
            0xB1, 0x06, 0, 0, 0, 0, 0, 0, 0, 0, // 102: fixed64
            0xBB, 0x06, 0x08, 0x01, 0x13, 0x14, 0xBC, 0x06, // 103: a group holding a varint and an empty nested group
            0x10, 0x09 // color (2) = 9, a number `Color` does not define
        ]
        // Known field `color` (2) arriving as fixed32 is skipped like an unknown field.
        let mismatched: [UInt8] = [0x15, 0x01, 0x00, 0x00, 0x00]

        let decoded = try codec.decodeCountingUnknownFields(unknown + mismatched, as: Self.everything)

        try CodecFixtures.assertJSON(decoded.json, #"{"color": 9}"#)
        XCTAssertEqual(decoded.unknownFieldCount, 6, "Five unknown numbers, plus `color` for the value it could not hold")
    }

    func testDecodeMergesRepeatedMessagesAndKeepsTheLastScalar() throws {
        // scalars (1) twice: {i32: 1, text: "a"} then {text: "b"}; color (2) twice: 1 then 2.
        let bytes: [UInt8] = [0x0A, 0x05, 0x18, 0x01, 0x72, 0x01, 0x61, 0x0A, 0x03, 0x72, 0x01, 0x62, 0x10, 0x01, 0x10, 0x02]

        try CodecFixtures.assertJSON(
            codec.decode(bytes, as: Self.everything),
            #"{"scalars": {"i32": 1, "text": "b"}, "color": "COLOR_GREEN"}"#
        )
    }

    func testDecodeKeepsOnlyTheLastOneofMember() throws {
        // choice_text (9) = "a", choice_scalars (10) = {}, then choice_color (11) = COLOR_RED.
        let bytes: [UInt8] = [0x4A, 0x01, 0x61, 0x52, 0x00, 0x58, 0x01]

        try CodecFixtures.assertJSON(codec.decode(bytes, as: Self.everything), #"{"choiceColor": "COLOR_RED"}"#)
    }

    func testDecodeFillsMissingMapEntryPartsAndLetsLaterKeysWin() throws {
        // counts (6): {} (key "" and value 0), {key "a", value 1}, then {key "a", value 2}; by_id (7): {key 4}.
        let bytes: [UInt8] = [
            0x32, 0x00,
            0x32, 0x05, 0x0A, 0x01, 0x61, 0x10, 0x01,
            0x32, 0x05, 0x0A, 0x01, 0x61, 0x10, 0x02,
            0x3A, 0x02, 0x08, 0x04
        ]

        try CodecFixtures.assertJSON(codec.decode(bytes, as: Self.everything), #"{"counts": {"": 0, "a": 2}, "byId": {"4": {}}}"#)
    }

    func testDecodeWritesUnknownEnumNumbersAsNumbers() throws {
        var message = Reqling_Test_V1_Everything()
        message.color = .UNRECOGNIZED(42)
        message.nested.mood = .UNRECOGNIZED(-3)

        try CodecFixtures.assertJSON(
            codec.decode(message.wireBytes(), as: Self.everything),
            #"{"color": 42, "nested": {"mood": -3}}"#
        )
    }

    func testProto2PresenceAndUnpackedInputFollowTheFilesSyntax() throws {
        let legacy = ProtobufJSONCodec(registry: DescriptorRegistry(files: [
            CodecFixtures.file("legacy", syntax: "proto2", [
                CodecFixtures.message("Legacy", [
                    CodecFixtures.field("count", 1, .int32),
                    CodecFixtures.field("ids", 2, .sint64, label: .repeated)
                ])
            ])
        ]))

        let bytes = try legacy.encode(json: #"{"count": 0, "ids": ["-1", 1]}"#, as: "legacy.Legacy")

        // proto2 `optional` keeps an explicit zero; repeated scalars are still written packed, which parsers accept.
        XCTAssertEqual(bytes, [0x08, 0x00, 0x12, 0x02, 0x01, 0x02])
        try CodecFixtures.assertJSON(legacy.decode(bytes, as: "legacy.Legacy"), #"{"count": 0, "ids": ["-1", "1"]}"#)
        try CodecFixtures.assertJSON(legacy.decode([0x10, 0x01, 0x10, 0x02], as: "legacy.Legacy"), #"{"ids": ["-1", "1"]}"#)
    }

    // The generated oracle is proto3, which has no delimited messages, so these bytes are written out by hand.
    func testEditionsDelimitedMessagesUseTheGroupWireForm() throws {
        var file = CodecFixtures.file("ed", syntax: "editions", [
            CodecFixtures.message("Inner", [CodecFixtures.field("n", 1, .int32)]),
            CodecFixtures.message("Outer", [
                CodecFixtures.field("child", 1, .message, typeName: ".ed.Inner"),
                CodecFixtures.field("kids", 2, .message, label: .repeated, typeName: ".ed.Inner"),
                CodecFixtures.field("plain", 3, .message, typeName: ".ed.Inner"),
                CodecFixtures.field("counts", 4, .message, label: .repeated, typeName: ".ed.Outer.CountsEntry")
            ])
        ])
        file.edition = .edition2023
        file.options.features.messageEncoding = .delimited
        // The field-level feature wins over the file's.
        file.messageType[1].field[2].options.features.messageEncoding = .lengthPrefixed
        // A map entry is always length-prefixed, as is its value.
        var entry = CodecFixtures.message("CountsEntry", [
            CodecFixtures.field("key", 1, .string), CodecFixtures.field("value", 2, .message, typeName: ".ed.Inner")
        ])
        entry.options.mapEntry = true
        file.messageType[1].nestedType = [entry]
        let editions = ProtobufJSONCodec(registry: DescriptorRegistry(files: [file]))
        let json = #"{"child": {"n": 1}, "kids": [{"n": 2}, {}], "plain": {"n": 3}, "counts": {"a": {"n": 4}}}"#

        let bytes = try editions.encode(json: json, as: "ed.Outer")

        XCTAssertEqual(bytes, [
            0x0B, 0x08, 0x01, 0x0C, // child: start group 1, n = 1, end group 1
            0x13, 0x08, 0x02, 0x14, 0x13, 0x14, // kids: two groups
            0x1A, 0x02, 0x08, 0x03, // plain: length-prefixed
            0x22, 0x07, 0x0A, 0x01, 0x61, 0x12, 0x02, 0x08, 0x04 // counts: length-prefixed entry and value
        ])
        try CodecFixtures.assertJSON(editions.decode(bytes, as: "ed.Outer"), json)
        // Two occurrences of a singular group merge (the later `n` wins); a length-prefixed `child` is the wrong wire
        // type and is skipped.
        let merged: [UInt8] = [0x0B, 0x08, 0x01, 0x0C, 0x0A, 0x02, 0x08, 0x07, 0x0B, 0x08, 0x05, 0x0C]
        try CodecFixtures.assertJSON(editions.decode(merged, as: "ed.Outer"), #"{"child": {"n": 5}}"#)
    }

    func testProto2GroupsRoundTrip() throws {
        var legacy = CodecFixtures.message("Legacy", [CodecFixtures.field("item", 1, .group, typeName: ".legacy.Legacy.Item")])
        legacy.nestedType = [CodecFixtures.message("Item", [CodecFixtures.field("n", 2, .int32)])]
        let codec = ProtobufJSONCodec(registry: DescriptorRegistry(files: [CodecFixtures.file("legacy", syntax: "proto2", [legacy])]))

        let bytes = try codec.encode(json: #"{"item": {"n": 5}}"#, as: "legacy.Legacy")

        XCTAssertEqual(bytes, [0x0B, 0x10, 0x05, 0x0C])
        try CodecFixtures.assertJSON(codec.decode(bytes, as: "legacy.Legacy"), #"{"item": {"n": 5}}"#)
        try CodecFixtures.assertJSON(codec.example(for: "legacy.Legacy"), #"{"item": {"n": 0}}"#)
    }

    // SwiftProtobuf shares this bug, so the oracle cannot catch it.
    func testJSONNamesWinOverAnotherFieldsProtoName() throws {
        let codec = ProtobufJSONCodec(registry: DescriptorRegistry(files: [
            CodecFixtures.file("clash", syntax: "proto3", [
                CodecFixtures.message("Clash", [
                    CodecFixtures.field("a", 1, .int32, jsonName: "b"),
                    CodecFixtures.field("b", 2, .int32, jsonName: "c")
                ])
            ])
        ]))

        XCTAssertEqual(try codec.encode(json: #"{"b": 1}"#, as: "clash.Clash"), [0x08, 0x01])
        XCTAssertEqual(try codec.encode(json: #"{"c": 2}"#, as: "clash.Clash"), [0x10, 0x02])
        XCTAssertEqual(try codec.encode(json: #"{"a": 3}"#, as: "clash.Clash"), [0x08, 0x03])
        CodecFixtures.assertCodecError(path: "b", containing: "more than once") {
            try codec.encode(json: #"{"a": 1, "b": 2}"#, as: "clash.Clash")
        }
        try CodecFixtures.assertJSON(codec.decode([0x08, 0x01, 0x10, 0x02], as: "clash.Clash"), #"{"b": 1, "c": 2}"#)
    }

    private static func littleEndian(_ value: Double) -> [UInt8] {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
    }
}
