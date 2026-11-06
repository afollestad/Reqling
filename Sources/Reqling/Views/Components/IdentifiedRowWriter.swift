import SwiftUI

/// The write path from one row of a table keyed by its rows' own IDs (`KeyValuePair`, `MultipartField`) back into
/// its array. `ForEach` keys the rows by the same IDs, so a removal or an adopted change elsewhere never hands one
/// row's fields, or a focused field, to another.
///
/// An edit applies to the array's current copy of the row with this ID, never to the render's snapshot, so two edits
/// before the next render (typing `{{`, then completion inserting a name) both land, and a late commit from a row that
/// was removed (an input method committing as focus leaves) finds nothing and is dropped instead of landing on the
/// row that took its place. Each render makes a fresh writer, and `shown` follows its own writes in between.
///
/// A table's trailing draft row passes `isDraft` and the ID its first edit appends the row under; the table keys the
/// draft by that ID too, so the new row keeps the draft row's view identity, and with it the field's focus.
@MainActor
final class IdentifiedRowWriter<Row: Identifiable & Equatable> {
    private let rows: Binding<[Row]>
    /// Cleared once the draft's row is appended, so a late commit after that row is removed cannot append it again.
    private(set) var isDraft: Bool
    private let onDraftAppended: () -> Void
    private(set) var shown: Row

    init(rows: Binding<[Row]>, shown: Row, isDraft: Bool = false, onDraftAppended: @escaping () -> Void = {}) {
        self.rows = rows
        self.shown = shown
        self.isDraft = isDraft
        self.onDraftAppended = onDraftAppended
    }

    func binding<Value>(_ keyPath: WritableKeyPath<Row, Value>) -> Binding<Value> {
        Binding(
            get: { self.shown[keyPath: keyPath] },
            set: { newValue in self.edit { $0[keyPath: keyPath] = newValue } }
        )
    }

    func edit(_ change: (inout Row) -> Void) {
        var current = rows.wrappedValue
        if let index = current.firstIndex(where: { $0.id == shown.id }) {
            var updated = current[index]
            change(&updated)
            guard updated != current[index] else {
                return
            }
            current[index] = updated
            rows.wrappedValue = current
            shown = updated
        } else if isDraft {
            var updated = shown
            change(&updated)
            guard updated != shown else {
                return
            }
            current.append(updated)
            rows.wrappedValue = current
            shown = updated
            isDraft = false
            onDraftAppended()
        }
    }

    func remove() {
        var current = rows.wrappedValue
        guard !isDraft, let index = current.firstIndex(where: { $0.id == shown.id }) else {
            return
        }
        current.remove(at: index)
        rows.wrappedValue = current
    }

    /// Moves the row `offset` places (−1 up, +1 down) as one edit; at either end, or for the draft, nothing moves.
    func move(by offset: Int) {
        var current = rows.wrappedValue
        guard !isDraft, let index = current.firstIndex(where: { $0.id == shown.id }), current.indices.contains(index + offset) else {
            return
        }
        current.swapAt(index, index + offset)
        rows.wrappedValue = current
    }
}
