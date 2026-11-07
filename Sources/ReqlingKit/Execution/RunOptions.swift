import Foundation

/// Options for one run, mostly used by agents through MCP.
public struct RunOptions: Sendable {
    /// `nil` uses the project's active environment.
    public var environmentID: EnvironmentID?
    /// One-run values that beat every environment.
    public var variableOverrides: [String: String]
    /// Replaces the saved spec for this run only, such as with an extra header or other messages; the saved template is
    /// untouched. Its protocol must match the request's.
    public var spec: RequestKind?
    /// Send even when some `{{variables}}` cannot be resolved; they go out verbatim.
    public var allowUnresolved: Bool
    /// For client-streaming and bidirectional gRPC calls: leave the request stream open after the request's own
    /// messages, for `RequestRunner.sendMessage` and `endStream`. The editor sets it; agents and tests leave it off, so
    /// a call runs to completion unattended.
    public var keepsStreamOpen: Bool
    /// Stops an event-stream response or a WebSocket early, so an agent's run returns; `nil` lets it run until stopped.
    public var streamLimit: StreamLimit?
    /// Whether the run may ask the person at the Mac to trust the project's scripts (`ScriptTrustDeciding`). Only runs
    /// they start set it; without it, a project not yet trusted runs without its scripts.
    public var mayPromptForTrust: Bool

    public init(
        environmentID: EnvironmentID? = nil,
        variableOverrides: [String: String] = [:],
        spec: RequestKind? = nil,
        allowUnresolved: Bool = false,
        keepsStreamOpen: Bool = false,
        streamLimit: StreamLimit? = nil,
        mayPromptForTrust: Bool = false
    ) {
        self.environmentID = environmentID
        self.variableOverrides = variableOverrides
        self.spec = spec
        self.allowUnresolved = allowUnresolved
        self.keepsStreamOpen = keepsStreamOpen
        self.streamLimit = streamLimit
        self.mayPromptForTrust = mayPromptForTrust
    }

    /// Set by `RequestRunner.runUnsaved`: the request to run in place of a saved one. Its run is never recorded, so it
    /// neither shows in the window nor lands in the history.
    var unsaved: RequestItem?
    /// Collects the secrets the run's scripts touch, for masking output built outside the run.
    var scriptSecrets: ScriptSecretSink?
    /// Set by `BatchRunner` for each step of a folder or project run: what the step starts from, and what it leaves for
    /// the next.
    var batchStep: BatchStepContext?
}

/// One request in one project. Runs are tracked by this, never by request ID alone: a request file copied between
/// projects keeps its ID, and keying by that alone let sending one cancel the other and share its in-flight state.
public struct RunKey: Hashable, Sendable {
    public let projectID: ProjectID
    public let requestID: RequestNodeID

    public init(_ requestID: RequestNodeID, in projectID: ProjectID) {
        self.projectID = projectID
        self.requestID = requestID
    }
}
