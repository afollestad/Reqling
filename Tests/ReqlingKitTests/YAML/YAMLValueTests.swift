import Foundation
import ReqlingYAML
import XCTest

/// YAML read into JSON's model: order, YAML 1.2 typing, merge keys, limits, and errors.
final class YAMLValueTests: XCTestCase {
    private func parse(_ text: String) throws -> YAMLValue {
        try YAML.parse(text)
    }

    func testMappingsKeepTheirOrderAndKeysTheirText() throws {
        let value = try parse("""
        zeta: 1
        alpha: 2
        200: ok
        [a, b]: list key
        """)

        guard case .object(let members) = value else {
            return XCTFail("a mapping")
        }
        XCTAssertEqual(members.map(\.key), ["zeta", "alpha", "200", #"["a","b"]"#])
        XCTAssertEqual(value["200"], .string("ok"))
    }

    func testPlainScalarsAreTypedByYAML12NotYAML11() throws {
        let value = try parse("""
        - yes
        - on
        - NO
        - true
        - FALSE
        - ~
        -
        - null
        - 012
        - +1
        - 1.10
        - .5
        - 2.
        - -1.5e+3
        - 0x1F
        - 0o17
        - 1_000
        - 12345678901234567890
        - .inf
        - 2024-01-01
        - "123"
        - !!str 123
        - !!int "42"
        - 'quoted: yes'
        """)

        XCTAssertEqual(value, .array([
            .string("yes"), .string("on"), .string("NO"), .bool(true), .bool(false), .null, .null, .null,
            .number("12"), .number("1"), .number("1.10"), .number("0.5"), .number("2"), .number("-1.5e3"),
            .number("31"), .number("15"), .string("1_000"), .number("12345678901234567890"), .string(".inf"),
            .string("2024-01-01"), .string("123"), .string("123"), .number("42"), .string("quoted: yes")
        ]))
    }

    func testMergeKeysSpliceInWithTheMappingsOwnKeysWinning() throws {
        let value = try parse("""
        base: &base {a: 1, b: 2}
        more: &more {b: 3, c: 4}
        child:
          b: own
          <<: [*base, *more]
          d: 5
        literal:
          "<<": kept
        """)

        XCTAssertEqual(value["child"], .object([
            YAMLMember(key: "b", value: .string("own")),
            YAMLMember(key: "a", value: .number("1")),
            YAMLMember(key: "c", value: .number("4")),
            YAMLMember(key: "d", value: .number("5"))
        ]))
        XCTAssertEqual(value["literal"], .object([YAMLMember(key: "<<", value: .string("kept"))]), "A quoted << is a key")
    }

    func testAnAliasBombStopsAtTheBudget() {
        var text = "a: &a [x, x, x, x, x, x, x, x, x, x]\n"
        for level in 1...9 {
            let items = Array(repeating: "*\(level == 1 ? "a" : "l\(level - 1)")", count: 10).joined(separator: ", ")
            text += "l\(level): &l\(level) [\(items)]\n"
        }

        XCTAssertThrowsError(try YAML.parse(text)) { error in
            XCTAssertEqual(error as? YAMLError, .tooLarge)
        }
    }

    func testErrorsSayWhere() {
        XCTAssertThrowsError(try parse("a: 1\nb: [2\nc: 3")) { error in
            let error = error as? YAMLError
            XCTAssertNotNil(error?.line)
            XCTAssertEqual(error?.errorDescription?.hasPrefix("Line "), true)
        }
        XCTAssertThrowsError(try parse("a: 1\na: 2")) { error in
            XCTAssertEqual((error as? YAMLError)?.message, "A mapping repeats the key “a”.")
        }
        XCTAssertThrowsError(try parse("a: 1\n---\nb: 2"), "One document was expected")
        XCTAssertThrowsError(try YAML.parse(Data([0xFF, 0xFE, 0x00])))
    }

    func testJSONReadsAsJSONMeansIt() throws {
        let value = try YAML.parse(Data(#"{"name": "Ada 😀", "id": 007, "tags": [], "nested": {"ok": null}}"#.utf8))

        XCTAssertEqual(value.jsonText(), #"{"name":"Ada 😀","id":7,"tags":[],"nested":{"ok":null}}"#)
    }

    func testStreamsReadEachDocument() throws {
        XCTAssertEqual(try YAML.parseAll("a: 1\n---\n- 2\n"), [.object([YAMLMember(key: "a", value: .number("1"))]), .array([.number("2")])])
        XCTAssertEqual(try YAML.parse(""), .null)
    }

    func testEmittingQuotesWhatWouldReadBackAsSomethingElse() throws {
        let value = YAMLValue.object([
            YAMLMember(key: "yes", value: .string("no")),
            YAMLMember(key: "version", value: .string("1.0")),
            YAMLMember(key: "count", value: .number("3")),
            YAMLMember(key: "empty", value: .string("")),
            YAMLMember(key: "date", value: .string("2024-01-01")),
            YAMLMember(key: "note", value: .string("line one\nline two")),
            YAMLMember(key: "list", value: .array([.bool(true), .null, .string("plain text")])),
            YAMLMember(key: "nested", value: .object([YAMLMember(key: "a: b", value: .string("#hash"))]))
        ])

        let text = value.yamlText()

        XCTAssertEqual(try YAML.parse(text), value, text)
        XCTAssertTrue(text.contains("count: 3\n"), text)
        XCTAssertTrue(text.contains("- plain text\n"), text)
        XCTAssertTrue(text.contains("note: |"), text)
        XCTAssertFalse(text.contains("!!"), text)
    }

    func testAStreamEmitsEachDocumentAfterAMarker() throws {
        let documents: [YAMLValue] = [.object([YAMLMember(key: "a", value: .number("1"))]), .array([.number("2")])]

        let text = YAML.text(documents)

        XCTAssertEqual(try YAML.parseAll(text), documents)
        XCTAssertTrue(text.hasPrefix("---"), text)
    }
}
