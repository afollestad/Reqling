import Foundation
import Observation
import ReqlingKit
import UniformTypeIdentifiers

/// The editor's sections; `GRPCEditorPane.title(for:listsMessages:)` names them, as Messages depends on the call kind.
enum GRPCEditorTab: CaseIterable, Identifiable {
    case messages
    case metadata
    case auth
    case scripts
    case options

    var id: Self {
        self
    }
}

/// Edits one saved gRPC request with the same `RequestDraft` lifecycle as `RequestEditorViewModel`: autosave after a
/// pause, a merge with whatever was stored meanwhile (see `merge`), adoption while clean, and a draft kept while its
/// project is unavailable.
///
/// The call's kind comes from the picked method's descriptor in `schema`, never from the spec, so the editor lists
/// several messages exactly when Send will stream them.
@MainActor
@Observable
final class GRPCEditorViewModel {
    let projectID: ProjectID
    let requestID: RequestNodeID
    var spec: GRPCRequestSpec {
        didSet {
            draft.draftDidChange(content)
            if Self.changesSchema(from: oldValue, to: spec) {
                schema.scheduleReload()
            }
        }
    }
    var tab: GRPCEditorTab = .messages
    /// The next message for an open call. Never saved: what an open call sends is a one-off.
    var liveMessage = "{}"
    /// Why the last live send failed; the next send clears it.
    private(set) var liveError: String?
    /// A non-blocking note, such as which run a restore put back.
    var notice: String?
    let history: RunHistoryViewModel
    let response: GRPCResponseViewModel
    let schema: GRPCSchemaLoader

    @ObservationIgnored private unowned let app: AppModel
    /// The request's own scripts, which the draft saves with the spec.
    let scriptsEditor: ScriptsEditorModel

    @ObservationIgnored private let draft: DocumentDraft<RequestContent<GRPCRequestSpec>>

    init(projectID: ProjectID, requestID: RequestNodeID, app: AppModel) {
        self.projectID = projectID
        self.requestID = requestID
        self.app = app
        let draft = DocumentDraft(
            projectID: projectID,
            app: app,
            coding: Self.coding(requestID),
            fallback: RequestContent(spec: GRPCRequestSpec(), scripts: ScriptSet(), runsInheritedScripts: true)
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
        history = RunHistoryViewModel(projectID: projectID, requestID: requestID, app: app)
        response = GRPCResponseViewModel(requestID: requestID, projectID: projectID, runner: app.runner, history: history)
        schema = GRPCSchemaLoader(projectID: projectID, requestID: requestID, app: app)
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
        schema.prepare = { [weak self] in
            self?.flush()
        }
        schema.start()
        history.editor = self
    }

    /// Puts a past run's template back; autosave stores it, and the schema reloads if its source changed.
    func restore(_ spec: RequestKind, from date: Date) {
        guard !isReadOnly, let restored = spec.grpcSpec else {
            return
        }
        self.spec = restored
        notice = RunHistoryViewModel.restoredNotice(sentAt: date)
    }

    // MARK: - Derived state

    var name: String {
        draft.name
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

    var tokenContext: TemplateTokenContext {
        app.tokenContext(for: projectID, request: requestID)
    }

    var isSending: Bool {
        app.runner.isInFlight(requestID, in: projectID)
    }

    /// The call's request stream is open for Send Message and End Stream.
    var isStreamOpen: Bool {
        app.runner.openStreams.contains(RunKey(requestID, in: projectID))
    }

    /// The picked method, when the loaded schema has it.
    var selectedMethod: GRPCMethodDescriptor? {
        schema.method(service: spec.service, name: spec.method)
    }

    /// The picked service's methods, in declaration order.
    var methods: [GRPCMethodDescriptor] {
        schema.services.first { $0.fullName == spec.service }?.methods ?? []
    }

    /// The picked method's Example: every field of its input type at a placeholder value.
    var exampleMessage: String? {
        selectedMethod.map(example(for:))
    }

    /// Calls sent from the editor stay open for the composer when the method streams from the client, and the runner
    /// gives those no deadline unless the request sets one.
    var isInteractive: Bool {
        selectedMethod?.kind.clientStreams == true
    }

    /// Whether the Messages tab lists every message: when the picked method's client streams, or, while its kind is
    /// unknown (no schema yet), when the request already holds more than one.
    var listsMessages: Bool {
        selectedMethod?.kind.clientStreams ?? (spec.messages.count > 1)
    }

    /// The first message: all a unary or server-streaming call sends.
    var firstMessage: String {
        get { spec.messages.first ?? "" }
        set {
            guard newValue != firstMessage else {
                return
            }
            if spec.messages.isEmpty {
                spec.messages = [newValue]
            } else {
                spec.messages[0] = newValue
            }
        }
    }

    /// The source's name; a descriptor set shows its file name, the rest of its path being noise in a menu.
    var schemaSourceTitle: String {
        switch spec.schema {
        case .automatic: "Automatic"
        case .projectProtos: "Project protos"
        case .reflection: "Server reflection"
        case .descriptorSet(let reference):
            app.pathResolver(for: projectID)?.url(for: reference, in: .descriptorSet(requestID))?.lastPathComponent ?? "Descriptor set"
        }
    }

    // MARK: - Editing

    func setTLS(_ isOn: Bool) {
        spec.security = isOn ? .tls : .plaintext
    }

    /// Picks `service` and its first method, which a service always needs to be called.
    func select(_ service: GRPCServiceDescriptor) {
        guard service.fullName != spec.service else {
            return
        }
        if let first = service.methods.first {
            select(first)
        } else {
            spec.service = service.fullName
            spec.method = ""
        }
    }

    /// Picks `method`, filling in its Example while every message is still blank, so a new request starts with the
    /// fields it can send.
    func select(_ method: GRPCMethodDescriptor) {
        var copy = spec
        copy.service = method.service
        copy.method = method.name
        if copy.messages.allSatisfy(Self.isBlank) {
            copy.messages = [example(for: method)]
        }
        spec = copy
    }

    func setSchemaSource(_ source: GRPCSchemaSource) {
        spec.schema = source
    }

    func chooseDescriptorSet() {
        let types = ["protoset", "binpb", "pb"].compactMap { UTType(filenameExtension: $0) }
        var existing: ProjectPathReference?
        if case .descriptorSet(let current) = spec.schema {
            existing = current
        }
        guard let url = app.system.chooseFile(prompt: "Use Descriptor Set", allowedTypes: types),
              let reference = app.reference(for: url, in: projectID, at: .descriptorSet(requestID), replacing: existing) else {
            return
        }
        spec.schema = .descriptorSet(reference)
    }

    /// Replaces the message at `index` with the picked method's Example.
    func fillExample(at index: Int) {
        guard let method = selectedMethod, spec.messages.indices.contains(index) else {
            return
        }
        spec.messages[index] = example(for: method)
    }

    /// Appends the Example, or `{}` while no method is picked.
    func addMessage() {
        spec.messages.append(selectedMethod.map(example(for:)) ?? "{}")
    }

    func refreshSchema() {
        schema.refresh()
    }

    /// Opens the project's settings, where its proto roots, files, and descriptor sets are configured.
    func configureProtos() {
        app.flushPendingEdits()
        app.sheet = .projectSettings(projectID)
    }

    private func example(for method: GRPCMethodDescriptor) -> String {
        ProtobufJSONCodec(registry: schema.registry).example(for: method.inputType)
    }

    // MARK: - Calls

    /// Asks the runner to keep the request stream open every time: it does so only when the method it resolves
    /// streams from the client, so Send never depends on the editor's schema having loaded.
    ///
    /// While the stream is open, Send sends the composer's message instead: a new run would cancel the open call,
    /// and ⌘Return (the menu's Send) is also how the composer sends. It shows the Messages tab first, where the
    /// composer and any error it reports are.
    func send() {
        // Either way the latest call is where the message goes.
        history.showLatest()
        guard !isStreamOpen else {
            tab = .messages
            sendLiveMessage()
            return
        }
        flush()
        liveError = nil
        if let method = selectedMethod, method.kind.clientStreams, Self.isBlank(liveMessage) {
            liveMessage = example(for: method)
        }
        let runner = app.runner
        let requestID = requestID
        let projectID = projectID
        Task {
            await runner.run(requestID, in: projectID, options: RunOptions(keepsStreamOpen: true, mayPromptForTrust: true))
        }
    }

    func cancel() {
        app.runner.cancel(requestID, in: projectID)
    }

    func sendLiveMessage() {
        do {
            try app.runner.sendMessage(liveMessage, to: requestID, in: projectID)
            liveError = nil
        } catch {
            liveError = error.message
        }
    }

    func endStream() {
        app.runner.endStream(requestID, in: projectID)
    }

    // MARK: - Saving

    func flush() {
        show(draft.flush(content))
    }

    func adoptExternalChange() {
        show(draft.adoptExternalChange(content))
    }

    private var content: RequestContent<GRPCRequestSpec> {
        RequestContent(spec: spec, scripts: scriptsEditor.scripts, runsInheritedScripts: scriptsEditor.runsInheritedScripts)
    }

    /// Shows a stored version: the scripts first, so the spec's observer sees both stored and schedules no save.
    private func show(_ stored: RequestContent<GRPCRequestSpec>?) {
        guard let stored else {
            return
        }
        scriptsEditor.show(stored.scripts, runsInheritedScripts: stored.runsInheritedScripts)
        if stored.spec != spec {
            spec = stored.spec
        }
    }

    private static func coding(_ requestID: RequestNodeID) -> DocumentDraft<RequestContent<GRPCRequestSpec>>.Coding {
        DocumentDraft.request(requestID, read: { $0.grpcSpec }, wrap: { .grpc($0) }, merge: merge(base:draft:stored:))
    }

    /// A three-way merge per top-level field: each field the draft changed since `base` keeps the draft's value, and
    /// every other field takes the stored one. Metadata merges row by row by ID (`ListMerge`); the messages, which
    /// carry no IDs, and the auth are each one field, and the service and method one pair, so a merge never calls a
    /// method on a service that lacks it. A field added to `GRPCRequestSpec` must be listed here, or the draft wins it
    /// unconditionally.
    private nonisolated static func merge(base: GRPCRequestSpec, draft: GRPCRequestSpec, stored: GRPCRequestSpec) -> GRPCRequestSpec {
        var merged = draft
        func takeStored<Value: Equatable>(_ field: WritableKeyPath<GRPCRequestSpec, Value>) {
            if draft[keyPath: field] == base[keyPath: field] {
                merged[keyPath: field] = stored[keyPath: field]
            }
        }
        takeStored(\.target)
        takeStored(\.security)
        if draft.methodPath == base.methodPath {
            merged.service = stored.service
            merged.method = stored.method
        }
        merged.metadata = ListMerge.merge(base: base.metadata, draft: draft.metadata, stored: stored.metadata)
        takeStored(\.messages)
        takeStored(\.schema)
        takeStored(\.deadlineSeconds)
        takeStored(\.verifyTLS)
        takeStored(\.auth)
        return merged
    }

    /// What the schema lookup reads from the request: where reflection connects and how, and which source to use.
    private static func changesSchema(from old: GRPCRequestSpec, to new: GRPCRequestSpec) -> Bool {
        old.target != new.target || old.security != new.security || old.verifyTLS != new.verifyTLS || old.schema != new.schema
    }

    /// Blank or `{}`: nothing the user would lose to an Example.
    private static func isBlank(_ message: String) -> Bool {
        let compact = message.filter { !$0.isWhitespace }
        return compact.isEmpty || compact == "{}"
    }
}
