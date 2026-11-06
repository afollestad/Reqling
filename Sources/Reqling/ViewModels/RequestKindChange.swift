import ReqlingKit

/// A request switching protocol; see `AppModel.changeKind(of:in:to:)`.
struct RequestKindChange: Identifiable, Equatable {
    let projectID: ProjectID
    let requestID: RequestNodeID
    let name: String
    let from: RequestKind.Name
    let kind: RequestKind.Name

    var id: RequestNodeID {
        requestID
    }

    /// What the switch keeps and what it discards, as `RequestKind.converted(to:)` carries them over.
    var consequences: String {
        switch (from, kind) {
        case (.http, .grpc):
            "Its auth, headers, host, and timeout carry over. Its method, query, body, and run history are discarded."
        case (.grpc, .http), (.grpc, .webSocket):
            "Its auth, metadata, target, and deadline carry over. Its service, method, messages, and run history are discarded."
        case (.http, .webSocket):
            "Its URL, query, auth, headers, and timeout carry over. Its method, body, and run history are discarded."
        case (.webSocket, .http):
            "Its URL, query, auth, headers, and timeout carry over. Its subprotocols, messages, and run history are discarded."
        case (.webSocket, .grpc):
            "Its auth, headers, host, and timeout carry over. Its path, query, subprotocols, messages, and run history are discarded."
        case (.http, .http), (.grpc, .grpc), (.webSocket, .webSocket):
            ""
        }
    }
}
