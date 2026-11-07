import Foundation
@testable import ReqlingKit
import XCTest

/// Data files for folder and project runs: CSV and JSON rows as text.
final class IterationDataTests: XCTestCase {
    private func csv(_ text: String) throws(IterationDataError) -> [[String: String]] {
        try IterationData.parse(Data(text.utf8), fileExtension: "csv")
    }

    private func json(_ text: String) throws(IterationDataError) -> [[String: String]] {
        try IterationData.parse(Data(text.utf8), fileExtension: "JSON")
    }

    private func error(_ parse: () throws -> [[String: String]]) -> String? {
        do {
            _ = try parse()
            return nil
        } catch {
            return (error as? IterationDataError)?.message ?? "\(error)"
        }
    }

    func testCSVReadsQuotedValuesAcrossLinesAndSkipsBlankOnes() throws {
        let text = "\u{FEFF}email, name ,note\r\n"
            + "ada@acme.dev,\"Lovelace, Ada\",\"says \"\"hi\"\"\"\r\n\r\n"
            + "grace@acme.dev,Grace,\"two\nlines\"\nshort\n"
        let rows = try csv(text)

        XCTAssertEqual(rows, [
            ["email": "ada@acme.dev", "name": "Lovelace, Ada", "note": #"says "hi""#],
            ["email": "grace@acme.dev", "name": "Grace", "note": "two\nlines"],
            ["email": "short"]
        ], "A BOM and spaces around a column name are dropped; a short row leaves its last columns out")
    }

    func testCSVRefusesWhatItCantReadSayingWhere() {
        XCTAssertEqual(error { try csv("a,b\n1,2,3\n") }, "Line 2 of the CSV has 3 values, but the header names 2.")
        XCTAssertEqual(error { try csv("a,a\n1,2\n") }, "The CSV's header row names “a” twice.")
        XCTAssertEqual(error { try csv("a,,b\n1,2,3\n") }, "The CSV's header row has an empty column name.")
        XCTAssertEqual(error { try csv("a\n\"open\n") }, "A quoted value on line 2 of the CSV never closes.")
        XCTAssertEqual(error { try csv("a,b\n") }, "The data has no rows.")
    }

    func testJSONTurnsEveryValueIntoText() throws {
        let rows = try json(#"[{"id": 7, "price": 1.5, "active": true, "tags": ["a"], "owner": {"b": 2, "a": 1}, "gone": null, "name": "Ada"}]"#)

        XCTAssertEqual(rows, [[
            "id": "7", "price": "1.5", "active": "true", "tags": #"["a"]"#, "owner": #"{"a":1,"b":2}"#, "name": "Ada"
        ]], "null leaves the column out")
    }

    func testJSONMustBeAnArrayOfObjects() {
        XCTAssertEqual(error { try json(#"{"id": 1}"#) }, "The JSON must be an array of objects, one per iteration.")
        XCTAssertEqual(error { try json(#"[{"id": 1}, 2]"#) }, "Item 2 of the JSON array isn't an object.")
        XCTAssertEqual(error { try json("[]") }, "The data has no rows.")
    }

    func testTooManyRowsAreRefused() {
        let text = "id\n" + (0...IterationData.maximumRows).map(String.init).joined(separator: "\n")

        XCTAssertEqual(error { try csv(text) }, "The data has 10001 rows; a run takes at most 10,000.")
    }

    func testAFileIsReadOffTheMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "iteration-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "users.json")
        try Data(#"[{"id": "1"}]"#.utf8).write(to: file)

        let rows = try await IterationData.read(file)
        var missing: IterationDataError?
        do {
            _ = try await IterationData.read(directory.appending(path: "nope.csv"))
        } catch {
            missing = error
        }

        XCTAssertEqual(rows, [["id": "1"]])
        XCTAssertTrue(missing?.message.hasPrefix("“nope.csv” couldn't be read") ?? false, String(describing: missing))
    }
}
