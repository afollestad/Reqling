import Foundation
import Observation
import ReqlingKit

/// Edits a project's environments, and the Global environment every project shares, as a draft that commits on Done,
/// so a half-typed secret is not written to the Keychain on every keystroke. Global comes first, then Default; neither
/// can be renamed or removed, and Global is never made active.
///
/// Done merges the draft into what is stored now (see `save()`), so an agent's or a `git pull`'s change made while the
/// sheet was open survives unless the sheet changed the same environment name or variable.
@MainActor
@Observable
final class EnvironmentEditorModel {
    let projectID: ProjectID
    var globalEnvironment: RequestEnvironment
    var defaultEnvironment: RequestEnvironment
    var environments: [RequestEnvironment]
    var selectedID: EnvironmentID
    /// Current values Reset, or Save as Value, is to drop on Done, by environment (`EnvironmentEditorModel+CurrentValues`).
    var stagedCurrentValueResets: [EnvironmentID: Set<String>] = [:]
    /// Environments whose every current value Reset All is to drop on Done, including any a script sets meanwhile.
    var stagedCurrentValueResetAll: Set<EnvironmentID> = []

    @ObservationIgnored unowned let app: AppModel
    /// The environments as loaded or last saved: the base of Done's merge.
    @ObservationIgnored private(set) var baseGlobalEnvironment: RequestEnvironment
    @ObservationIgnored private(set) var baseDefaultEnvironment: RequestEnvironment
    @ObservationIgnored private(set) var baseEnvironments: [RequestEnvironment]

    init(projectID: ProjectID, app: AppModel) {
        self.projectID = projectID
        self.app = app
        let document = app.library.document(projectID)
        globalEnvironment = app.library.globalEnvironment
        baseGlobalEnvironment = app.library.globalEnvironment
        let defaultEnvironment = document?.defaultEnvironment ?? RequestEnvironment(name: RequestEnvironment.defaultName)
        let environments = document?.environments ?? []
        self.defaultEnvironment = defaultEnvironment
        self.environments = environments
        baseDefaultEnvironment = defaultEnvironment
        baseEnvironments = environments
        selectedID = app.activeEnvironmentID(for: projectID) ?? defaultEnvironment.id
    }

    /// The heading over the project's own environments, so they never read as shared like Global.
    var projectName: String {
        app.library.document(projectID)?.name ?? ""
    }

    /// Default first, then the others: the project's own, which the list shows under its name.
    var projectEnvironments: [RequestEnvironment] {
        [defaultEnvironment] + environments
    }

    var allEnvironments: [RequestEnvironment] {
        [globalEnvironment] + projectEnvironments
    }

    var isGlobalSelected: Bool {
        selectedID == globalEnvironment.id
    }

    var isDefaultSelected: Bool {
        selectedID == defaultEnvironment.id
    }

    /// Whether the selection can be removed: only a project's own environments other than Default can.
    var canRemoveSelected: Bool {
        environments.contains { $0.id == selectedID }
    }

    static let reservedNameWarning = "“\(RequestEnvironment.globalName)” is reserved for the environment every project shares."

    /// Why Done is refused, if it is: one of the project's environments is named like Global, a name reserved for it.
    var reservedNameProblem: String? {
        guard environments.contains(where: { RequestEnvironment.isGlobalName($0.name) }) else {
            return nil
        }
        return "\(Self.reservedNameWarning) Rename the environment using it."
    }

    /// Why Global loaded incomplete, shown above its variables.
    var globalEnvironmentIssue: String? {
        app.library.globalEnvironmentIssue
    }

    var selected: RequestEnvironment {
        get {
            allEnvironments.first { $0.id == selectedID } ?? defaultEnvironment
        }
        set {
            if newValue.id == globalEnvironment.id {
                globalEnvironment = RequestEnvironment.global(variables: newValue.variables)
            } else if newValue.id == defaultEnvironment.id {
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
        guard environments.contains(where: { $0.id == id }) else {
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

    /// Merges the draft into the stored environments, three-way against what the sheet loaded: environments per ID
    /// (Global and Default included), each one's name as a field and its variables per ID (`ListMerge`). Whatever the
    /// sheet left alone takes the stored version, deletions included. Secret values need no bookkeeping here: they
    /// travel with their variables, and the library's mutations store and delete them by comparing what the merge
    /// produced with what was stored.
    ///
    /// Global saves first, in its own write: when the project's save then fails, Global's base already matches what
    /// was stored, so Done again merges only what is still unsaved.
    @discardableResult
    func save() -> Bool {
        guard reservedNameProblem == nil, saveGlobalEnvironment(), let (mergedDefault, mergedEnvironments) = saveProjectEnvironments() else {
            return false
        }
        defaultEnvironment = mergedDefault
        environments = mergedEnvironments
        baseDefaultEnvironment = mergedDefault
        baseEnvironments = mergedEnvironments
        if mergedEnvironments.contains(where: { $0.id == selectedID }) || selectedID == mergedDefault.id {
            app.setActiveEnvironment(selectedID, for: projectID)
        }
        applyStagedCurrentValueResets()
        return true
    }

    /// The project's environments after Done: merged and saved, or as stored when the sheet changed none of them, since
    /// a read-only project refuses even an empty save and Done may have changed only Global.
    private func saveProjectEnvironments() -> (RequestEnvironment, [RequestEnvironment])? {
        let draftDefault = defaultEnvironment
        let draftEnvironments = environments.map { environment in
            var trimmed = environment
            trimmed.name = environment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : environment.name
            return trimmed
        }
        let baseDefault = baseDefaultEnvironment
        let base = baseEnvironments
        if draftDefault == baseDefault, draftEnvironments == base, let document = app.library.document(projectID) {
            return (document.defaultEnvironment, document.environments)
        }
        return app.perform("Couldn't Save the Environments") {
            try app.library.mutate(projectID) { document in
                document.defaultEnvironment = Self.merge(base: baseDefault, draft: draftDefault, stored: document.defaultEnvironment)
                document.environments = ListMerge.merge(
                    base: base,
                    draft: draftEnvironments,
                    stored: document.environments,
                    mergeEdited: Self.merge(base:draft:stored:)
                )
                return (document.defaultEnvironment, document.environments)
            }
        }
    }

    private func saveGlobalEnvironment() -> Bool {
        let draft = globalEnvironment
        let base = baseGlobalEnvironment
        let merged = app.perform("Couldn't Save the Environments") {
            try app.library.mutateGlobalEnvironment { stored in
                stored = Self.merge(base: base, draft: draft, stored: stored)
            }
            return app.library.globalEnvironment
        }
        guard let merged else {
            return false
        }
        globalEnvironment = merged
        baseGlobalEnvironment = merged
        return true
    }

    /// One environment both sides may have changed: the name as one field, the variables per ID.
    private nonisolated static func merge(base: RequestEnvironment, draft: RequestEnvironment, stored: RequestEnvironment) -> RequestEnvironment {
        var merged = stored
        if draft.name != base.name {
            merged.name = draft.name
        }
        merged.variables = ListMerge.merge(base: base.variables, draft: draft.variables, stored: stored.variables, mergeEdited: mergeVariable)
        return merged
    }

    /// The sheet's version of a variable both sides changed, kept secret when either side has it secret unless the sheet
    /// itself turned that off: otherwise a value typed in one place as a secret could land in a file because the
    /// other place changed the flag meanwhile.
    private nonisolated static func mergeVariable(base: Variable, draft: Variable, stored: Variable) -> Variable {
        var merged = draft
        if draft.isSecret == base.isSecret {
            merged.isSecret = draft.isSecret || stored.isSecret
        }
        return merged
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
