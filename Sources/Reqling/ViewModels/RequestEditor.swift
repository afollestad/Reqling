import Foundation
import ReqlingKit

/// What every request editor offers whatever protocol its request speaks, so `AppModel`'s selection, flushing, quit
/// confirmation, and adoption, and the Request menu's Send and Cancel, treat every kind alike.
@MainActor
protocol RequestEditing: AnyObject {
    var projectID: ProjectID { get }
    var requestID: RequestNodeID { get }
    var name: String { get }
    var kind: RequestKind.Name { get }
    var isReadOnly: Bool { get }
    /// Explains the pause while the project is listed but did not load; `nil` otherwise.
    var unavailableNote: String? { get }
    var isSending: Bool { get }
    /// A draft that could not save because its project is unavailable; replacing the editor discards it.
    var hasStrandedChanges: Bool { get }
    /// The draft differs from the stored request, saved or not yet; after a flush, only an edit that could not save.
    var hasUnsavedChanges: Bool { get }
    /// Saves a dirty draft now, before anything that could change what it applies to.
    func flush()
    /// Takes a change stored elsewhere while the draft is clean; a dirty draft merges it in on its next save.
    func adoptExternalChange()
    func send()
    func cancel()
    /// The request's runs beside the editor, which also decide which run the response pane shows.
    var history: RunHistoryViewModel { get }
    /// The draft, as a past run's template compares with it.
    var currentSpec: RequestKind { get }
    /// Replaces the draft with a past run's template, sent at `date`; a spec of the other protocol is ignored.
    func restore(_ spec: RequestKind, from date: Date)
}

extension RequestEditing {
    /// What this editor edits, in the sidebar's terms; request IDs alone can repeat across projects.
    var identity: SidebarItem {
        .node(projectID, requestID)
    }
}

extension RequestEditorViewModel: RequestEditing {
    var kind: RequestKind.Name {
        .http
    }

    var currentSpec: RequestKind {
        .http(spec)
    }
}

extension GRPCEditorViewModel: RequestEditing {
    var kind: RequestKind.Name {
        .grpc
    }

    var currentSpec: RequestKind {
        .grpc(spec)
    }
}

/// The selected request's editor. An enum rather than an existential, so the detail view switches over the kinds
/// exhaustively and an action only one protocol has (Copy as cURL) is reachable only on its kind. Two values are equal
/// when they hold the same editor instance.
@MainActor
enum RequestEditor: Equatable {
    case http(RequestEditorViewModel)
    case grpc(GRPCEditorViewModel)
    case webSocket(WebSocketEditorViewModel)

    init(projectID: ProjectID, requestID: RequestNodeID, kind: RequestKind.Name, app: AppModel) {
        switch kind {
        case .http: self = .http(RequestEditorViewModel(projectID: projectID, requestID: requestID, app: app))
        case .grpc: self = .grpc(GRPCEditorViewModel(projectID: projectID, requestID: requestID, app: app))
        case .webSocket: self = .webSocket(WebSocketEditorViewModel(projectID: projectID, requestID: requestID, app: app))
        }
    }

    var editing: any RequestEditing {
        switch self {
        case .http(let editor): editor
        case .grpc(let editor): editor
        case .webSocket(let editor): editor
        }
    }

    var kind: RequestKind.Name {
        switch self {
        case .http: .http
        case .grpc: .grpc
        case .webSocket: .webSocket
        }
    }

    var asHTTP: RequestEditorViewModel? {
        if case .http(let editor) = self {
            return editor
        }
        return nil
    }

    var asGRPC: GRPCEditorViewModel? {
        if case .grpc(let editor) = self {
            return editor
        }
        return nil
    }

    var asWebSocket: WebSocketEditorViewModel? {
        if case .webSocket(let editor) = self {
            return editor
        }
        return nil
    }

    nonisolated static func == (lhs: RequestEditor, rhs: RequestEditor) -> Bool {
        switch (lhs, rhs) {
        case (.http(let left), .http(let right)): left === right
        case (.grpc(let left), .grpc(let right)): left === right
        case (.webSocket(let left), .webSocket(let right)): left === right
        default: false
        }
    }

    // MARK: - Shared surface

    var identity: SidebarItem {
        editing.identity
    }

    var name: String {
        editing.name
    }

    var isSending: Bool {
        editing.isSending
    }

    var hasStrandedChanges: Bool {
        editing.hasStrandedChanges
    }

    var hasUnsavedChanges: Bool {
        editing.hasUnsavedChanges
    }

    var history: RunHistoryViewModel {
        editing.history
    }

    func flush() {
        editing.flush()
    }

    func adoptExternalChange() {
        editing.adoptExternalChange()
    }

    func send() {
        editing.send()
    }

    func cancel() {
        editing.cancel()
    }

    /// The Request menu's Send. An open gRPC stream or WebSocket takes ⌘Return as its next message, not a restart.
    var sendTitle: String {
        switch self {
        case .http: "Send"
        case .grpc(let editor): editor.isStreamOpen ? "Send Message" : "Send"
        case .webSocket(let editor): editor.isOpen ? "Send Message" : "Connect"
        }
    }

    /// The Request menu's Cancel. An open event stream has nothing left to cancel but the stream itself, and an open
    /// WebSocket closes.
    var cancelTitle: String {
        switch self {
        case .http(let editor): editor.isStreaming ? "Stop" : "Cancel"
        case .grpc: "Cancel"
        case .webSocket(let editor): editor.isOpen ? "Disconnect" : "Cancel"
        }
    }
}
