import Foundation
import Observation
import ReqlingKit

/// Edits a project's environments as a draft that commits on Done, so a half-typed secret is not written to the
/// Keychain on every keystroke. Default stays first and can be neither renamed nor removed.
@MainActor
@Observable
final class EnvironmentEditorModel {
    let projectID: ProjectID
    var defaultEnvironment: RequestEnvironment
    var environments: [RequestEnvironment]
    var selectedID: EnvironmentID

    @ObservationIgnored private unowned let app: AppModel

    init(projectID: ProjectID, app: AppModel) {
        self.projectID = projectID
        self.app = app
        let document = app.library.document(projectID)
        let defaultEnvironment = document?.defaultEnvironment ?? RequestEnvironment(name: RequestEnvironment.defaultName)
        self.defaultEnvironment = defaultEnvironment
        environments = document?.environments ?? []
        selectedID = app.activeEnvironmentID(for: projectID) ?? defaultEnvironment.id
    }

    var allEnvironments: [RequestEnvironment] {
        [defaultEnvironment] + environments
    }

    var isDefaultSelected: Bool {
        selectedID == defaultEnvironment.id
    }

    var selected: RequestEnvironment {
        get {
            allEnvironments.first { $0.id == selectedID } ?? defaultEnvironment
        }
        set {
            if newValue.id == defaultEnvironment.id {
                defaultEnvironment = newValue
                defaultEnvironment.name = RequestEnvironment.defaultName
            } else if let index = environments.firstIndex(where: { $0.id == newValue.id }) {
                environments[index] = newValue
            }
        }
    }

    /// Keys used more than once in the selected environment; the last enabled one wins when resolving.
    var duplicateKeys: [String] {
        let keys = selected.variables.filter(\.isEnabled).map(\.key).filter { !$0.isEmpty }
        return Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
    }

    func addEnvironment() {
        let environment = RequestEnvironment(name: uniqueName("New Environment"))
        environments.append(environment)
        selectedID = environment.id
    }

    func removeEnvironment(_ id: EnvironmentID) {
        guard id != defaultEnvironment.id else {
            return
        }
        environments.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = defaultEnvironment.id
        }
    }

    func duplicateEnvironment(_ id: EnvironmentID) {
        guard let source = allEnvironments.first(where: { $0.id == id }) else {
            return
        }
        let copy = RequestEnvironment(
            name: uniqueName("\(source.name) Copy"),
            variables: source.variables.map { Variable(key: $0.key, value: $0.value, isEnabled: $0.isEnabled, isSecret: $0.isSecret) }
        )
        environments.append(copy)
        selectedID = copy.id
    }

    @discardableResult
    func save() -> Bool {
        let defaultEnvironment = defaultEnvironment
        let environments = environments.map { environment in
            var trimmed = environment
            trimmed.name = environment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : environment.name
            return trimmed
        }
        let saved: Void? = app.perform("Couldn't Save the Environments") {
            try app.library.mutate(projectID) { document in
                document.defaultEnvironment = defaultEnvironment
                document.environments = environments
            }
        }
        if saved != nil, environments.contains(where: { $0.id == selectedID }) || selectedID == defaultEnvironment.id {
            app.setActiveEnvironment(selectedID, for: projectID)
        }
        return saved != nil
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(allEnvironments.map(\.name))
        guard names.contains(base) else {
            return base
        }
        var suffix = 2
        while names.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }
}
