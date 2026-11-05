import ReqlingKit
import SwiftUI

/// Edits a project's environments. Default is always first; the others override its variables when active.
struct EnvironmentEditorSheet: View {
    @State var editor: EnvironmentEditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                EnvironmentList(editor: editor)
                    .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
                EnvironmentDetail(editor: editor)
                    .frame(minWidth: 420)
            }
            SheetFooter(note: Self.note) {
                dismiss()
            } onPrimary: {
                if editor.save() {
                    dismiss()
                }
            }
        }
        .frame(width: 760, height: 480)
    }

    private static let note =
        "The active environment's variables override Default's. Secret values are stored in your Keychain, never in the project."
}

private struct EnvironmentList: View {
    @Bindable var editor: EnvironmentEditorModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $editor.selectedID) {
                ForEach(editor.allEnvironments) { environment in
                    Label(
                        environment.name,
                        systemImage: environment.id == editor.defaultEnvironment.id ? "square.stack.3d.up.fill" : "square.stack.3d.up"
                    )
                        .tag(environment.id)
                        .contextMenu {
                            Button("Duplicate") { editor.duplicateEnvironment(environment.id) }
                            if environment.id != editor.defaultEnvironment.id {
                                Button("Delete", role: .destructive) { editor.removeEnvironment(environment.id) }
                            }
                        }
                }
            }
            HStack(spacing: 2) {
                Button {
                    editor.addEnvironment()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add an environment")
                .accessibilityLabel("Add an environment")
                Button {
                    editor.removeEnvironment(editor.selectedID)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(editor.isDefaultSelected)
                .help("Delete the selected environment")
                .accessibilityLabel("Delete the selected environment")
                Spacer()
            }
            .buttonStyle(IconButtonStyle())
            // The icon tiles carry their own padding, so the bar adds only a little.
            .padding(4)
        }
    }
}

private struct EnvironmentDetail: View {
    @Bindable var editor: EnvironmentEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editor.isDefaultSelected {
                Text("Default")
                    .font(.title3.weight(.semibold))
                Text("Every request sees these variables. Other environments override them by key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Name", text: $editor.selected.name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .accessibilityLabel("Environment name")
            }
            if !editor.duplicateKeys.isEmpty {
                Label(
                    "Defined more than once: \(editor.duplicateKeys.joined(separator: ", ")). The last one wins.",
                    systemImage: "exclamationmark.triangle"
                )
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ScrollView {
                VariableTable(variables: $editor.selected.variables)
            }
        }
        .padding(AppMetrics.paneInset)
    }
}

/// Variable rows with a trailing draft row, like `KeyValueTable`, plus a secret toggle per row.
///
/// Rows are keyed and written by `Variable.id`, so an edit that arrives after its row was removed or moved (a text
/// field committing as it loses focus) finds nothing to change instead of overwriting whichever row took its place.
private struct VariableTable: View {
    @Binding var variables: [Variable]
    /// The identity the draft row gives the variable its first edit creates, so the new row keeps the draft row's view
    /// identity, and with it the text field's focus.
    @State private var draftID = VariableID()
    @State private var checkboxRange = CheckboxRange<VariableID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !variables.isEmpty {
                CheckboxSelectionBar(rows: $variables, isOn: \.isEnabled)
            }
            ForEach(variables + [Variable(id: draftID, key: "", value: "")]) { variable in
                VariableRow(
                    variable: variable,
                    isDraft: variable.id == draftID,
                    onEdit: { edit(variable.id, $0) },
                    onToggle: { checkboxRange.click(\.isEnabled, to: $0, at: variable.id, in: $variables) },
                    onRemove: { variables.removeAll { $0.id == variable.id } }
                )
            }
        }
    }

    private func edit(_ id: VariableID, _ change: (inout Variable) -> Void) {
        if let index = variables.firstIndex(where: { $0.id == id }) {
            change(&variables[index])
        } else if id == draftID {
            let blank = Variable(id: id, key: "", value: "")
            var variable = blank
            change(&variable)
            guard variable != blank else {
                return
            }
            variables.append(variable)
            draftID = VariableID()
        }
    }
}

private struct VariableRow: View {
    let variable: Variable
    let isDraft: Bool
    /// Applies one field's change to the table's current copy of this variable, never to this render's `variable`,
    /// so a second edit before the next render cannot revert the first.
    let onEdit: @MainActor (_ change: (inout Variable) -> Void) -> Void
    /// Goes through the table rather than `onEdit`, since a Shift-click sets a range of rows.
    let onToggle: @MainActor (Bool) -> Void
    let onRemove: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Enabled", isOn: Binding(get: { variable.isEnabled }, set: { onToggle($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isDraft)
                .accessibilityLabel("Use this variable")
            TextField("Key", text: binding(\.key))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: 200)
            if variable.isSecret {
                SecureField("Value", text: binding(\.value))
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("Value", text: binding(\.value))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            Toggle(isOn: binding(\.isSecret)) {
                Image(systemName: variable.isSecret ? "lock.fill" : "lock.open")
            }
            .toggleStyle(IconToggleStyle())
            .help(variable.isSecret ? "Secret: stored in your Keychain and masked in previews" : "Mark as secret")
            .accessibilityLabel("Secret")
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(IconButtonStyle())
            .help("Remove this variable")
            .accessibilityLabel("Remove this variable")
            .opacity(isDraft ? 0 : 1)
            .disabled(isDraft)
        }
        .opacity(variable.isEnabled || isDraft ? 1 : 0.55)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Variable, Value>) -> Binding<Value> {
        Binding(
            get: { variable[keyPath: keyPath] },
            set: { newValue in onEdit { $0[keyPath: keyPath] = newValue } }
        )
    }
}
