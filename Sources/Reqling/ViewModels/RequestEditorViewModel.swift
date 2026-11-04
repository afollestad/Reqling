import Foundation
import Observation
import ReqlingKit

enum RequestEditorTab: String, CaseIterable, Identifiable {
    case params = "Params"
    case headers = "Headers"
    case body = "Body"
    case auth = "Auth"
    case options = "Options"

    var id: Self {
        self
    }
}

/// Edits one saved HTTP request. The draft autosaves after a short pause, and every save goes through
/// `ProjectLibrary.mutate`. An edit made elsewhere (MCP, a `git pull`) is adopted while the draft is clean; while it is
/// dirty, the next save merges it in per field (see `merge`), so it survives unless the draft changed the same field.
@MainActor
@Observable
final class RequestEditorViewModel {
    static let autosaveDelay: Duration = .milliseconds(350)

    let projectID: ProjectID
    let requestID: RequestNodeID
    var spec: HTTPRequestSpec {
        didSet {
            if !Self.urlBar(typedURL, describes: spec) {
                typedURL = spec.displayURL
            }
            if spec != savedSpec {
                scheduleSave()
            }
        }
    }
    var tab: RequestEditorTab = .params
    /// A non-blocking note, such as what a cURL import could not carry over.
    var notice: String?
    let response: ResponseViewModel

    /// The URL bar's text exactly as typed. `HTTPRequestSpec.displayURL` cannot show a trailing `?`, `=`, or `&`, so a
    /// bar derived from `spec` on every render erases them mid-typing and jumps the caret. `spec`'s observer re-derives
    /// this only when a change elsewhere (the params table, an adopted external edit, a cURL import) leaves it stale.
    private var typedURL: String

    @ObservationIgnored private unowned let app: AppModel
    /// The spec as last read from or written to the library: the dirtiness baseline and the base of a save's merge.
    @ObservationIgnored private var savedSpec: HTTPRequestSpec
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Set when a save found the project unavailable, so the draft saves once the project loads again rather than
    /// at the next flush. A failed write never sets it: retrying that on every library change would repeat its alert.
    @ObservationIgnored private var isWaitingForProject = false
    /// The name as last seen, so the header keeps it while the project is unavailable.
    @ObservationIgnored private var lastKnownName: String

    init(projectID: ProjectID, requestID: RequestNodeID, app: AppModel) {
        self.projectID = projectID
        self.requestID = requestID
        self.app = app
        let saved = (app.library.document(projectID)?.request(requestID)?.kind.httpSpec ?? HTTPRequestSpec()).normalized()
        spec = saved
        savedSpec = saved
        typedURL = saved.displayURL
        lastKnownName = app.library.document(projectID)?.request(requestID)?.name ?? ""
        response = ResponseViewModel(requestID: requestID, projectID: projectID, runner: app.runner)
    }

    // MARK: - Derived state

    /// What this editor edits, in the sidebar's terms; request IDs alone can repeat across projects.
    var identity: SidebarItem {
        .node(projectID, requestID)
    }

    var name: String {
        guard let current = app.library.document(projectID)?.request(requestID)?.name else {
            return lastKnownName
        }
        lastKnownName = current
        return current
    }

    var tokenContext: TemplateTokenContext {
        TemplateTokenContext(scope: app.scope(for: projectID))
    }

    var autoHeaders: [AutoHeader] {
        HTTPRequestBuilder.autoHeaders(for: spec, userAgent: app.appInfo.userAgent)
    }

    var isSending: Bool {
        app.runner.isInFlight(requestID, in: projectID)
    }

    /// Off for a project saved by a newer Reqling, and while the project is listed but did not load (moved,
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

    /// A draft that could not save because its project is unavailable; replacing this editor discards it.
    var hasStrandedChanges: Bool {
        isWaitingForProject && spec != savedSpec
    }

    /// The URL bar's text: the URL plus enabled query rows, kept as typed. Setting it applies the text to `spec`.
    var urlText: String {
        get { typedURL }
        set {
            typedURL = newValue
            var copy = spec
            copy.applyDisplayURL(newValue)
            if copy != spec {
                spec = copy
            }
        }
    }

    // MARK: - Editing

    func setMethod(_ method: HTTPMethod) {
        spec.method = method
    }

    func toggleAutoHeader(_ header: AutoHeader, enabled: Bool) {
        var disabled = Set(spec.disabledAutoHeaders)
        if enabled {
            disabled.remove(header.key)
        } else {
            disabled.insert(header.key)
        }
        spec.disabledAutoHeaders = disabled.sorted()
    }

    /// Replaces the request with an imported cURL command; returns false when `text` is not one.
    @discardableResult
    func importCurl(_ text: String) -> Bool {
        guard CurlCodec.looksLikeCurl(text) else {
            return false
        }
        do {
            let imported = try CurlCodec.importCommand(text)
            spec = imported.spec
            notice = imported.warnings.isEmpty ? nil : imported.warnings.joined(separator: " ")
        } catch {
            notice = error.localizedDescription
        }
        return true
    }

    /// Picks a file for a binary body or a form-data part.
    func chooseFile() -> ProjectPathReference? {
        guard let url = app.system.chooseFile(prompt: "Choose", allowedTypes: []) else {
            return nil
        }
        return app.reference(for: url, in: projectID)
    }

    func describe(_ reference: ProjectPathReference?) -> String {
        guard let reference else {
            return "No file chosen"
        }
        return app.pathResolver(for: projectID)?.describe(reference) ?? "No file chosen"
    }

    // MARK: - Sending

    func send() {
        flush()
        Task {
            await app.runner.run(requestID, in: projectID)
        }
    }

    func cancel() {
        app.runner.cancel(requestID, in: projectID)
    }

    func copyAsCurl() {
        flush()
        do {
            app.system.copyToPasteboard(CurlCodec.export(try app.runner.prepare(requestID, in: projectID)))
        } catch {
            app.alert = AppAlert(title: "Couldn't Copy as cURL", message: error.message)
        }
    }

    // MARK: - Saving

    /// Saves a dirty draft now; called before sending, switching selection, and quitting. Dirtiness decides, not a
    /// pending timer, so an autosave that failed is retried here instead of being dropped.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    /// Takes the stored version when it changed underneath and the draft is clean. A dirty draft is never replaced:
    /// its save merges the stored change in instead. A save that waited on an unavailable project is rescheduled here.
    func adoptExternalChange() {
        guard spec == savedSpec else {
            resumeDirtyDraft()
            return
        }
        guard let stored = storedSpec(), stored != savedSpec else {
            return
        }
        savedSpec = stored
        spec = stored
    }

    /// Picks an idle dirty draft back up after a library change. A project that loaded again gets its save rescheduled;
    /// one that came back read-only can never take the draft, so it is discarded rather than retried every pause.
    private func resumeDirtyDraft() {
        guard saveTask == nil, let project = app.library.project(projectID), project.document != nil else {
            return
        }
        if project.isReadOnly {
            discardDraft()
        } else if isWaitingForProject {
            scheduleSave()
        }
    }

    /// Drops a draft its read-only project can never take, shows the stored version, and says so.
    private func discardDraft() {
        isWaitingForProject = false
        let stored = storedSpec() ?? savedSpec
        savedSpec = stored
        spec = stored
        app.alert = AppAlert(
            title: "Unsaved Changes Discarded",
            message: "“\(name)” is now read-only: its project was saved by a newer version of Reqling."
        )
    }

    private func storedSpec() -> HTTPRequestSpec? {
        app.library.document(projectID)?.request(requestID)?.kind.httpSpec?.normalized()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let sleep = app.sleep
        saveTask = Task { [weak self] in
            try? await sleep(Self.autosaveDelay)
            guard !Task.isCancelled, let self else {
                return
            }
            saveTask = nil
            save()
            // An edit undone before the pause ends leaves nothing to save, but a stored change may still need adopting.
            adoptExternalChange()
        }
    }

    /// Writes a dirty draft, merged with whatever the library stored since `savedSpec`, and shows the merged result.
    /// A request that no longer exists has nothing to save into and drops the draft silently (its delete is the news);
    /// an unavailable project keeps the draft dirty until it loads again.
    private func save() {
        let draft = spec
        guard draft != savedSpec, let project = app.library.project(projectID) else {
            return
        }
        guard let document = project.document else {
            isWaitingForProject = true
            return
        }
        guard !project.isReadOnly else {
            discardDraft()
            return
        }
        isWaitingForProject = false
        guard let stored = document.request(requestID)?.kind.httpSpec?.normalized() else {
            return
        }
        let merged = stored == savedSpec ? draft : Self.merge(base: savedSpec, draft: draft, stored: stored)
        let saved: Void? = app.perform("Couldn't Save the Request") {
            try app.library.mutate(projectID) { try $0.updateRequest(requestID) { $0.kind = .http(merged) } }
        }
        guard saved != nil else {
            return
        }
        savedSpec = merged
        if spec != merged {
            spec = merged
        }
    }

    /// A three-way merge: each field the draft changed since `base` keeps the draft's value, and every other field
    /// takes the stored one, so a change made elsewhere survives unless the draft changed the same field. The body and
    /// options merge per subfield (switching body mode keeps a raw text edited elsewhere), but each list (query rows,
    /// headers, form fields) and the auth is one field: if both sides edited the same list, the draft's whole list wins.
    /// A field added to `HTTPRequestSpec`, `HTTPBody`, or `HTTPRequestOptions` must be listed here, or the draft wins it
    /// unconditionally.
    private static func merge(base: HTTPRequestSpec, draft: HTTPRequestSpec, stored: HTTPRequestSpec) -> HTTPRequestSpec {
        var merged = draft
        func takeStored<Value: Equatable>(_ field: WritableKeyPath<HTTPRequestSpec, Value>) {
            if draft[keyPath: field] == base[keyPath: field] {
                merged[keyPath: field] = stored[keyPath: field]
            }
        }
        takeStored(\.method)
        takeStored(\.url)
        takeStored(\.queryParameters)
        takeStored(\.headers)
        takeStored(\.disabledAutoHeaders)
        takeStored(\.body.mode)
        takeStored(\.body.raw)
        takeStored(\.body.formData)
        takeStored(\.body.urlEncoded)
        takeStored(\.body.binary)
        takeStored(\.body.graphQL)
        takeStored(\.auth)
        takeStored(\.options.timeoutSeconds)
        takeStored(\.options.followRedirects)
        takeStored(\.options.verifyTLS)
        return merged
    }

    /// Whether the URL bar showing `text` already describes `spec`, i.e. applying it would change nothing.
    private static func urlBar(_ text: String, describes spec: HTTPRequestSpec) -> Bool {
        var applied = spec
        applied.applyDisplayURL(text)
        return applied == spec
    }
}
