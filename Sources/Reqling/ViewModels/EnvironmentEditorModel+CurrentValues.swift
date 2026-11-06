import Foundation
import ReqlingKit
import ReqlingTemplating

/// One current value the sheet lists under the selected environment's variables.
struct CurrentValueRow: Identifiable, Equatable {
    let key: String
    /// `nil` for a marker a script's `unset` left, which hides the saved value.
    let value: String?
    let isSecret: Bool
    /// The environment saves this key too, so the current value overrides that.
    let overridesSavedValue: Bool

    var id: String {
        key
    }
}

/// What scripts set on this Mac over the selected environment's saved values. Like every other edit in the sheet,
/// Reset, Reset All, and Save as Value are staged and apply on Done, so Cancel leaves the current values alone.
extension EnvironmentEditorModel {
    /// The selected environment's current values, sorted by key, minus those Reset is staged for and those whose saved
    /// variable the draft changed: saving that edit drops them (`ProjectLibrary.mutate`).
    var currentValueRows: [CurrentValueRow] {
        let environment = selected
        guard !stagedCurrentValueResetAll.contains(environment.id) else {
            return []
        }
        let staged = stagedCurrentValueResets[environment.id] ?? []
        let edited = baseEnvironment(environment.id).map { base in
            SavedVariableChanges(old: [base], new: [environment]).changedKeys[environment.id] ?? []
        } ?? []
        let savedKeys = Set(environment.variables.map(\.key))
        return currentValues(of: environment.id)
            .filter { !staged.contains($0.key) && !edited.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { key, current in
                switch current {
                case .value(let variable):
                    CurrentValueRow(key: key, value: variable.value, isSecret: variable.isSecret, overridesSavedValue: savedKeys.contains(key))
                case .unset:
                    CurrentValueRow(key: key, value: nil, isSecret: false, overridesSavedValue: savedKeys.contains(key))
                }
            }
    }

    /// Why a secret current value couldn't be read or stored, shown with the current values.
    var currentValueIssue: String? {
        app.library.currentValues.issue
    }

    func resetCurrentValue(_ key: String) {
        stagedCurrentValueResets[selectedID, default: []].insert(key)
    }

    func resetAllCurrentValues() {
        stagedCurrentValueResetAll.insert(selectedID)
    }

    /// Puts the current value into the draft as the variable's saved value, the way the library's Save as Value does,
    /// and stages dropping the current value, which a value already equal to the saved one would otherwise keep.
    func saveCurrentValueAsValue(_ key: String) {
        guard case .value(let current)? = currentValues(of: selectedID)[key] else {
            return
        }
        var environment = selected
        environment.adoptCurrentValue(current, for: key)
        selected = environment
        resetCurrentValue(key)
    }

    /// Drops the staged current values once Done has saved everything else.
    func applyStagedCurrentValueResets() {
        for environment in stagedCurrentValueResetAll {
            app.library.currentValues.reset(in: currentValueScope(environment))
        }
        for (environment, keys) in stagedCurrentValueResets where !stagedCurrentValueResetAll.contains(environment) {
            app.library.currentValues.reset(keys, in: currentValueScope(environment))
        }
        stagedCurrentValueResets = [:]
        stagedCurrentValueResetAll = []
    }

    private func currentValues(of environment: EnvironmentID) -> [String: CurrentVariable] {
        app.library.currentValues.values(in: currentValueScope(environment))
    }

    private func currentValueScope(_ environment: EnvironmentID) -> CurrentValueScope {
        environment == globalEnvironment.id ? .global : .environment(projectID, environment)
    }

    private func baseEnvironment(_ id: EnvironmentID) -> RequestEnvironment? {
        ([baseGlobalEnvironment, baseDefaultEnvironment] + baseEnvironments).first { $0.id == id }
    }
}
