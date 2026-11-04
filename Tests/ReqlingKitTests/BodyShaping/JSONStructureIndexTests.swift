import Foundation
@testable import ReqlingKit
import XCTest

final class JSONStructureIndexTests: XCTestCase {
    func testRecordsContainersInPreOrder() throws {
        let json = #"{"a":[1,{"b":null},[]],"c":{},"d":"]"}"#
        let index = try JSONStructureIndex.build(Data(json.utf8))
        let bytes = Array(json.utf8)

        XCTAssertEqual(index.roots, [0..<bytes.count])
        XCTAssertEqual(index.containerCount, 5)
        XCTAssertEqual(index.starts.map { Character(UnicodeScalar(bytes[Int($0)])) }, ["{", "[", "{", "[", "{"])
        XCTAssertEqual(index.ends.map { Character(UnicodeScalar(bytes[Int($0)])) }, ["}", "]", "}", "]", "}"])
        XCTAssertEqual(index.childCounts, [3, 3, 1, 0, 0])
        XCTAssertEqual(index.subtreeSizes, [5, 3, 1, 1, 1])
        XCTAssertEqual(index.parents, [-1, 0, 1, 1, 0])
    }

    func testAcceptsScalarsWhitespaceAndAByteOrderMark() throws {
        XCTAssertEqual(try JSONStructureIndex.build(Data(" -0.5e+10 ".utf8)).roots, [1..<9])
        XCTAssertEqual(try JSONStructureIndex.build(Data(#""\u00e9\n\"""#.utf8)).containerCount, 0)
        XCTAssertEqual(try JSONStructureIndex.build(Data([0xEF, 0xBB, 0xBF] + Array("[true,false,null]".utf8))).roots, [3..<20])
    }

    func testASequenceHasOneRootPerValue() throws {
        let index = try JSONStructureIndex.build(Data("{\"a\":1}\n[2]\n\"x\"\n".utf8), allowsSequence: true)
        XCTAssertEqual(index.roots, [0..<7, 8..<11, 12..<15])
        XCTAssertThrowsError(try JSONStructureIndex.build(Data("{}\n{}".utf8)))
    }

    func testNestingIsLimitedByMemoryNotTheStack() throws {
        let depth = 200_000
        let json = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        XCTAssertEqual(try JSONStructureIndex.build(Data(json.utf8)).containerCount, depth)
    }

    func testReportsWhereTheTextStopsBeingJSON() {
        let cases = [
            SyntaxCase("[1,]", "Expected a JSON value.", line: 1, column: 4),
            SyntaxCase("{\"a\" 1}", "Expected “:” after a property name.", line: 1, column: 6),
            SyntaxCase("{\n  \"é\": tru}", "Expected a JSON value.", line: 2, column: 8),
            SyntaxCase("[01]", "Expected “,” or “]”.", line: 1, column: 3),
            SyntaxCase("{\"a\":1,}", "Expected a property name in double quotes.", line: 1, column: 8),
            SyntaxCase("[\"a\nb\"]", "A string can't contain a raw control character or line break.", line: 1, column: 4),
            SyntaxCase("[\"unclosed]", "A string is never closed.", line: 1, column: 2),
            SyntaxCase("{\"a\":[1}", "Expected “,” or “]”.", line: 1, column: 8),
            SyntaxCase("[1] x", "Unexpected text after the JSON value.", line: 1, column: 5),
            SyntaxCase("[[1]", "The text ends before every object and array is closed.", line: 1, column: 5),
            SyntaxCase("  ", "Expected a JSON value.", line: 1, column: 3),
            SyntaxCase("[\"\\x\"]", "Unknown escape in a string.", line: 1, column: 4),
            SyntaxCase("[1.]", "Expected a digit after the decimal point.", line: 1, column: 4)
        ]
        for test in cases {
            XCTAssertThrowsError(try JSONStructureIndex.build(Data(test.json.utf8)), test.json) { error in
                XCTAssertEqual(error as? JSONIndexError, .syntax(message: test.message, line: test.line, column: test.column), test.json)
            }
        }
    }

    func testStopsOnceItsTaskIsCancelled() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try JSONStructureIndex.build(Data(("[" + String(repeating: "1,", count: 1 << 20) + "1]").utf8))
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? JSONIndexError, .cancelled)
        }
    }
}

private struct SyntaxCase {
    let json: String
    let message: String
    let line: Int
    let column: Int

    init(_ json: String, _ message: String, line: Int, column: Int) {
        self.json = json
        self.message = message
        self.line = line
        self.column = column
    }
}
