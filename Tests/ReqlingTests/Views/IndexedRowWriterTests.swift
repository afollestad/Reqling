import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

@MainActor
final class IndexedRowWriterTests: XCTestCase {
    private var rows: [KeyValuePair] = []
    private var binding: Binding<[KeyValuePair]> {
        Binding(get: { self.rows }, set: { self.rows = $0 })
    }

    func testTwoEditsBeforeTheNextRenderBothLand() {
        rows = [KeyValuePair(key: "a", value: "1")]
        let writer = writer(at: 0)

        writer.binding(\.key).wrappedValue = "ab"
        writer.binding(\.value).wrappedValue = "2"

        XCTAssertEqual(rows, [KeyValuePair(key: "ab", value: "2")])
    }

    func testALateEditFromAShiftedRowIsDropped() {
        rows = [KeyValuePair(key: "a", value: ""), KeyValuePair(key: "b", value: ""), KeyValuePair(key: "c", value: "")]
        let second = writer(at: 1)
        let third = writer(at: 2)

        writer(at: 0).remove()
        second.binding(\.key).wrappedValue = "late"
        third.binding(\.key).wrappedValue = "late"
        third.remove()

        XCTAssertEqual(rows.map(\.key), ["b", "c"])
    }

    func testTheDraftRowAppendsOnceThenEditsItsRow() {
        rows = [KeyValuePair(key: "a", value: "")]
        let draft = IndexedRowWriter(rows: binding, index: 1, shown: KeyValuePair(key: "", value: ""), isDraft: true)

        draft.binding(\.key).wrappedValue = "{{"
        draft.binding(\.key).wrappedValue = "{{token"
        draft.remove()

        XCTAssertEqual(rows.map(\.key), ["a", "{{token"])
    }

    func testIdentitiesFollowTheTablesOwnRemovalsAndDraftAppends() {
        rows = [KeyValuePair(key: "a", value: ""), KeyValuePair(key: "b", value: ""), KeyValuePair(key: "c", value: "")]
        let identities = RowIdentities()
        let ids = identities.ids(count: rows.count)
        let draftID = identities.draftID

        writer(at: 1, identities: identities).remove()
        XCTAssertEqual(identities.ids(count: rows.count), [ids[0], ids[2]])
        IndexedRowWriter(rows: binding, index: rows.count, shown: KeyValuePair(key: "", value: ""), isDraft: true, identities: identities)
            .binding(\.key).wrappedValue = "d"

        XCTAssertEqual(identities.ids(count: rows.count), [ids[0], ids[2], draftID])
        XCTAssertNotEqual(identities.draftID, draftID)
    }

    func testIdentitiesReKeyEveryRowWhenTheCountChangesFromOutside() {
        let identities = RowIdentities()
        let ids = identities.ids(count: 2)

        XCTAssertEqual(identities.ids(count: 2), ids)
        XCTAssertTrue(Set(identities.ids(count: 3)).isDisjoint(with: ids))
    }

    private func writer(at index: Int, identities: RowIdentities? = nil) -> IndexedRowWriter<KeyValuePair> {
        IndexedRowWriter(rows: binding, index: index, shown: rows[index], identities: identities)
    }
}
