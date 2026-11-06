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

/// Edits one saved HTTP request. The draft autosaves after a short pause through `RequestDraft`, which also adopts
/// an edit made elsewhere (MCP, a `git pull`) while the draft is clean and merges it in per field and row (see `merge`)
/// while it is dirty.
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
            draft.draftDidChange(spec)
            syncGraphQL(from: oldValue)
        }
    }
    var tab: RequestEditorTab = .params
    /// A non-blocking note, such as what a cURL import could not carry over.
    var notice: String?
    let history: RunHistoryViewModel
    let response: ResponseViewModel
    /// The GraphQL body's schema and checking, while the request sends one (`RequestEditorViewModel+GraphQL`).
    var graphQL: GraphQLEditorModel?

    /// The URL bar's text exactly as typed. `HTTPRequestSpec.displayURL` cannot show a trailing `?`, `=`, or `&`, so a
    /// bar derived from `spec` on every render erases them mid-typing and jumps the caret. `spec`'s observer re-derives
    /// this only when a change elsewhere (the params table, an adopted external edit, a cURL import) leaves it stale.
    private var typedURL: String

    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored private let draft: RequestDraft<HTTPRequestSpec>
    /// `autoHeaders`' memo, keyed on the only parts of the spec it reads; the user agent is fixed for the app's life.
    @ObservationIgnored private var autoHeadersCache: (key: AutoHeadersKey, value: [AutoHeader])?

    init(projectID: ProjectID, requestID: RequestNodeID, app: AppModel) {
        self.projectID = projectID
        self.requestID = requestID
        self.app = app
        let draft = RequestDraft(projectID: projectID, requestID: requestID, app: app, coding: Self.coding, fallback: HTTPRequestSpec())
        self.draft = draft
        spec = draft.saved
        typedURL = draft.saved.displayURL
        history = RunHistoryViewModel(projectID: projectID, requestID: requestID, app: app)
        response = ResponseViewModel(requestID: requestID, projectID: projectID, runner: app.runner, history: history)
        draft.onAutosave = { [weak self] in
            guard let self else {
                return
            }
            show(self.draft.autosave(spec))
        }
        history.editor = self
        syncGraphQL(from: nil)
    }

    // MARK: - Derived state

    var name: String {
        draft.name
    }

    var tokenContext: TemplateTokenContext {
        app.tokenContext(for: projectID)
    }

    var autoHeaders: [AutoHeader] {
        // Read every observable input before consulting the cache, so observation keeps tracking them.
        let body = spec.body
        let key = AutoHeadersKey(
            allowsBody: spec.method.bodyPolicy.allowsBody,
            mode: body.mode,
            rawContentType: body.raw.contentType,
            binaryContentType: body.binary.contentType
        )
        if let autoHeadersCache, autoHeadersCache.key == key {
            return autoHeadersCache.value
        }
        let value = HTTPRequestBuilder.autoHeaders(for: spec, userAgent: app.appInfo.userAgent)
        autoHeadersCache = (key, value)
        return value
    }

    var isSending: Bool {
        app.runner.isInFlight(requestID, in: projectID)
    }

    /// The response is an event stream still open, which Cancel stops, so it reads Stop.
    var isStreaming: Bool {
        app.runner.eventStreams.contains(RunKey(requestID, in: projectID))
    }

    var isReadOnly: Bool {
        draft.isReadOnly
    }

    var unavailableNote: String? {
        draft.unavailableNote
    }

    var hasStrandedChanges: Bool {
        draft.hasStrandedChanges(spec)
    }

    var hasUnsavedChanges: Bool {
        draft.isDirty(spec)
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

    /// Puts a past run's template back, as `importCurl` replaces the request; autosave stores it.
    func restore(_ spec: RequestKind, from date: Date) {
        guard !isReadOnly, let restored = spec.httpSpec else {
            return
        }
        self.spec = restored
        notice = RunHistoryViewModel.restoredNotice(sentAt: date)
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
        history.showLatest()
        Task {
            await app.runner.run(requestID, in: projectID, options: RunOptions(mayPromptForTrust: true))
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

    func flush() {
        show(draft.flush(spec))
    }

    func adoptExternalChange() {
        show(draft.adoptExternalChange(spec))
    }

    private func show(_ stored: HTTPRequestSpec?) {
        if let stored, stored != spec {
            spec = stored
        }
    }

    private static let coding = RequestDraft<HTTPRequestSpec>.Coding(
        read: { $0.httpSpec?.normalized() },
        wrap: { .http($0) },
        merge: merge(base:draft:stored:)
    )

    /// A three-way merge: each field the draft changed since `base` keeps the draft's value, and every other field
    /// takes the stored one, so a change made elsewhere survives unless the draft changed the same field. The body and
    /// options merge per subfield (switching body mode keeps a raw text edited elsewhere; editing a GraphQL query keeps
    /// a schema source chosen elsewhere), and each list (query rows,
    /// headers, form fields) row by row by ID (`ListMerge`), so a header removed elsewhere stays removed unless the
    /// draft edited it. The auth is one field. A field added to `HTTPRequestSpec`, `HTTPBody`, or `HTTPRequestOptions`
    /// (or `GraphQLBody`) must be listed here, or the draft wins it unconditionally.
    private nonisolated static func merge(base: HTTPRequestSpec, draft: HTTPRequestSpec, stored: HTTPRequestSpec) -> HTTPRequestSpec {
        var merged = draft
        func takeStored<Value: Equatable>(_ field: WritableKeyPath<HTTPRequestSpec, Value>) {
            if draft[keyPath: field] == base[keyPath: field] {
                merged[keyPath: field] = stored[keyPath: field]
            }
        }
        func mergeRows<Row: ListRow>(_ field: WritableKeyPath<HTTPRequestSpec, [Row]>) {
            merged[keyPath: field] = ListMerge.merge(base: base[keyPath: field], draft: draft[keyPath: field], stored: stored[keyPath: field])
        }
        takeStored(\.method)
        takeStored(\.url)
        mergeRows(\.queryParameters)
        mergeRows(\.headers)
        takeStored(\.disabledAutoHeaders)
        takeStored(\.body.mode)
        takeStored(\.body.raw)
        mergeRows(\.body.formData)
        mergeRows(\.body.urlEncoded)
        takeStored(\.body.binary)
        takeStored(\.body.graphQL.query)
        takeStored(\.body.graphQL.variables)
        takeStored(\.body.graphQL.operationName)
        takeStored(\.body.graphQL.schema)
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

/// The parts of a spec `HTTPRequestBuilder.autoHeaders(for:userAgent:)` reads.
private struct AutoHeadersKey: Equatable {
    let allowsBody: Bool
    let mode: HTTPBodyMode
    let rawContentType: String
    let binaryContentType: String?
}
