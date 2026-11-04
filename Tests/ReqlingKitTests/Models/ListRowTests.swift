import Foundation
import ReqlingKit
import XCTest

final class ListRowTests: XCTestCase {
    // MARK: - Decoding

    func testRowsStoredWithoutIDsGetTheSameDistinctIDsOnEveryRead() throws {
        let json = #"""
        {"url": "https://x", "headers": [{"key": "A"}, {"key": "B"}], "queryParameters": [{"key": "q"}],
         "body": {"mode": "form-data", "form-data": [{"key": "f"}, {"key": "g"}], "x-www-form-urlencoded": [{"key": "u"}]}}
        """#

        let first = try decode(HTTPRequestSpec.self, json)
        let second = try decode(HTTPRequestSpec.self, json)

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first.headers.map(\.id)).count, 2)
        XCTAssertEqual(Set(first.body.formData.map(\.id)).count, 2)
        XCTAssertEqual(try ProjectJSON.decode(HTTPRequestSpec.self, from: ProjectJSON.encode(first)), first)
        XCTAssertEqual(
            try decode(GRPCRequestSpec.self, #"{"metadata": [{"key": "a"}]}"#),
            try decode(GRPCRequestSpec.self, #"{"metadata": [{"key": "a"}]}"#)
        )
    }

    /// A row pasted twice in a hand-edited file states its original's ID; the repeat gets one of its own, and no
    /// derived ID may take one that a later row states.
    func testARepeatedOrMissingIDNeverTakesAnIDAnotherRowStates() throws {
        let derived = try decode(HTTPRequestSpec.self, #"{"headers": [{"key": "first"}]}"#).headers[0].id
        let stated = KeyValuePairID()
        let json = #"""
        {"headers": [{"key": "new"}, {"id": "\#(derived)", "key": "saved"}, {"id": "\#(stated)", "key": "original"},
                     {"id": "\#(stated)", "key": "pasted"}, {"id": "not a uuid", "key": "broken"}]}
        """#

        let headers = try decode(HTTPRequestSpec.self, json).headers

        XCTAssertEqual(headers[1].id, derived)
        XCTAssertEqual(headers[2].id, stated)
        XCTAssertEqual(Set(headers.map(\.id)).count, headers.count)
        XCTAssertEqual(try decode(HTTPRequestSpec.self, json).headers, headers)
    }

    // MARK: - Rebuilding from the URL bar

    func testTypingInTheURLBarKeepsEveryRowsID() {
        var spec = HTTPRequestSpec(url: "https://x", queryParameters: [
            KeyValuePair(key: "a", value: "1"),
            KeyValuePair(key: "off", value: "1", isEnabled: false),
            KeyValuePair(key: "b", value: "2")
        ])
        let ids = spec.queryParameters.map(\.id)

        spec.applyDisplayURL("https://x?a=1&b=23")
        XCTAssertEqual(spec.queryParameters.map(\.id), [ids[0], ids[2], ids[1]], "edited in place; the disabled row is kept")
        spec.applyDisplayURL("https://x?a=1&b=23&")
        spec.applyDisplayURL("https://x?a=1&b=23&c")
        let added = spec.queryParameters[2].id
        XCTAssertFalse(ids.contains(added))
        spec.applyDisplayURL("https://x?z&a=1&b=23&c")
        XCTAssertEqual(spec.queryParameters.map(\.key), ["z", "a", "b", "c", "off"])
        XCTAssertEqual(Array(spec.queryParameters.map(\.id).dropFirst()), [ids[0], ids[2], added, ids[1]])
        spec.applyDisplayURL("https://x?z&b=23&c")

        XCTAssertEqual(Array(spec.queryParameters.map(\.id).dropFirst()), [ids[2], added, ids[1]])
        XCTAssertEqual(Set(spec.queryParameters.map(\.id)).count, spec.queryParameters.count)
    }

    func testRewritingTheWholeQueryPairsRowsByPositionAndApplyingTheSameTextTwiceAgrees() {
        var spec = HTTPRequestSpec(url: "https://x", queryParameters: [KeyValuePair(key: "a", value: "1"), KeyValuePair(key: "b", value: "2")])
        let ids = spec.queryParameters.map(\.id)

        spec.applyDisplayURL("https://x?c=3&d=4&e=5")
        var again = HTTPRequestSpec(url: "https://x", queryParameters: spec.queryParameters)
        again.applyDisplayURL(spec.displayURL)

        XCTAssertEqual(Array(spec.queryParameters.map(\.id).prefix(2)), ids)
        XCTAssertEqual(again, spec)
    }

    func testNormalizingTheSameSpecTwiceYieldsEqualRows() {
        let pasted = HTTPRequestSpec(url: "https://x?a=1&b=2", queryParameters: [KeyValuePair(key: "kept", value: "")])

        XCTAssertEqual(pasted.normalized(), pasted.normalized())
        XCTAssertEqual(pasted.normalized().queryParameters.map(\.key), ["kept", "a", "b"])
        XCTAssertEqual(Set(pasted.normalized().queryParameters.map(\.id)).count, 3)
    }

    /// Rows parsed on two sides (an agent's URL, a typed one) share an ID only when they are the same row, so a merge
    /// never mistakes one side's new row for an edit of the other's.
    func testRowsParsedIndependentlyShareAnIDOnlyWhenTheyMatch() {
        func firstRowID(_ url: String) -> KeyValuePairID? {
            HTTPRequestSpec(url: url).normalized().queryParameters.first?.id
        }
        var typed = HTTPRequestSpec()
        typed.applyDisplayURL("https://x?a=1")

        XCTAssertEqual(firstRowID("https://x?a=1"), firstRowID("https://y?a=1"))
        XCTAssertNotEqual(firstRowID("https://x?a=1"), firstRowID("https://x?b=1"))
        XCTAssertNotEqual(typed.queryParameters.first?.id, firstRowID("https://x?a=2"))
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try ProjectJSON.decode(type, from: Data(json.utf8))
    }
}
