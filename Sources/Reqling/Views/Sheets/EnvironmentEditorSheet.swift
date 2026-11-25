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
            SheetFooter(note: footerNote, isPrimaryEnabled: editor.reservedNameProblem == nil) {
                dismiss()
            } onPrimary: {
                if editor.save() {
                    dismiss()
                }
            }
        }
        .frame(width: 760, height: 480)
    }

    /// A reserved name blocking Done first, then what a Postman import added to the draft.
    private var footerNote: String {
        editor.reservedNameProblem ?? editor.postmanImportNote ?? (editor.editsOnlySecretValues ? Self.viewOnlyNote : Self.note)
    }

    private static let note = "Default overrides Global, and the active environment overrides Default. "
        + "Secret values are stored in your Keychain, never in the project."

    private static let viewOnlyNote = "This project is shared with you to view. You can set your own secret values, "
        + "which only you see, and edit Global."
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
                .disabled(editor.editsOnlySecretValues)
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
                Button {
                    Task { await editor.importPostmanEnvironments() }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(editor.editsOnlySecretValues)
                .help("Import Postman environments or globals")
                .accessibilityLabel("Import Postman environments or globals")
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
                if !editor.editsOnlySecretValues {
                    Button("Duplicate") { editor.duplicateEnvironment(environment.id) }
                }
                if editor.canRemove(environment.id) {
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
                    caption: "Every request in every project sees these variables, kept apart from any project. Each project's "
                        + "environments override them by key."
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
                    .disabled(editor.isSelectedLocked)
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
                    VariableTable(variables: $editor.selected.variables, onlySecretValues: editor.isSelectedLocked)
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
    /// Whether only secret values may change, as in a project shared to view: no row is added, removed, or rekeyed.
    let onlySecretValues: Bool
    /// The identity the draft row gives the variable its first edit creates, so the new row keeps the draft row's view
    /// identity, and with it the text field's focus.
    @State private var draftID = VariableID()
    @State private var checkboxRange = CheckboxRange<VariableID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !variables.isEmpty, !onlySecretValues {
                CheckboxSelectionBar(rows: $variables, isOn: \.isEnabled)
            }
            ForEach(onlySecretValues ? variables : variables + [Variable(id: draftID, key: "", value: "")]) { variable in
                VariableRow(
                    variable: variable,
                    isDraft: variable.id == draftID,
                    onlySecretValue: onlySecretValues,
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
    /// Whether only a secret variable's value may change here.
    let onlySecretValue: Bool
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
                .disabled(isDraft || onlySecretValue)
                .accessibilityLabel("Use this variable")
            TextField("Key", text: binding(\.key))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: 200)
                .disabled(onlySecretValue)
            if variable.isSecret {
                SecureField(onlySecretValue ? "Your value" : "Value", text: binding(\.value))
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("Value", text: binding(\.value))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(onlySecretValue)
            }
            Toggle(isOn: binding(\.isSecret)) {
                Image(systemName: variable.isSecret ? "lock.fill" : "lock.open")
            }
            .toggleStyle(IconToggleStyle())
            .disabled(onlySecretValue)
            .help(variable.isSecret ? "Secret: stored in your Keychain and masked in previews" : "Mark as secret")
            .accessibilityLabel("Secret")
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(IconButtonStyle())
            .help("Remove this variable")
            .accessibilityLabel("Remove this variable")
            .opacity(isDraft || onlySecretValue ? 0 : 1)
            .disabled(isDraft || onlySecretValue)
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
