import ReqlingKit
import SwiftUI

/// Edits a project's environments, under the project's name, beneath the Global environment every project shares.
/// Default overrides Global; the others override Default when active.
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
            SheetFooter(note: editor.reservedNameProblem ?? Self.note, isPrimaryEnabled: editor.reservedNameProblem == nil) {
                dismiss()
            } onPrimary: {
                if editor.save() {
                    dismiss()
                }
            }
        }
        .frame(width: 760, height: 480)
    }

    private static let note = "Default overrides Global, and the active environment overrides Default. "
        + "Secret values are stored in your Keychain, never in the project."
}

private struct EnvironmentList: View {
    @Bindable var editor: EnvironmentEditorModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $editor.selectedID) {
                // Headers are rows rather than `Section`s, which macOS sets far apart with no way to bring them closer.
                EnvironmentListHeader(title: "All Projects")
                row(editor.globalEnvironment, systemImage: "globe")
                EnvironmentListHeader(title: editor.projectName)
                    .padding(.top, 6)
                ForEach(editor.projectEnvironments) { environment in
                    row(environment, systemImage: systemImage(for: environment))
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
                .disabled(!editor.canRemoveSelected)
                .help("Delete the selected environment")
                .accessibilityLabel("Delete the selected environment")
                Spacer()
            }
            .buttonStyle(IconButtonStyle())
            // The icon tiles carry their own padding, so the bar adds only a little.
            .padding(4)
        }
    }

    /// A warning in place of the stack for an environment named like Global, so the one blocking Done is easy to find.
    private func systemImage(for environment: RequestEnvironment) -> String {
        if environment.id == editor.defaultEnvironment.id {
            return "square.stack.3d.up.fill"
        }
        return RequestEnvironment.isGlobalName(environment.name) ? "exclamationmark.triangle" : "square.stack.3d.up"
    }

    private func row(_ environment: RequestEnvironment, systemImage: String) -> some View {
        Label(environment.name, systemImage: systemImage)
            .tag(environment.id)
            // Inset to the text rather than the icon, they read as stray lines between so few rows.
            .listRowSeparator(.hidden)
            .contextMenu {
                Button("Duplicate") { editor.duplicateEnvironment(environment.id) }
                if editor.environments.contains(where: { $0.id == environment.id }) {
                    Button("Delete", role: .destructive) { editor.removeEnvironment(environment.id) }
                }
            }
    }
}

/// A group's title among the environment list's rows: Global's, then the project's own.
private struct EnvironmentListHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .selectionDisabled()
            .listRowSeparator(.hidden)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct EnvironmentDetail: View {
    @Bindable var editor: EnvironmentEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editor.isGlobalSelected {
                FixedEnvironmentHeader(
                    title: RequestEnvironment.globalName,
                    caption: "Every request in every project sees these variables, kept on this Mac. Each project's environments "
                        + "override them by key."
                )
                if let issue = editor.globalEnvironmentIssue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if editor.isDefaultSelected {
                FixedEnvironmentHeader(
                    title: RequestEnvironment.defaultName,
                    caption: "Every request in this project sees these variables. Other environments override them by key."
                )
            } else {
                TextField("Name", text: $editor.selected.name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .accessibilityLabel("Environment name")
                if RequestEnvironment.isGlobalName(editor.selected.name) {
                    Label(EnvironmentEditorModel.reservedNameWarning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
                VStack(alignment: .leading, spacing: 18) {
                    VariableTable(variables: $editor.selected.variables)
                    CurrentValuesSection(editor: editor)
                }
            }
        }
        .padding(AppMetrics.paneInset)
    }
}

/// The title and caption of an environment that can't be renamed: Global or Default.
private struct FixedEnvironmentHeader: View {
    let title: String
    let caption: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
        Text(caption)
            .font(.callout)
            .foregroundStyle(.secondary)
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
