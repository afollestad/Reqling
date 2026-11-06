import Foundation
import Observation
import ReqlingKit

enum WebSocketEditorTab: String, CaseIterable, Identifiable {
    case messages = "Messages"
    case params = "Params"
    case headers = "Headers"
    case auth = "Auth"
    case scripts = "Scripts"
    case options = "Options"

    var id: Self {
        self
    }
}

/// Edits one saved WebSocket request with the same `RequestDraft` lifecycle as `RequestEditorViewModel`: autosave after
/// a pause, a merge with whatever was stored meanwhile (see `merge`), adoption while clean, and a draft kept while its
/// project is unavailable.
///
/// While the connection is open, Send (⌘Return) sends the composer's message instead of connecting again, as a gRPC
/// call's composer does; each saved message can be sent too, and neither needs the project to be writable.
@MainActor
@Observable
final class WebSocketEditorViewModel {
    let projectID: ProjectID
    let requestID: RequestNodeID
    var spec: WebSocketRequestSpec {
        didSet {
            if !Self.urlBar(typedURL, describes: spec) {
                typedURL = spec.displayURL
            }
            if Self.subprotocols(in: typedSubprotocols) != spec.subprotocols {
                typedSubprotocols = spec.subprotocols.joined(separator: ", ")
            }
            draft.draftDidChange(content)
        }
    }
    var tab: WebSocketEditorTab = .messages
    /// The next message for an open connection. Never saved unless Save adds it to the request's messages.
    var liveMessage = WebSocketMessage(sendsOnConnect: true)
    /// Why the last send or ping failed; the next one clears it.
    private(set) var liveError: String?
    /// A non-blocking note, such as which run a restore put back.
    var notice: String?
    let history: RunHistoryViewModel
    let response: WebSocketResponseViewModel

    /// The URL bar's text exactly as typed, kept like `RequestEditorViewModel`'s, so a trailing `?`, `=`, or `&` isn't
    /// erased mid-typing.
    private var typedURL: String
    /// The subprotocols field as typed, so a trailing comma survives until the next name is typed.
    private var typedSubprotocols: String

    @ObservationIgnored private unowned let app: AppModel
    /// The request's own scripts, which the draft saves with the spec.
    let scriptsEditor: ScriptsEditorModel

    @ObservationIgnored private let draft: DocumentDraft<RequestContent<WebSocketRequestSpec>>
    /// `autoHeaders`' memo, keyed on the only parts of the spec it reads; the user agent is fixed for the app's life.
    @ObservationIgnored private var autoHeadersCache: (key: AutoHeadersKey, value: [AutoHeader])?

    init(projectID: ProjectID, requestID: RequestNodeID, app: AppModel) {
        self.projectID = projectID
        self.requestID = requestID
        self.app = app
        let draft = DocumentDraft(
            projectID: projectID,
            app: app,
            coding: Self.coding(requestID),
            fallback: RequestContent(spec: WebSocketRequestSpec(), scripts: ScriptSet(), runsInheritedScripts: true)
        )
        self.draft = draft
        spec = draft.saved.spec
        scriptsEditor = ScriptsEditorModel(
            projectID: projectID,
            owner: .request(requestID),
            scripts: draft.saved.scripts,
            runsInheritedScripts: draft.saved.runsInheritedScripts,
            app: app
        )
        typedURL = draft.saved.spec.displayURL
        typedSubprotocols = draft.saved.spec.subprotocols.joined(separator: ", ")
        history = RunHistoryViewModel(projectID: projectID, requestID: requestID, app: app)
        response = WebSocketResponseViewModel(requestID: requestID, projectID: projectID, runner: app.runner, history: history)
        draft.onAutosave = { [weak self] in
            guard let self else {
                return
            }
            show(self.draft.autosave(content))
        }
        scriptsEditor.onChange = { [weak self] in
            guard let self else {
                return
            }
            self.draft.draftDidChange(content)
        }
        history.editor = self
    }

    // MARK: - Derived state

    var name: String {
        draft.name
    }

    var tokenContext: TemplateTokenContext {
        app.tokenContext(for: projectID, request: requestID)
    }

    var isReadOnly: Bool {
        draft.isReadOnly
    }

    var unavailableNote: String? {
        draft.unavailableNote
    }

    var hasStrandedChanges: Bool {
        draft.hasStrandedChanges(content)
    }

    var hasUnsavedChanges: Bool {
        draft.isDirty(content)
    }

    /// Connecting, open, or closing.
    var isSending: Bool {
        app.runner.isInFlight(requestID, in: projectID)
    }

    /// The connection is open for sending and pinging.
    var isOpen: Bool {
        app.runner.openSockets.contains(RunKey(requestID, in: projectID))
    }

    var autoHeaders: [AutoHeader] {
        // Read every observable input before consulting the cache, so observation keeps tracking them.
        let key = AutoHeadersKey(url: spec.url, subprotocols: spec.subprotocols)
        if let autoHeadersCache, autoHeadersCache.key == key {
            return autoHeadersCache.value
        }
        let value = HTTPRequestBuilder.autoHeaders(for: spec, userAgent: app.appInfo.userAgent)
        autoHeadersCache = (key, value)
        return value
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

    /// The subprotocols, comma-separated as `Sec-WebSocket-Protocol` lists them. Setting it stores each name.
    var subprotocolsText: String {
        get { typedSubprotocols }
        set {
            typedSubprotocols = newValue
            let names = Self.subprotocols(in: newValue)
            if names != spec.subprotocols {
                spec.subprotocols = names
            }
        }
    }

    // MARK: - Editing

    func toggleAutoHeader(_ header: AutoHeader, enabled: Bool) {
        spec.setSends(header, enabled)
    }

    func addMessage() {
        spec.messages.append(WebSocketMessage())
    }

    /// Adds the composer's message to the request's, so a conversation tried live can be replayed.
    func saveLiveMessage() {
        guard !isReadOnly else {
            return
        }
        spec.messages.append(WebSocketMessage(format: liveMessage.format, text: liveMessage.text))
    }

    /// Puts a past run's template back; autosave stores it.
    func restore(_ spec: RequestKind, from date: Date) {
        guard !isReadOnly, let restored = spec.webSocketSpec else {
            return
        }
        self.spec = restored
        notice = RunHistoryViewModel.restoredNotice(sentAt: date)
    }

    // MARK: - Connection

    /// Connects, or while open sends the composer's message: a new run would close the open connection, and ⌘Return
    /// (the menu's Send) is also how the composer sends. It shows the Messages tab first, where the composer is.
    func send() {
        // Either way the latest run is where the message goes.
        history.showLatest()
        guard !isOpen else {
            tab = .messages
            sendLiveMessage()
            return
        }
        flush()
        liveError = nil
        let runner = app.runner
        let requestID = requestID
        let projectID = projectID
        Task {
            await runner.run(requestID, in: projectID, options: RunOptions(mayPromptForTrust: true))
        }
    }

    /// Disconnects: closes an open connection with 1000, or abandons one still connecting.
    func cancel() {
        app.runner.cancel(requestID, in: projectID)
    }

    func sendLiveMessage() {
        let message = liveMessage
        perform { runner throws(RunFailure) in try runner.sendWebSocketMessage(message, to: requestID, in: projectID) }
    }

    /// Sends one of the request's messages as it stands in the editor, saved or not.
    func sendSaved(_ message: WebSocketMessage) {
        history.showLatest()
        perform { runner throws(RunFailure) in try runner.sendWebSocketMessage(message, to: requestID, in: projectID) }
    }

    func ping() {
        history.showLatest()
        perform { runner throws(RunFailure) in try runner.pingWebSocket(requestID, in: projectID) }
    }

    private func perform(_ action: (RequestRunner) throws(RunFailure) -> Void) {
        do {
            try action(app.runner)
            liveError = nil
        } catch {
            liveError = error.message
        }
    }

    // MARK: - Saving

    func flush() {
        show(draft.flush(content))
    }

    func adoptExternalChange() {
        show(draft.adoptExternalChange(content))
    }

    private var content: RequestContent<WebSocketRequestSpec> {
        RequestContent(spec: spec, scripts: scriptsEditor.scripts, runsInheritedScripts: scriptsEditor.runsInheritedScripts)
    }

    /// Shows a stored version: the scripts first, so the spec's observer sees both stored and schedules no save.
    private func show(_ stored: RequestContent<WebSocketRequestSpec>?) {
        guard let stored else {
            return
        }
        scriptsEditor.show(stored.scripts, runsInheritedScripts: stored.runsInheritedScripts)
        if stored.spec != spec {
            spec = stored.spec
        }
    }

    private static func coding(_ requestID: RequestNodeID) -> DocumentDraft<RequestContent<WebSocketRequestSpec>>.Coding {
        DocumentDraft.request(requestID, read: { $0.webSocketSpec?.normalized() }, wrap: { .webSocket($0) }, merge: merge(base:draft:stored:))
    }

    /// A three-way merge: each field the draft changed since `base` keeps the draft's value, and every other field
    /// takes the stored one, so a change made elsewhere survives unless the draft changed the same field. Each list
    /// (query rows, headers, messages) merges row by row by ID (`ListMerge`), so a message an agent added survives an
    /// edit to another. A field added to `WebSocketRequestSpec` or `WebSocketRequestOptions` must be listed here, or the
    /// draft wins it unconditionally.
    private nonisolated static func merge(
        base: WebSocketRequestSpec,
        draft: WebSocketRequestSpec,
        stored: WebSocketRequestSpec
    ) -> WebSocketRequestSpec {
        var merged = draft
        func takeStored<Value: Equatable>(_ field: WritableKeyPath<WebSocketRequestSpec, Value>) {
            if draft[keyPath: field] == base[keyPath: field] {
                merged[keyPath: field] = stored[keyPath: field]
            }
        }
        func mergeRows<Row: ListRow>(_ field: WritableKeyPath<WebSocketRequestSpec, [Row]>) {
            merged[keyPath: field] = ListMerge.merge(base: base[keyPath: field], draft: draft[keyPath: field], stored: stored[keyPath: field])
        }
        takeStored(\.url)
        mergeRows(\.queryParameters)
        mergeRows(\.headers)
        takeStored(\.disabledAutoHeaders)
        takeStored(\.enabledAutoHeaders)
        takeStored(\.subprotocols)
        mergeRows(\.messages)
        takeStored(\.auth)
        takeStored(\.options.timeoutSeconds)
        takeStored(\.options.verifyTLS)
        takeStored(\.options.keepaliveSeconds)
        return merged
    }

    /// Whether the URL bar showing `text` already describes `spec`, i.e. applying it would change nothing.
    private static func urlBar(_ text: String, describes spec: WebSocketRequestSpec) -> Bool {
        var applied = spec
        applied.applyDisplayURL(text)
        return applied == spec
    }

    private static func subprotocols(in text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension WebSocketEditorViewModel: RequestEditing {
    var kind: RequestKind.Name {
        .webSocket
    }

    var currentSpec: RequestKind {
        .webSocket(spec)
    }
}

/// The parts of a spec `HTTPRequestBuilder.autoHeaders(for:userAgent:)` reads for a WebSocket.
private struct AutoHeadersKey: Equatable {
    let url: String
    let subprotocols: [String]
}
