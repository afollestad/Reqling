import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

@MainActor
final class IdentifiedRowWriterTests: XCTestCase {
    private var rows: [KeyValuePair] = []
    private var binding: Binding<[KeyValuePair]> {
        Binding(get: { self.rows }, set: { self.rows = $0 })
    }

    func testTwoEditsBeforeTheNextRenderBothLand() {
        rows = [KeyValuePair(key: "a", value: "1")]
        let writer = writer(for: 0)

        writer.binding(\.key).wrappedValue = "ab"
        writer.binding(\.value).wrappedValue = "2"

        XCTAssertEqual(rows.map(\.key), ["ab"])
        XCTAssertEqual(rows.map(\.value), ["2"])
    }

    func testALateEditFromARemovedRowIsDroppedWhileShiftedRowsStillTakeTheirs() {
        rows = [KeyValuePair(key: "a", value: ""), KeyValuePair(key: "b", value: ""), KeyValuePair(key: "c", value: "")]
        let first = writer(for: 0)
        let third = writer(for: 2)

        first.remove()
        first.binding(\.key).wrappedValue = "late"
        third.binding(\.key).wrappedValue = "c2"

        XCTAssertEqual(rows.map(\.key), ["b", "c2"], "the shifted row keeps its edit; the removed one lands nowhere")
    }

    func testAnEditKeepsAChangeMadeToTheSameRowSinceTheRender() {
        rows = [KeyValuePair(key: "a", value: "1")]
        let writer = writer(for: 0)
        rows[0].value = "adopted"

        writer.binding(\.key).wrappedValue = "ab"

        XCTAssertEqual(rows.map(\.value), ["adopted"])
    }

    func testTheDraftRowAppendsOnceUnderItsIDThenEditsItsRow() {
        rows = [KeyValuePair(key: "a", value: "")]
        let draftID = KeyValuePairID()
        var appended = 0
        let draft = IdentifiedRowWriter(
            rows: binding,
            shown: KeyValuePair(id: draftID, key: "", value: ""),
            isDraft: true,
            onDraftAppended: { appended += 1 }
        )

        draft.binding(\.key).wrappedValue = "{{"
        draft.binding(\.key).wrappedValue = "{{token"

        XCTAssertEqual(rows.map(\.key), ["a", "{{token"])
        XCTAssertEqual(rows.last?.id, draftID, "the new row keeps the draft row's identity, and with it focus")
        XCTAssertEqual(appended, 1)

        rows.removeLast()
        draft.binding(\.key).wrappedValue = "late"
        XCTAssertEqual(rows.map(\.key), ["a"], "a late commit after its row was removed must not append it again")
    }

    private func writer(for index: Int) -> IdentifiedRowWriter<KeyValuePair> {
        IdentifiedRowWriter(rows: binding, shown: rows[index])
    }
}
