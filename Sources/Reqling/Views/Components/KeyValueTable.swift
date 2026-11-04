import ReqlingKit
import SwiftUI

/// Editable key/value rows for parameters, headers, and URL-encoded forms.
///
/// A trailing draft row is always shown; typing into it appends a real row in place, so the field keeps focus.
/// `KeyValuePair` has no identity, so rows are keyed by view-local `RowIdentities` and write through
/// `IndexedRowWriter`.
struct KeyValueTable: View {
    @Binding var rows: [KeyValuePair]
    var keyPlaceholder = "Key"
    var valuePlaceholder = "Value"
    /// Names one row for accessibility, such as "header".
    var rowName: String
    var tokenContext: TemplateTokenContext

    @State private var identities = RowIdentities()

    var body: some View {
        let slots = IdentifiedRow.rows(identities.ids(count: rows.count), draftID: identities.draftID)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(slots) { slot in
                let isDraft = slot.index == rows.count
                KeyValueTableRow(
                    writer: IndexedRowWriter(
                        rows: $rows,
                        index: slot.index,
                        shown: isDraft ? KeyValuePair(key: "", value: "") : rows[slot.index],
                        isDraft: isDraft,
                        identities: identities
                    ),
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
    let writer: IndexedRowWriter<KeyValuePair>
    let keyPlaceholder: String
    let valuePlaceholder: String
    let rowName: String
    let tokenContext: TemplateTokenContext

    var body: some View {
        let isDraft = writer.isDraft
        HStack(spacing: 6) {
            Toggle("Enabled", isOn: writer.binding(\.isEnabled))
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
            .buttonStyle(.borderless)
            .help("Remove this \(rowName)")
            .accessibilityLabel("Remove this \(rowName)")
            .opacity(isDraft ? 0 : 1)
            .disabled(isDraft)
        }
        .opacity(writer.shown.isEnabled || isDraft ? 1 : 0.55)
    }
}
