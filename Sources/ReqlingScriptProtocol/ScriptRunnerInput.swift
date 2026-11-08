import ReqlingTemplating

/// Everything one launch of `ReqlingScriptRunner` runs: one phase of one request's scripts, outermost level first, with
/// the variables, cookies, request, and (after the request) response they see. It travels as the first frame on the helper's
/// standard input (`ScriptFraming`); `blobCount` bodies follow as raw frames that `ScriptBlob` points at, so a large
/// response is never base64'd into the JSON. `ScriptRunnerMessage` frames follow those, in every phase, for as long as
/// the helper runs: a stream's items, and what each request a script sent got back.
public struct ScriptRunnerInput: Codable, Sendable {
    /// Bumped on any change one side could misread; the helper refuses another version (`ScriptRunnerExit.badInput`).
    public static let currentProtocolVersion = 7

    public var protocolVersion: Int
    public var phase: ScriptPhase
    public var levels: [ScriptLevelSource]
    public var variables: VariableLayers
    public var info: ScriptRunInfo
    public var request: ScriptRequestSnapshot
    /// `nil` before the request, and in a stream phase, which reads what the stream opened with (`stream`).
    public var response: ScriptResponseSnapshot?
    /// Set exactly for a stream phase.
    public var stream: ScriptStreamSetup?
    /// The project's whole cookie jar as the phase starts: after the request, with its response's `Set-Cookie`s stored.
    public var cookies: [ScriptCookie]
    /// The folder holding `runtime.js` and the vendored libraries.
    public var runtimeDirectory: String
    public var limits: ScriptLimits
    /// How many raw body frames follow this one. Standard input stays open after them for `ScriptRunnerMessage`s, so
    /// the helper can't read bodies to its end; `HelperScriptRunner` sets it from the bodies it writes.
    public var blobCount = 0

    public init(
        phase: ScriptPhase,
        levels: [ScriptLevelSource],
        variables: VariableLayers,
        info: ScriptRunInfo,
        request: ScriptRequestSnapshot,
        response: ScriptResponseSnapshot? = nil,
        stream: ScriptStreamSetup? = nil,
        cookies: [ScriptCookie] = [],
        runtimeDirectory: String,
        limits: ScriptLimits = .standard
    ) {
        protocolVersion = Self.currentProtocolVersion
        self.phase = phase
        self.levels = levels
        self.variables = variables
        self.info = info
        self.request = request
        self.response = response
        self.stream = stream
        self.cookies = cookies
        self.runtimeDirectory = runtimeDirectory
        self.limits = limits
    }
}

/// Whose script a level is.
public enum ScriptLevelKind: String, Hashable, Sendable, Codable {
    case project
    case folder
    case request
}

/// One level's script, as typed.
public struct ScriptLevelSource: Hashable, Sendable, Codable {
    public var kind: ScriptLevelKind
    /// The project's, folder's, or request's name, as reports show it.
    public var name: String
    /// The script's file within the project, which error locations and stack traces name.
    public var path: String
    public var source: String

    public init(kind: ScriptLevelKind, name: String, path: String, source: String) {
        self.kind = kind
        self.name = name
        self.path = path
        self.source = source
    }
}

/// What `rq.info` describes.
public struct ScriptRunInfo: Hashable, Sendable, Codable {
    public var requestName: String
    public var requestID: String
    /// `http`, `grpc`, or `websocket`.
    public var protocolName: String
    public var environmentName: String
    public var defaultEnvironmentName: String
    /// Which pass of a folder or project run this is, from 0; 0 for a request run on its own.
    public var iteration: Int
    /// How many passes the folder or project run makes; 1 for a request run on its own.
    public var iterationCount: Int

    public init(
        requestName: String,
        requestID: String,
        protocolName: String,
        environmentName: String,
        defaultEnvironmentName: String,
        iteration: Int = 0,
        iterationCount: Int = 1
    ) {
        self.requestName = requestName
        self.requestID = requestID
        self.protocolName = protocolName
        self.environmentName = environmentName
        self.defaultEnvironmentName = defaultEnvironmentName
        self.iteration = iteration
        self.iterationCount = iterationCount
    }
}

/// A header, query parameter, or metadata entry.
public struct ScriptRow: Hashable, Sendable, Codable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// The request as a script sees it: the template, `{{variables}}` unresolved, with only enabled rows. Pre-request
/// scripts change headers, query parameters, and path variables through `ScriptRequestChange`, which later levels see
/// here.
public struct ScriptRequestSnapshot: Hashable, Sendable, Codable {
    /// `http`, `grpc`, or `websocket`.
    public var protocolName: String
    public var method: String?
    /// The URL without its query, its `:name` path variables as written (HTTP and WebSocket), or the target (gRPC).
    public var url: String
    /// Headers, or a gRPC call's metadata.
    public var headers: [ScriptRow]
    /// Empty for gRPC, which has none.
    public var query: [ScriptRow]
    /// One row per `:name` in `url`, with its value as typed; empty for gRPC.
    public var pathVariables: [ScriptRow]
    public var body: ScriptRequestBody?
    /// A gRPC call's service and method.
    public var service: String?
    public var rpc: String?
    /// A gRPC call's request messages, or a WebSocket's on-connect messages, as typed.
    public var messages: [String]

    public init(
        protocolName: String,
        method: String? = nil,
        url: String,
        headers: [ScriptRow] = [],
        query: [ScriptRow] = [],
        pathVariables: [ScriptRow] = [],
        body: ScriptRequestBody? = nil,
        service: String? = nil,
        rpc: String? = nil,
        messages: [String] = []
    ) {
        self.protocolName = protocolName
        self.method = method
        self.url = url
        self.headers = headers
        self.query = query
        self.pathVariables = pathVariables
        self.body = body
        self.service = service
        self.rpc = rpc
        self.messages = messages
    }
}

/// An HTTP request's body as typed.
public struct ScriptRequestBody: Hashable, Sendable, Codable {
    /// `none`, `raw`, `formData`, `urlEncoded`, `binary`, or `graphQL`.
    public var mode: String
    public var raw: String?
    /// Form fields, as typed; a file field's value is its path.
    public var fields: [ScriptRow]
    public var graphQLQuery: String?
    public var graphQLVariables: String?
    public var graphQLOperationName: String?

    public init(
        mode: String,
        raw: String? = nil,
        fields: [ScriptRow] = [],
        graphQLQuery: String? = nil,
        graphQLVariables: String? = nil,
        graphQLOperationName: String? = nil
    ) {
        self.mode = mode
        self.raw = raw
        self.fields = fields
        self.graphQLQuery = graphQLQuery
        self.graphQLVariables = graphQLVariables
        self.graphQLOperationName = graphQLOperationName
    }
}

/// Points at a raw frame after the input's JSON: frame `index + 1`.
public struct ScriptBlob: Hashable, Sendable, Codable {
    public var index: Int
    public var size: Int

    public init(index: Int, size: Int) {
        self.index = index
        self.size = size
    }
}
