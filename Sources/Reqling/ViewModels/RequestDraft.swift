import Foundation
import ReqlingKit

/// The saved-request lifecycle both request editors share: the dirtiness baseline, the autosave pause, the three-way
/// merge on save, adopting a change stored elsewhere (MCP, a `git pull`) while the draft is clean, and a draft kept
/// unsaved while its project is unavailable. A dirty draft is never replaced by a stored change: its save merges the
/// change in instead, so it survives unless the draft changed the same field.
///
/// Each editor owns its observable `spec` and passes it in. A method that returns a spec hands back what the editor
/// should now show; `nil` means keep showing the draft. Nothing here is observable: the baseline and timers are
/// bookkeeping, and the reads that should re-render a view (the library's projects) go through `app` as the view asks.
@MainActor
final class RequestDraft<Spec: Equatable> {
    /// How one request kind reads, writes, and merges its spec.
    struct Coding {
        /// The spec a stored request holds, or `nil` when it is another kind.
        let read: (RequestKind) -> Spec?
        let wrap: (Spec) -> RequestKind
        /// Keeps each field `draft` changed since `base`, and takes `stored` for the rest.
        let merge: (_ base: Spec, _ draft: Spec, _ stored: Spec) -> Spec
    }

    let projectID: ProjectID
    let requestID: RequestNodeID
    /// The spec as last read from or written to the library: the dirtiness baseline and the base of a save's merge.
    private(set) var saved: Spec
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

    init(projectID: ProjectID, requestID: RequestNodeID, app: AppModel, coding: Coding, fallback: Spec) {
        self.projectID = projectID
        self.requestID = requestID
        self.app = app
        self.coding = coding
        let request = app.library.document(projectID)?.request(requestID)
        saved = request.flatMap { coding.read($0.kind) } ?? fallback
        lastKnownName = request?.name ?? ""
    }

    // MARK: - Derived state

    var name: String {
        guard let current = app.library.document(projectID)?.request(requestID)?.name else {
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
        return "“\(project.name)” isn't available right now, so this request is read-only until it loads again. "
            + "Unsaved changes save then, as long as this request stays open."
    }

    /// The draft differs from what was last read or written, whether or not its save is still pending.
    func isDirty(_ draft: Spec) -> Bool {
        draft != saved
    }

    /// A draft that could not save because its project is unavailable; replacing its editor discards it.
    func hasStrandedChanges(_ draft: Spec) -> Bool {
        isWaitingForProject && draft != saved
    }

    // MARK: - Saving

    /// Starts (or restarts) the autosave pause when `draft` differs from what is stored.
    func draftDidChange(_ draft: Spec) {
        if draft != saved {
            scheduleSave()
        }
    }

    /// Saves a dirty draft now; editors call it before sending, switching selection, and quitting. Dirtiness decides,
    /// not a pending timer, so an autosave that failed is retried here instead of being dropped.
    func flush(_ draft: Spec) -> Spec? {
        saveTask?.cancel()
        saveTask = nil
        return save(draft)
    }

    /// The autosave's pass: saves the draft, then adopts a stored change, since an edit undone before the pause ended
    /// leaves nothing to save but may still have a change from elsewhere waiting.
    func autosave(_ draft: Spec) -> Spec? {
        let merged = save(draft)
        return adoptExternalChange(merged ?? draft) ?? merged
    }

    /// Takes the stored version when it changed underneath and the draft is clean. A save that waited on an
    /// unavailable project is rescheduled here.
    func adoptExternalChange(_ draft: Spec) -> Spec? {
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
    private func resumeDirtyDraft() -> Spec? {
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
    private func discardDraft() -> Spec {
        isWaitingForProject = false
        let stored = stored() ?? saved
        saved = stored
        app.alert = AppAlert(
            title: "Unsaved Changes Discarded",
            message: "“\(name)” is now read-only: its project was saved by a newer version of Reqling."
        )
        return stored
    }

    private func stored() -> Spec? {
        app.library.document(projectID)?.request(requestID).flatMap { coding.read($0.kind) }
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
    /// A request that no longer exists has nothing to save into and drops the draft silently (its delete is the news);
    /// an unavailable project keeps the draft dirty until it loads again.
    private func save(_ draft: Spec) -> Spec? {
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
        guard let stored = document.request(requestID).flatMap({ coding.read($0.kind) }) else {
            return nil
        }
        let merged = stored == saved ? draft : coding.merge(saved, draft, stored)
        let kind = coding.wrap(merged)
        let requestID = requestID
        let written: Void? = app.perform("Couldn't Save the Request") {
            try app.library.mutate(projectID) { try $0.updateRequest(requestID) { $0.kind = kind } }
        }
        guard written != nil else {
            return nil
        }
        saved = merged
        return merged
    }
}
