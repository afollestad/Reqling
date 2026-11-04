import SwiftUI
import XCTest

@testable import Reqling

@MainActor
final class IndexedRowWriterTests: XCTestCase {
    private var rows: [String] = []
    private var binding: Binding<[String]> {
        Binding(get: { self.rows }, set: { self.rows = $0 })
    }

    func testTwoEditsBeforeTheNextRenderBothLand() {
        rows = ["{}"]
        let writer = writer(at: 0)

        writer.binding(\.self).wrappedValue = "{{"
        writer.binding(\.self).wrappedValue = "{{token}}"

        XCTAssertEqual(rows, ["{{token}}"])
    }

    func testALateEditFromAShiftedRowIsDropped() {
        rows = ["a", "b", "c"]
        let second = writer(at: 1)
        let third = writer(at: 2)

        writer(at: 0).remove()
        second.binding(\.self).wrappedValue = "late"
        third.binding(\.self).wrappedValue = "late"
        third.remove()

        XCTAssertEqual(rows, ["b", "c"])
    }

    func testIdentitiesFollowTheTablesOwnRemovalsAndAppends() {
        rows = ["a", "b", "c"]
        let identities = RowIdentities()
        let ids = identities.ids(count: rows.count)

        writer(at: 1, identities: identities).remove()
        XCTAssertEqual(identities.ids(count: rows.count), [ids[0], ids[2]])
        identities.rowWasAppended()
        rows.append("d")

        XCTAssertEqual(Array(identities.ids(count: rows.count).prefix(2)), [ids[0], ids[2]])
    }

    func testIdentitiesReKeyEveryRowWhenTheCountChangesFromOutside() {
        let identities = RowIdentities()
        let ids = identities.ids(count: 2)

        XCTAssertEqual(identities.ids(count: 2), ids)
        XCTAssertTrue(Set(identities.ids(count: 3)).isDisjoint(with: ids))
    }

    private func writer(at index: Int, identities: RowIdentities? = nil) -> IndexedRowWriter<String> {
        IndexedRowWriter(rows: binding, index: index, shown: rows[index], identities: identities)
    }
}
