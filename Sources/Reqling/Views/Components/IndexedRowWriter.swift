import SwiftUI

/// The write path from one row of a table keyed by position back into its array, for elements with no identity of
/// their own (a gRPC request's messages). Rows that carry IDs use `IdentifiedRowWriter` instead.
///
/// A row is only "the element at `index`", so an edit lands only while that slot still holds what this row last
/// showed or wrote. A late commit from a row that was removed or shifted (an input method committing as focus
/// leaves, say) is dropped instead of overwriting its new neighbour or trapping out of range. Each render makes a
/// fresh writer, and `shown` follows its own writes in between, so two edits before the next render (typing `{{`,
/// then completion inserting a name) both land. Removals go through `identities` first, so the rows' view
/// identities follow them.
@MainActor
final class IndexedRowWriter<Element: Equatable> {
    private let rows: Binding<[Element]>
    private let index: Int
    private let identities: RowIdentities?
    private(set) var shown: Element

    init(rows: Binding<[Element]>, index: Int, shown: Element, identities: RowIdentities? = nil) {
        self.rows = rows
        self.index = index
        self.shown = shown
        self.identities = identities
    }

    func binding<Value>(_ keyPath: WritableKeyPath<Element, Value>) -> Binding<Value> {
        Binding(
            get: { self.shown[keyPath: keyPath] },
            set: { newValue in self.edit { $0[keyPath: keyPath] = newValue } }
        )
    }

    func edit(_ change: (inout Element) -> Void) {
        var updated = shown
        change(&updated)
        guard updated != shown else {
            return
        }
        var current = rows.wrappedValue
        guard index < current.count, current[index] == shown else {
            return
        }
        current[index] = updated
        rows.wrappedValue = current
        shown = updated
    }

    func remove() {
        var current = rows.wrappedValue
        guard index < current.count, current[index] == shown else {
            return
        }
        current.remove(at: index)
        identities?.rowWasRemoved(at: index)
        rows.wrappedValue = current
    }
}

/// View-local identities for the rows of a table whose elements carry none, which `ForEach` keys the rows by.
///
/// Keyed by position instead, removing a row would hand its fields to the row below, so a focused field would jump to
/// another row's text. These follow the table's own appends and removals (through `IndexedRowWriter`, or
/// `rowWasAppended()`). When the count changes any other way, nothing says which rows survived, so every row is
/// re-keyed. Hold it in `@State`: it is a class so that a render can re-key without a state change.
@MainActor
final class RowIdentities {
    private var ids: [UUID] = []

    /// One identity per row, re-keying every row when the count no longer matches the edits seen here.
    func ids(count: Int) -> [UUID] {
        if ids.count != count {
            ids = (0..<count).map { _ in UUID() }
        }
        return ids
    }

    func rowWasAppended() {
        ids.append(UUID())
    }

    func rowWasRemoved(at index: Int) {
        if ids.indices.contains(index) {
            ids.remove(at: index)
        }
    }
}

/// A row's position paired with the identity `ForEach` keys it by.
struct IdentifiedRow: Identifiable {
    let id: UUID
    let index: Int

    static func rows(_ ids: [UUID]) -> [IdentifiedRow] {
        ids.enumerated().map { IdentifiedRow(id: $1, index: $0) }
    }
}
