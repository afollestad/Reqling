import ReqlingKit
import SwiftUI

/// The values scripts set on this Mac over the selected environment's variables, each with Save as Value and Reset.
/// Hidden while there are none.
struct CurrentValuesSection: View {
    let editor: EnvironmentEditorModel

    var body: some View {
        let rows = editor.currentValueRows
        if !rows.isEmpty || editor.currentValueIssue != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Current Values")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !rows.isEmpty {
                        Button("Reset All") { editor.resetAllCurrentValues() }
                            .controlSize(.small)
                            .help("Drop every value scripts set here, so the saved values apply again")
                    }
                }
                Text("Set by scripts. They override the saved values by key and never go into the project's files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let issue = editor.currentValueIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(rows) { row in
                    CurrentValueRowView(row: row, editor: editor)
                }
            }
        }
    }
}

private struct CurrentValueRowView: View {
    let row: CurrentValueRow
    let editor: EnvironmentEditorModel

    var body: some View {
        HStack(spacing: 8) {
            Text(row.key)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 160, alignment: .leading)
            valueText
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.isSecret {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Secret: stored in your Keychain and masked in previews")
                    .accessibilityLabel("Secret")
            }
            if row.value != nil {
                Button("Save as Value") { editor.saveCurrentValueAsValue(row.key) }
                    .help("Make this the environment's saved value, shared with the project")
            }
            Button("Reset") { editor.resetCurrentValue(row.key) }
                .help(row.overridesSavedValue ? "Drop this value so the saved one applies again" : "Drop this value")
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var valueText: some View {
        if let value = row.value {
            Text(row.isSecret ? TemplateResolver.mask : value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        } else {
            Text(row.overridesSavedValue ? "Unset by a script, hiding the saved value" : "Unset by a script")
                .italic()
                .foregroundStyle(.secondary)
        }
    }
}
