import Foundation
import ReqlingKit
import ReqlingScriptProtocol

/// The scripts of the folder or project the detail pane shows (`containerScripts`), and opening a level's scripts from a
/// Scripts pane's "Runs after" line. A request's scripts live in its editor's draft instead.
extension AppModel {
    /// Keeps `containerScripts` on the selected folder or project: the editor it replaces was flushed with the
    /// selection's other edits, and the one it keeps adopts changes made elsewhere. A folder in a project that is listed
    /// but did not load keeps its editor, so the draft saves once the project loads again.
    func syncContainerScripts() {
        let wanted: (project: ProjectID, folder: RequestNodeID?)?
        switch selection {
        case .project(let project)?:
            wanted = (project, nil)
        case .node(let project, let node)?:
            if let document = library.document(project) {
                wanted = document.folder(node) == nil ? nil : (project, node)
            } else {
                wanted = containerScripts?.projectID == project && containerScripts?.folderID == node ? (project, node) : nil
            }
        case nil:
            wanted = nil
        }
        if let current = containerScripts, current.projectID == wanted?.project, current.folderID == wanted?.folder {
            current.adoptExternalChange()
            return
        }
        if let previous = containerScripts, previous.hasStrandedChanges {
            alert = AppAlert(
                title: "Unsaved Changes Discarded",
                message: "The scripts of “\(previous.name)” couldn't be saved because the project isn't available."
            )
        }
        containerScripts = wanted.map { ContainerScriptsEditor(projectID: $0.project, folderID: $0.folder, app: self) }
    }

    /// Shows `link`'s scripts in `phase`.
    func openScripts(_ link: ScriptsChainLink, phase: ScriptPhase, in project: ProjectID) {
        switch link.owner {
        case .project:
            selection = .project(project)
        case .folder(let node), .request(let node):
            selection = .node(project, node)
        }
        containerScripts?.scripts.phase = phase
    }
}
