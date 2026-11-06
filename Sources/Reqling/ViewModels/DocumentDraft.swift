import Foundation
import ReqlingKit

/// The lifecycle every autosaving editor of part of a project shares (a request, or a folder's or the project's
/// scripts): the dirtiness baseline, the autosave pause, the three-way merge on save, adopting a change stored elsewhere
/// (MCP, a `git pull`) while the draft is clean, and a draft kept unsaved while its project is unavailable. A dirty
/// draft is never replaced by a stored change: its save merges the change in instead, so it survives unless the draft
/// changed the same field or, in a list, the same row.
///
/// Each editor owns its observable content and passes it in. A method that returns content hands back what the editor
/// should now show; `nil` means keep showing the draft. Nothing here is observable: the baseline and timers are
/// bookkeeping, and the reads that should re-render a view (the library's projects) go through `app` as the view asks.
@MainActor
final class DocumentDraft<Content: Equatable> {
    /// How one kind of draft reads, writes, and merges what it edits.
    struct Coding {
        /// What the document holds, or `nil` once it holds none: the part was deleted, or a request changed kind.
        let read: (ProjectDocument) -> Content?
        let write: (inout ProjectDocument, Content) throws -> Void
        /// Keeps each field `draft` changed since `base`, and takes `stored` for the rest.
        let merge: (_ base: Content, _ draft: Content, _ stored: Content) -> Content
        /// The edited part's name as the document has it, for the header and messages.
        let name: (ProjectDocument) -> String?
        /// What the draft edits, as the unavailable note names it: "this request".
        let noun: String
        /// The title of the alert a failed save raises.
        let failureTitle: String
    }

    let projectID: ProjectID
    /// The content as last read from or written to the library: the dirtiness baseline and the base of a save's merge.
    private(set) var saved: Content
    /// Called when the autosave pause ends; the editor answers with `autosave(_:)` on its current draft.
    var onAutosave: (() -> Void)?

    private unowned let app: AppModel
    private let coding: Coding
    private var saveTask: Task<Void, Never>?
    /// Set when a save found the project unavailable, so the draft saves once the project loads again rather than
    /// at the next flush. A failed write never sets it: retrying that on every library change would repeat its alert.
    private var isWaitingForProject = false
    /// The name as last seen, so the header keeps it while the project is unavailable.
    private var lastKnownName: String

    init(projectID: ProjectID, app: AppModel, coding: Coding, fallback: Content) {
        self.projectID = projectID
        self.app = app
        self.coding = coding
        let document = app.library.document(projectID)
        saved = document.flatMap(coding.read) ?? fallback
        lastKnownName = document.flatMap(coding.name) ?? ""
    }

    // MARK: - Derived state

    var name: String {
        guard let current = app.library.document(projectID).flatMap(coding.name) else {
            return lastKnownName
        }
        lastKnownName = current
        return current
    }

    /// On for a project saved by a newer Reqling, and while the project is listed but did not load (moved,
    /// mid-checkout): there is nothing to save into then, so anything typed would only be stranded.
    var isReadOnly: Bool {
        guard let project = app.library.project(projectID) else {
            return true
        }
        return project.isReadOnly || project.document == nil
    }

    /// Explains the pause while the project is listed but did not load; `nil` otherwise.
    var unavailableNote: String? {
        guard let project = app.library.project(projectID), project.document == nil else {
            return nil
        }
        return "“\(project.name)” isn't available right now, so \(coding.noun) is read-only until it loads again. "
            + "Unsaved changes save then, as long as this request stays open."
    }

    /// The draft differs from what was last read or written, whether or not its save is still pending.
    func isDirty(_ draft: Content) -> Bool {
        draft != saved
    }

    /// A draft that could not save because its project is unavailable; replacing its editor discards it.
    func hasStrandedChanges(_ draft: Content) -> Bool {
        isWaitingForProject && draft != saved
    }

    // MARK: - Saving

    /// Starts (or restarts) the autosave pause when `draft` differs from what is stored.
    func draftDidChange(_ draft: Content) {
        if draft != saved {
            scheduleSave()
        }
    }

    /// Saves a dirty draft now; editors call it before sending, switching selection, and quitting. Dirtiness decides,
    /// not a pending timer, so an autosave that failed is retried here instead of being dropped.
    func flush(_ draft: Content) -> Content? {
        saveTask?.cancel()
        saveTask = nil
        return save(draft)
    }

    /// The autosave's pass: saves the draft, then adopts a stored change, since an edit undone before the pause ended
    /// leaves nothing to save but may still have a change from elsewhere waiting.
    func autosave(_ draft: Content) -> Content? {
        let merged = save(draft)
        return adoptExternalChange(merged ?? draft) ?? merged
    }

    /// Takes the stored version when it changed underneath and the draft is clean. A save that waited on an
    /// unavailable project is rescheduled here.
    func adoptExternalChange(_ draft: Content) -> Content? {
        guard draft == saved else {
            return resumeDirtyDraft()
        }
        guard let stored = stored(), stored != saved else {
            return nil
        }
        saved = stored
        return stored
    }

    /// Picks an idle dirty draft back up after a library change. A project that loaded again gets its save rescheduled;
    /// one that came back read-only can never take the draft, so it is discarded rather than retried every pause.
    private func resumeDirtyDraft() -> Content? {
        guard saveTask == nil, let project = app.library.project(projectID), project.document != nil else {
            return nil
        }
        if project.isReadOnly {
            return discardDraft()
        }
        if isWaitingForProject {
            scheduleSave()
        }
        return nil
    }

    /// Drops a draft its read-only project can never take, shows the stored version, and says so.
    private func discardDraft() -> Content {
        isWaitingForProject = false
        let stored = stored() ?? saved
        saved = stored
        app.alert = AppAlert(
            title: "Unsaved Changes Discarded",
            message: "“\(name)” is now read-only: its project was saved by a newer version of Reqling."
        )
        return stored
    }

    private func stored() -> Content? {
        app.library.document(projectID).flatMap(coding.read)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let sleep = app.sleep
        saveTask = Task { [weak self] in
            try? await sleep(RequestEditorViewModel.autosaveDelay)
            guard !Task.isCancelled, let self else {
                return
            }
            saveTask = nil
            onAutosave?()
        }
    }

    /// Writes a dirty draft, merged with whatever the library stored since `saved`, and returns the merged result.
    /// A part that no longer exists has nothing to save into and drops the draft silently (its delete is the news);
    /// an unavailable project keeps the draft dirty until it loads again.
    private func save(_ draft: Content) -> Content? {
        guard draft != saved, let project = app.library.project(projectID) else {
            return nil
        }
        guard let document = project.document else {
            isWaitingForProject = true
            return nil
        }
        guard !project.isReadOnly else {
            return discardDraft()
        }
        isWaitingForProject = false
        guard let stored = coding.read(document) else {
            return nil
        }
        let merged = stored == saved ? draft : coding.merge(saved, draft, stored)
        let write = coding.write
        let written: Void? = app.perform(coding.failureTitle) {
            try app.library.mutate(projectID) { try write(&$0, merged) }
        }
        guard written != nil else {
            return nil
        }
        saved = merged
        return merged
    }
}

/// What a request editor edits and saves together: the spec, and the request's own scripts and whether it runs the
/// scripts of the folders and project around it.
struct RequestContent<Spec: Equatable>: Equatable {
    var spec: Spec
    var scripts: ScriptSet
    var runsInheritedScripts: Bool
}

extension DocumentDraft {
    /// A request editor's coding: the spec through `read`, `wrap`, and `merge`, and the scripts and their toggle
    /// merged per script, so editing the pre-request script keeps a post-response one changed elsewhere.
    static func request<Spec>(
        _ requestID: RequestNodeID,
        read: @escaping (RequestKind) -> Spec?,
        wrap: @escaping (Spec) -> RequestKind,
        merge: @escaping (_ base: Spec, _ draft: Spec, _ stored: Spec) -> Spec
    ) -> Coding where Content == RequestContent<Spec> {
        Coding(
            read: { document in
                document.request(requestID).flatMap { request in
                    read(request.kind).map {
                        RequestContent(spec: $0, scripts: request.scripts, runsInheritedScripts: request.runsInheritedScripts)
                    }
                }
            },
            write: { document, content in
                try document.updateRequest(requestID) { request in
                    request.kind = wrap(content.spec)
                    request.scripts = content.scripts
                    request.runsInheritedScripts = content.runsInheritedScripts
                }
            },
            merge: { base, draft, stored in
                RequestContent(
                    spec: merge(base.spec, draft.spec, stored.spec),
                    scripts: ScriptsContent.merge(base: base.scripts, draft: draft.scripts, stored: stored.scripts),
                    runsInheritedScripts: draft.runsInheritedScripts == base.runsInheritedScripts
                        ? stored.runsInheritedScripts
                        : draft.runsInheritedScripts
                )
            },
            name: { $0.request(requestID)?.name },
            noun: "this request",
            failureTitle: "Couldn't Save the Request"
        )
    }
}
