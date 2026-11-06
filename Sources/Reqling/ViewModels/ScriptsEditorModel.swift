import Foundation
import Observation
import ReqlingKit
import ReqlingScriptProtocol

/// Whose scripts an editor shows.
enum ScriptsOwnerID: Hashable {
    case project
    case folder(RequestNodeID)
    case request(RequestNodeID)
}

/// A level whose scripts run before the edited ones, as the "Also runs" line links to it.
struct ScriptsChainLink: Hashable, Identifiable {
    let owner: ScriptsOwnerID
    let title: String

    var id: ScriptsOwnerID {
        owner
    }
}

/// What a Scripts pane edits: a request's, folder's, or project's two scripts, the phase shown, and whether the owner
/// runs inherited scripts. Whoever owns the draft (a request editor, or `ContainerScriptsEditor`) hears of each edit
/// through `onChange` and answers with `show(_:runsInheritedScripts:)` when it adopts a stored version, which is no edit.
@MainActor
@Observable
final class ScriptsEditorModel {
    let projectID: ProjectID
    let owner: ScriptsOwnerID
    var phase: ScriptPhase = .preRequest {
        didSet {
            if phase != oldValue {
                validate(after: nil)
            }
        }
    }
    private(set) var scripts: ScriptSet
    private(set) var runsInheritedScripts: Bool
    /// The shown script's problems (`ScriptsEditorModel+Assistant`).
    var diagnostics: CodeDiagnosticSet = .none
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored var responseShape: ScriptJSONShape?
    @ObservationIgnored var validationTask: Task<Void, Never>?
    @ObservationIgnored var validationGeneration = 0

    init(projectID: ProjectID, owner: ScriptsOwnerID, scripts: ScriptSet, runsInheritedScripts: Bool, app: AppModel) {
        self.projectID = projectID
        self.owner = owner
        self.scripts = scripts
        self.runsInheritedScripts = runsInheritedScripts
        self.app = app
        validate(after: nil)
    }

    isolated deinit {
        validationTask?.cancel()
    }

    /// The shown phase's script.
    var source: String {
        get { scripts[phase] }
        set {
            guard newValue != scripts[phase] else {
                return
            }
            scripts[phase] = newValue
            onChange?()
            validate(after: Self.validationDelay)
        }
    }

    /// The project's scripts are the outermost, with nothing to inherit.
    var canInherit: Bool {
        owner != .project
    }

    func setRunsInheritedScripts(_ runs: Bool) {
        guard runs != runsInheritedScripts else {
            return
        }
        runsInheritedScripts = runs
        onChange?()
    }

    /// Shows a stored version without counting it as an edit.
    func show(_ scripts: ScriptSet, runsInheritedScripts: Bool) {
        if scripts != self.scripts {
            self.scripts = scripts
            validate(after: nil)
        }
        if runsInheritedScripts != self.runsInheritedScripts {
            self.runsInheritedScripts = runsInheritedScripts
        }
    }

    /// The levels whose scripts in the shown phase run before these, outermost first, as the draft's own toggle leaves
    /// the chain.
    var alsoRuns: [ScriptsChainLink] {
        let node: RequestNodeID
        switch owner {
        case .project:
            return []
        case .folder(let id), .request(let id):
            node = id
        }
        guard let document = app.library.document(projectID) else {
            return []
        }
        return document.inheritedScriptOwners(of: node, runsInherited: runsInheritedScripts).compactMap { owner in
            guard !owner.scripts[phase].isEmpty else {
                return nil
            }
            switch owner {
            case .project:
                return ScriptsChainLink(owner: .project, title: "Project")
            case .folder(let folder):
                return ScriptsChainLink(owner: .folder(folder.id), title: folder.name)
            case .request:
                return nil
            }
        }
    }
}

/// A folder's or the project's scripts as one draft edits them, with the folder's inherit toggle.
struct ScriptsContent: Equatable {
    var scripts: ScriptSet
    var runsInheritedScripts: Bool

    /// Each script as the draft changed it since `base`, else as stored, so editing one phase keeps the other's
    /// change made elsewhere.
    static func merge(base: ScriptSet, draft: ScriptSet, stored: ScriptSet) -> ScriptSet {
        var merged = draft
        for phase in ScriptPhase.allCases where draft[phase] == base[phase] {
            merged[phase] = stored[phase]
        }
        return merged
    }
}
