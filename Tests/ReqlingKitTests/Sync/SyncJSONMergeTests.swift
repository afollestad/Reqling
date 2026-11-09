import CryptoKit
import Foundation
@testable import ReqlingKit
import XCTest

final class SyncJSONMergeTests: XCTestCase {
    private let digester = SyncDigester(key: SymmetricKey(size: .bits256))

    private func json(_ text: String) throws -> OrderedJSON {
        try OrderedJSONParser.parse(text)
    }

    private func merge(_ base: String?, _ local: String, _ remote: String, localIsNewer: Bool = false) throws -> OrderedJSON {
        let merger = SyncJSONMerge(digester: digester, localIsNewer: localIsNewer)
        return merger.merge(base: try base.map { digester.tree(try json($0)) }, local: try json(local), remote: try json(remote))
    }

    func testEditsToDifferentFieldsBothSurvive() throws {
        let merged = try merge(#"{"name": "a", "url": "u"}"#, #"{"name": "b", "url": "u"}"#, #"{"name": "a", "url": "v"}"#)

        XCTAssertEqual(merged, try json(#"{"name": "b", "url": "v"}"#))
    }

    func testAFieldBothSidesChangedTakesTheLaterEdit() throws {
        let base = #"{"name": "a"}"#

        XCTAssertEqual(try merge(base, #"{"name": "local"}"#, #"{"name": "remote"}"#, localIsNewer: true), try json(#"{"name": "local"}"#))
        XCTAssertEqual(try merge(base, #"{"name": "local"}"#, #"{"name": "remote"}"#), try json(#"{"name": "remote"}"#))
    }

    func testAnEditOnEitherSideBeatsARemovalOnTheOther() throws {
        let base = #"{"rows": [{"id": "1", "v": "a"}, {"id": "2", "v": "b"}]}"#
        let edited = #"{"rows": [{"id": "1", "v": "a"}, {"id": "2", "v": "edited"}]}"#
        let removed = #"{"rows": [{"id": "1", "v": "a"}]}"#

        XCTAssertEqual(try merge(base, edited, removed), try json(edited))
        XCTAssertEqual(try merge(base, removed, edited), try json(edited))
        XCTAssertEqual(try merge(base, removed, base), try json(removed), "An untouched row's removal stands")
    }

    func testRowsAddedOnBothSidesAreKeptInPlace() throws {
        let base = #"[{"id": "1"}, {"id": "3"}]"#

        let merged = try merge(base, #"[{"id": "1"}, {"id": "2"}, {"id": "3"}]"#, #"[{"id": "1"}, {"id": "3"}, {"id": "4"}]"#)

        XCTAssertEqual(merged, try json(#"[{"id": "1"}, {"id": "2"}, {"id": "3"}, {"id": "4"}]"#))
    }

    func testTheOrderFollowsTheSideThatReorderedOrTheLaterOneWhenBothDid() throws {
        let base = #"["a", "b", "c"]"#

        XCTAssertEqual(try merge(base, #"["c", "b", "a"]"#, base), try json(#"["c", "b", "a"]"#))
        XCTAssertEqual(try merge(base, #"["c", "b", "a"]"#, #"["b", "a", "c"]"#, localIsNewer: true), try json(#"["c", "b", "a"]"#))
        XCTAssertEqual(try merge(base, #"["c", "b", "a"]"#, #"["b", "a", "c"]"#), try json(#"["b", "a", "c"]"#))
    }

    /// Two Macs that had the project before it ever synced: what only one has is kept, and a differing value takes the
    /// server's.
    func testWithoutABaseWhatOnlyOneSideHasIsKeptAndTheServerWinsTheRest() throws {
        let merged = try merge(nil, #"{"name": "local", "mine": 1}"#, #"{"name": "remote", "theirs": 2}"#)

        XCTAssertEqual(merged, try json(#"{"mine": 1, "name": "remote", "theirs": 2}"#))
    }

    func testADigestTreeHoldsNoContent() throws {
        let tree = digester.tree(try json(#"{"password": "hunter2", "rows": [{"id": "1", "token": "s3cret"}]}"#)).prettyPrinted()

        for text in ["password", "hunter2", "token", "s3cret"] {
            XCTAssertFalse(tree.contains(text), text)
        }
    }
}
