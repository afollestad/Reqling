import ReqlingKit
import SwiftUI

/// A request's path variables: one row per `:name` its URL uses, in order. The URL owns the names (`URLAddressed` keeps
/// the rows in step with it), so unlike `KeyValueTable` the keys are fixed and there is no draft row, checkbox, or
/// remove button; only the values edit, and a variable goes away when the URL stops using it.
struct PathVariableTable: View {
    @Binding var rows: [KeyValuePair]
    var tokenContext: TemplateTokenContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Path variables")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(rows) { row in
                PathVariableRow(writer: IdentifiedRowWriter(rows: $rows, shown: row), tokenContext: tokenContext)
            }
        }
    }
}

private struct PathVariableRow: View {
    let writer: IdentifiedRowWriter<KeyValuePair>
    let tokenContext: TemplateTokenContext

    var body: some View {
        let name = ":\(writer.shown.key)"
        HStack(spacing: 6) {
            // Hidden copies of `KeyValueTable`'s checkbox and remove button keep the columns in line with the query's.
            Toggle("", isOn: .constant(true))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .hidden()
                .accessibilityHidden(true)
            Text(name)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                // Where a field's text starts.
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Set by the URL; rename it there")
            TemplateField(
                text: writer.binding(\.value),
                placeholder: "Value",
                tokenContext: tokenContext,
                accessibilityLabel: "Value of \(name)"
            )
            Button {} label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(IconButtonStyle())
            .hidden()
            .accessibilityHidden(true)
        }
    }
}
