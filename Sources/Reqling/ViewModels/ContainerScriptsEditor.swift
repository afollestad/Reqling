import Foundation
import ReqlingKit

/// The scripts of the folder or project the detail pane shows, autosaved through `DocumentDraft` as a request editor's
/// are: merged with a change made elsewhere, kept while the project is unavailable, discarded once it is read-only.
@MainActor
final class ContainerScriptsEditor {
    let projectID: ProjectID
    /// `nil` for the project's own scripts.
    let folderID: RequestNodeID?
    let scripts: ScriptsEditorModel
    private let draft: DocumentDraft<ScriptsContent>

    init(projectID: ProjectID, folderID: RequestNodeID?, app: AppModel) {
        self.projectID = projectID
        self.folderID = folderID
        let draft = DocumentDraft(
            projectID: projectID,
            app: app,
            coding: Self.coding(folderID),
            fallback: ScriptsContent(scripts: ScriptSet(), runsInheritedScripts: true)
        )
        self.draft = draft
        scripts = ScriptsEditorModel(
            projectID: projectID,
            owner: folderID.map(ScriptsOwnerID.folder) ?? .project,
            scripts: draft.saved.scripts,
            runsInheritedScripts: draft.saved.runsInheritedScripts,
            app: app
        )
        scripts.onChange = { [weak self] in
            guard let self else {
                return
            }
            self.draft.draftDidChange(content)
        }
        draft.onAutosave = { [weak self] in
            guard let self else {
                return
            }
            show(self.draft.autosave(content))
        }
    }

    var name: String {
        draft.name
    }

    var isReadOnly: Bool {
        draft.isReadOnly
    }

    var hasStrandedChanges: Bool {
        draft.hasStrandedChanges(content)
    }

    func flush() {
        show(draft.flush(content))
    }

    func adoptExternalChange() {
        show(draft.adoptExternalChange(content))
    }

    private var content: ScriptsContent {
        ScriptsContent(scripts: scripts.scripts, runsInheritedScripts: scripts.runsInheritedScripts)
    }

    private func show(_ stored: ScriptsContent?) {
        if let stored {
            scripts.show(stored.scripts, runsInheritedScripts: stored.runsInheritedScripts)
        }
    }

    private static func coding(_ folderID: RequestNodeID?) -> DocumentDraft<ScriptsContent>.Coding {
        DocumentDraft.Coding(
            read: { document in
                guard let folderID else {
                    return ScriptsContent(scripts: document.scripts, runsInheritedScripts: true)
                }
                return document.folder(folderID).map { ScriptsContent(scripts: $0.scripts, runsInheritedScripts: $0.runsInheritedScripts) }
            },
            write: { document, content in
                guard let folderID else {
                    document.scripts = content.scripts
                    return
                }
                try document.updateFolder(folderID) { folder in
                    folder.scripts = content.scripts
                    folder.runsInheritedScripts = content.runsInheritedScripts
                }
            },
            merge: { base, draft, stored in
                ScriptsContent(
                    scripts: ScriptsContent.merge(base: base.scripts, draft: draft.scripts, stored: stored.scripts),
                    runsInheritedScripts: draft.runsInheritedScripts == base.runsInheritedScripts
                        ? stored.runsInheritedScripts
                        : draft.runsInheritedScripts
                )
            },
            name: { document in folderID.map { document.folder($0)?.name } ?? document.name },
            noun: folderID == nil ? "the project's scripts" : "this folder's scripts",
            failureTitle: "Couldn't Save the Scripts"
        )
    }
}
