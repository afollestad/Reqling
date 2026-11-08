import Foundation

/// A request a script asked Reqling to send (`rq.sendRequest`, `rq.runRequest`), reported as `ScriptRunnerEvent.fetch`
/// and answered with `ScriptRunnerMessage.fetched`. The helper has no network access of its own: Reqling sends it, so
/// the project's TLS and cookies apply, and the phase's time limit keeps running while it's out.
public enum ScriptFetch: Hashable, Sendable, Codable {
    /// `rq.sendRequest`: sent as given, `{{variables}}` and all.
    case send(ScriptFetchRequest)
    /// `rq.runRequest`: a saved request, by ID or name, resolved as a run resolves it, with `variables` beating every
    /// other value.
    case run(request: String, variables: [String: String])
}

/// What `rq.sendRequest` sends, as the script gave it: never `{{variables}}`-resolved, since scripts treat `{{name}}` as
/// plain text.
public struct ScriptFetchRequest: Hashable, Sendable, Codable {
    public var method: String
    public var url: String
    public var headers: [ScriptRow]
    /// `nil` sends none.
    public var body: Data?
    /// How long to wait for the response; `nil` waits as long as Settings' request timeout says.
    public var timeoutSeconds: Double?

    public init(method: String, url: String, headers: [ScriptRow] = [], body: Data? = nil, timeoutSeconds: Double? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeoutSeconds = timeoutSeconds
    }
}

/// What a fetch got back.
public struct ScriptFetchReply: Hashable, Sendable, Codable {
    public enum Outcome: Hashable, Sendable, Codable {
        /// The response, whatever its status. Its body follows the reply as the next frame, which `body` points at
        /// as blob 0, cut as a post-response script's is (`ScriptLimits.responseBodyLength`).
        case response(ScriptHTTPResponse)
        /// Why nothing came back: the request couldn't be built, sent, or answered.
        case failed(String)
    }

    /// The fetch's `ScriptRunnerEvent.fetch` ID.
    public var id: Int
    public var outcome: Outcome
    /// The project's whole jar once the fetch was done, its response's `Set-Cookie`s stored, with every cookie change the
    /// phase reported that Reqling hasn't applied yet on top. The scripts' view of the jar is rebuilt from it, replaying
    /// only the changes made after the fetch went out, which Reqling may not have had; `nil` leaves that view as it is.
    public var cookies: [ScriptCookie]?

    public init(id: Int, outcome: Outcome, cookies: [ScriptCookie]? = nil) {
        self.id = id
        self.outcome = outcome
        self.cookies = cookies
    }
}
