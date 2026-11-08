import Foundation

/// One run of a request: what was sent (masked) and what came back, or why it failed.
public struct RequestExchange: Hashable, Sendable, Codable {
    /// Shared by every partial exchange an open gRPC call, event stream, or WebSocket publishes and the one it finishes
    /// with.
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
    /// The stored HTTP body, gRPC messages, stream events, or WebSocket messages were cut to fit the history (`RunHistoryStore.bodyLimit`
    /// and `messageLimit`); the run itself saw them all.
    public var isBodyTruncated: Bool
    /// What the run's scripts did, masked; `nil` when it had none. Optional, so runs recorded before scripts decode.
    public var scriptReport: ScriptReport?
    /// The run started from values an earlier request of its folder or project run made secret for that run alone,
    /// which nothing keeps once Reqling quits, so a later read of it can't mask them (`ScriptReport.madeRunLocalSecrets`
    /// says the same of values the run's own scripts made). `nil` otherwise, and for runs recorded before batches.
    public var heldRunLocalSecrets: Bool?

    public enum Outcome: Hashable, Sendable, Codable {
        case response(HTTPResponseRecord)
        /// A gRPC call that reached the server, whatever its status; a call that never connected is a `failure`.
        case grpc(GRPCCallRecord)
        /// A WebSocket connection the server answered, opened or refused; one that got no answer is a `failure`.
        case webSocket(WebSocketRecord)
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
        isBodyTruncated: Bool = false,
        scriptReport: ScriptReport? = nil
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
        self.scriptReport = scriptReport
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

    public var webSocket: WebSocketRecord? {
        if case .webSocket(let record) = outcome {
            return record
        }
        return nil
    }

    public var failure: RunFailure? {
        if case .failure(let failure) = outcome {
            return failure
        }
        return nil
    }

    /// Failed scripts fail the run whatever came back: a failed test is what the person asked to hear about.
    public var outcomeKind: RunOutcomeKind {
        if scriptReport?.hasFailures == true {
            return .failed
        }
        return switch outcome {
        // A stream that timed out or failed never answered with an error status, but still went wrong.
        case .response(let response): response.statusCode < 400 && response.eventStream?.end?.isFailure != true ? .succeeded : .failed
        case .grpc(let call): call.status?.isOK == true ? .succeeded : .failed
        case .webSocket(let record): record.isFailure ? .failed : .succeeded
        case .failure(let failure): failure.kind == .skipped ? .notSent : .failed
        }
    }
}

public struct RunFailure: Hashable, Sendable, Codable, Error {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// The request could not be built: a bad URL, a missing file, unresolved variables.
        case invalidRequest
        /// A pre-request script threw, timed out, or couldn't run, so the request wasn't sent.
        case script
        /// A pre-request script asked not to send the request (`rq.execution.skipRequest`). No failure: its run counts
        /// as not sent, unless a test failed.
        case skipped
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

    /// Path variables with no value stop a run the same way: the URL would otherwise go out with `:name` in its path.
    static func emptyPathVariables(_ names: [String]) -> RunFailure {
        let list = names.map { ":\($0)" }.joined(separator: ", ")
        return RunFailure(kind: .invalidRequest, message: "Path variables without a value: \(list). Give them one under Params.")
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
