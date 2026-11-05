import Foundation

/// One run of a request: what was sent (masked) and what came back, or why it failed.
public struct RequestExchange: Hashable, Sendable, Codable {
    /// Shared by every partial exchange an open gRPC call publishes and the one it finishes with.
    public var id: RunID
    public var projectID: ProjectID
    public var requestID: RequestNodeID
    public var startedAt: Date
    /// The environment the run resolved against, Default included; `nil` when the run failed before choosing one.
    public var environmentID: EnvironmentID?
    public var environmentName: String?
    /// The template that ran, a one-run spec included: what re-running the run sends again and restoring it puts back in
    /// the editor. Its credentials are as typed, as in the project's files; resolved secret values never reach it.
    /// `nil` when the request no longer existed.
    public var spec: RequestKind?
    public var request: ResolvedHTTPRequest?
    public var outcome: Outcome
    public var unresolvedVariables: [String]
    /// The stored HTTP body, or the stored gRPC messages, were cut to fit the history (`RunHistoryStore.bodyLimit` and
    /// `grpcMessageLimit`); the run itself saw them all.
    public var isBodyTruncated: Bool

    public enum Outcome: Hashable, Sendable, Codable {
        case response(HTTPResponseRecord)
        /// A gRPC call that reached the server, whatever its status; a call that never connected is a `failure`.
        case grpc(GRPCCallRecord)
        case failure(RunFailure)
    }

    public init(
        id: RunID = RunID(),
        projectID: ProjectID,
        requestID: RequestNodeID,
        startedAt: Date,
        environmentID: EnvironmentID? = nil,
        environmentName: String?,
        spec: RequestKind? = nil,
        request: ResolvedHTTPRequest?,
        outcome: Outcome,
        unresolvedVariables: [String] = [],
        isBodyTruncated: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.requestID = requestID
        self.startedAt = startedAt
        self.environmentID = environmentID
        self.environmentName = environmentName
        self.spec = spec
        self.request = request
        self.outcome = outcome
        self.unresolvedVariables = unresolvedVariables
        self.isBodyTruncated = isBodyTruncated
    }

    public var response: HTTPResponseRecord? {
        if case .response(let response) = outcome {
            return response
        }
        return nil
    }

    public var grpc: GRPCCallRecord? {
        if case .grpc(let call) = outcome {
            return call
        }
        return nil
    }

    public var failure: RunFailure? {
        if case .failure(let failure) = outcome {
            return failure
        }
        return nil
    }

    public var outcomeKind: RunOutcomeKind {
        switch outcome {
        case .response(let response): response.statusCode < 400 ? .succeeded : .failed
        case .grpc(let call): call.status?.isOK == true ? .succeeded : .failed
        case .failure: .failed
        }
    }
}

public struct RunFailure: Hashable, Sendable, Codable, Error {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// The request could not be built: a bad URL, a missing file, unresolved variables.
        case invalidRequest
        case tls
        case cancelled
        case timedOut
        case transport
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// The failure with the run's secrets masked. Transport and TLS messages quote hosts and URLs, which may have
    /// come from a secret variable.
    func redacting(_ redaction: SecretRedaction) -> RunFailure {
        RunFailure(kind: kind, message: redaction.apply(message))
    }

    /// Unresolved `{{variables}}` stop a run before anything is sent, unless `RunOptions.allowUnresolved` is set.
    static func undefinedVariables(_ names: [String]) -> RunFailure {
        let list = names.map { "{{\($0)}}" }.joined(separator: ", ")
        return RunFailure(kind: .invalidRequest, message: "Undefined variables: \(list). Define them in an environment, or remove them.")
    }

    /// A gRPC call that ended without a status; TLS failures of either kind share `.tls`, as HTTP's do.
    init(_ error: GRPCCallError) {
        let kind: Kind = switch error {
        case .invalidRequest: .invalidRequest
        case .connectionFailed: .transport
        case .untrustedServer, .tlsFailed: .tls
        case .cancelled: .cancelled
        }
        self.init(kind: kind, message: error.localizedDescription)
    }
}
