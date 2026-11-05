import AppKit
import SwiftUI

/// Shift-click ranges for a table whose rows each carry an on/off checkbox, such as "send this parameter".
///
/// The anchor is the last row clicked, held by ID, so removing or reordering rows never moves it onto another row; a
/// Shift-click whose anchor is gone sets only the row clicked. A range takes the clicked box's new state, and the
/// clicked row becomes the next anchor, so ranges chain.
struct CheckboxRange<ID: Hashable> {
    private(set) var anchor: ID?

    /// Applies a click on one row's checkbox; Shift extends it from the anchor.
    ///
    /// Shift is read from the click's own event, not the keyboard's live state, so the modifier held at the click is
    /// the one that counts. The rows are written once, and only when something changed, so a range is a single edit.
    @MainActor
    mutating func click<Row: Identifiable & Equatable>(
        _ keyPath: WritableKeyPath<Row, Bool>,
        to isOn: Bool,
        at id: ID,
        in rows: Binding<[Row]>
    ) where Row.ID == ID {
        var updated = rows.wrappedValue
        let extending = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        set(keyPath, to: isOn, at: id, extending: extending, in: &updated)
        if updated != rows.wrappedValue {
            rows.wrappedValue = updated
        }
    }

    /// Sets the row `id` names to `isOn`, and with `extending`, every row between it and the anchor too. An ID not in
    /// `rows`, such as a table's draft row, changes nothing and leaves the anchor where it was.
    mutating func set<Row: Identifiable>(
        _ keyPath: WritableKeyPath<Row, Bool>,
        to isOn: Bool,
        at id: ID,
        extending: Bool,
        in rows: inout [Row]
    ) where Row.ID == ID {
        guard let clicked = rows.firstIndex(where: { $0.id == id }) else {
            return
        }
        var range = clicked...clicked
        if extending, let anchor, let start = rows.firstIndex(where: { $0.id == anchor }) {
            range = min(start, clicked)...max(start, clicked)
        }
        for index in range {
            rows[index][keyPath: keyPath] = isOn
        }
        anchor = id
    }
}
