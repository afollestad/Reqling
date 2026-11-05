import ReqlingKit
import SwiftUI

/// Editable key/value rows for parameters, headers, and URL-encoded forms.
///
/// A trailing draft row is always shown; typing into it appends a real row in place, so the field keeps focus.
/// Rows are keyed by their own IDs, which `KeyValuePair`'s list decoding keeps unique, and write through
/// `IdentifiedRowWriter`.
struct KeyValueTable: View {
    @Binding var rows: [KeyValuePair]
    var keyPlaceholder = "Key"
    var valuePlaceholder = "Value"
    /// Names one row for accessibility, such as "header".
    var rowName: String
    var tokenContext: TemplateTokenContext

    /// The ID the draft row's first edit appends its row under; renewed once it has.
    @State private var draftID = KeyValuePairID()
    @State private var checkboxRange = CheckboxRange<KeyValuePairID>()

    var body: some View {
        let draftID = draftID
        VStack(alignment: .leading, spacing: 6) {
            if !rows.isEmpty {
                CheckboxSelectionBar(rows: $rows, isOn: \.isEnabled)
            }
            ForEach(rows + [KeyValuePair(id: draftID, key: "", value: "")]) { row in
                KeyValueTableRow(
                    writer: IdentifiedRowWriter(
                        rows: $rows,
                        shown: row,
                        isDraft: row.id == draftID,
                        onDraftAppended: { self.draftID = KeyValuePairID() }
                    ),
                    onToggle: { checkboxRange.click(\.isEnabled, to: $0, at: row.id, in: $rows) },
                    keyPlaceholder: keyPlaceholder,
                    valuePlaceholder: valuePlaceholder,
                    rowName: rowName,
                    tokenContext: tokenContext
                )
            }
        }
    }
}

private struct KeyValueTableRow: View {
    let writer: IdentifiedRowWriter<KeyValuePair>
    /// Goes through the table rather than `writer`, since a Shift-click sets a range of rows.
    let onToggle: @MainActor (Bool) -> Void
    let keyPlaceholder: String
    let valuePlaceholder: String
    let rowName: String
    let tokenContext: TemplateTokenContext

    var body: some View {
        let isDraft = writer.isDraft
        HStack(spacing: 6) {
            Toggle("Enabled", isOn: Binding(get: { writer.shown.isEnabled }, set: { onToggle($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isDraft)
                .opacity(isDraft ? 0.35 : 1)
                .accessibilityLabel("Send this \(rowName)")
            TemplateField(
                text: writer.binding(\.key),
                placeholder: keyPlaceholder,
                tokenContext: tokenContext,
                accessibilityLabel: "\(rowName.capitalized) name"
            )
            TemplateField(
                text: writer.binding(\.value),
                placeholder: valuePlaceholder,
                tokenContext: tokenContext,
                accessibilityLabel: "\(rowName.capitalized) value"
            )
            Button(action: writer.remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(IconButtonStyle())
            .help("Remove this \(rowName)")
            .accessibilityLabel("Remove this \(rowName)")
            // Dimmed rather than hidden, like the checkbox, so the draft row spans the table's full width.
            .opacity(isDraft ? 0.35 : 1)
            .disabled(isDraft)
        }
        .opacity(writer.shown.isEnabled || isDraft ? 1 : 0.55)
    }
}
