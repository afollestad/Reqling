import ReqlingKit
import XCTest

final class JSONFormatterTests: XCTestCase {
    func testPreservesKeyOrderNumbersAndEscapes() {
        let pretty = JSONFormatter.pretty(#"{"z":1.50,"a":{"s":"x, \"y\" [z]","n":null},"e":[],"o":{},"l":[1,2]}"#)

        XCTAssertEqual(pretty, """
        {
          "z": 1.50,
          "a": {
            "s": "x, \\"y\\" [z]",
            "n": null
          },
          "e": [],
          "o": {},
          "l": [
            1,
            2
          ]
        }
        """)
    }

    func testReformatsAlreadyIndentedJSONAndRejectsNonJSON() {
        XCTAssertEqual(JSONFormatter.pretty("[\n\n  1 ,   2\n]"), "[\n  1,\n  2\n]")
        XCTAssertNil(JSONFormatter.pretty("hello"))
        XCTAssertNil(JSONFormatter.pretty("42"))
    }

    /// The byte-based printer replaced one that walked `Character`s; for JSON it must print exactly what that did.
    func testMatchesTheCharacterBasedPrinter() throws {
        let corpus = [
            #"{"z":1.50,"a":{"s":"x, \"y\" [z]","n":null},"e":[],"o":{},"l":[1,2]}"#,
            "[\r\n  {\"a\" :\t[ ] , \"b\":{ }}\r\n]",
            #"{"café":"日本語 — “quotes” 👩‍👩‍👧","emoji":["🙂","e\u0301"],"nested":{"x":[[[]]]}}"#,
            #"[-0.5e+10,true,false,null,"\\",{"k":"a\/b"}]"#,
            #"{"unicode-escape":"\u00e9\ud83d\ude00","tab":"\t"}"#,
            "{\n\n\n}",
            "[\"a,b\",\"c:d\",\"{\",\"[\"]"
        ]
        for json in corpus {
            XCTAssertEqual(JSONFormatter.pretty(json), Self.characterPrinter(json), json)
            let bytes = try XCTUnwrap(try JSONFormatter.pretty(Data(json.utf8)))
            XCTAssertEqual(String(bytes: bytes, encoding: .utf8), Self.characterPrinter(json), json)
        }
    }

    func testPutsEachTopLevelValueOnItsOwnLine() {
        XCTAssertEqual(JSONFormatter.pretty("{\"a\":1}\n{\"b\":[]}\n[2]\n"), "{\n  \"a\": 1\n}\n{\n  \"b\": []\n}\n[\n  2\n]")
    }

    func testSkipsAByteOrderMark() throws {
        let data = Data([0xEF, 0xBB, 0xBF] + Array(#"{"a":1}"#.utf8))
        let bytes = try XCTUnwrap(try JSONFormatter.pretty(data))
        XCTAssertEqual(String(bytes: bytes, encoding: .utf8), "{\n  \"a\": 1\n}")
    }

    func testStopsOnceItsTaskIsCancelled() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try JSONFormatter.pretty(Data("[1, 2]".utf8))
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// The printer `JSONFormatter` replaced, kept as the reference its output must match.
    private static func characterPrinter(_ text: String) -> String? {
        let trimmed = text.drop { $0.isWhitespace }
        guard let first = trimmed.first, first == "{" || first == "[" else {
            return nil
        }
        var printer = CharacterPrinter()
        trimmed.forEach { printer.consume($0) }
        return printer.output
    }
}

/// The `Character`-walking printer `JSONFormatter` used to be.
private struct CharacterPrinter {
    private(set) var output = ""
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var pendingNewline = false

    mutating func consume(_ character: Character) {
        if inString {
            consumeInString(character)
            return
        }
        if character.isWhitespace {
            return
        }
        if pendingNewline {
            pendingNewline = false
            if character == "}" || character == "]" {
                depth -= 1
                output.append(character)
                return
            }
            newline()
        }
        switch character {
        case "{", "[":
            output.append(character)
            depth += 1
            pendingNewline = true
        case "}", "]":
            depth -= 1
            newline()
            output.append(character)
        case ",":
            output.append(character)
            newline()
        case ":":
            output.append(": ")
        case "\"":
            inString = true
            output.append(character)
        default:
            output.append(character)
        }
    }

    private mutating func consumeInString(_ character: Character) {
        output.append(character)
        if escaped {
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if character == "\"" {
            inString = false
        }
    }

    private mutating func newline() {
        output.append("\n")
        output.append(String(repeating: "  ", count: max(depth, 0)))
    }
}
