/// Bounds on what one phase may report. The helper enforces them as scripts run, and the app trims again, so a script
/// stuck in a loop of `console.log` or `set` can neither flood the pipe nor bloat the run history. A stream phase, which
/// may run for as long as its stream stays open, applies each to its top level and to each handler call on its own.
public struct ScriptLimits: Hashable, Sendable, Codable {
    public var consoleEntries = 1_000
    public var consoleEntryLength = 16 * 1_024
    public var tests = 1_000
    public var testNameLength = 1_024
    public var testMessageLength = 4 * 1_024
    /// `set` and `unset` calls; past this, they throw.
    public var variableWrites = 10_000
    /// One variable's value, in UTF-16 units; a longer one throws.
    public var valueLength = 4 * 1_024 * 1_024
    public var requestChanges = 1_000
    /// Cookies set or removed; `clear()` counts each cookie it removes, and refuses before removing any past this.
    public var cookieWrites = 1_000
    /// A cookie's name and value together, in UTF-8 bytes, as browsers bound them.
    public var cookieLength = 4_096
    /// Messages `rq.send` sends.
    public var sends = 1_000
    /// One message `rq.send` sends, in bytes, as large as a WebSocket message Reqling sends may be.
    public var sendLength = 16 * 1_024 * 1_024
    /// Requests `rq.sendRequest` and `rq.runRequest` send.
    public var fetches = 100
    /// The body of one request `rq.sendRequest` sends, in bytes.
    public var fetchBodyLength = 16 * 1_024 * 1_024

    public static let standard = ScriptLimits()

    /// The most of a response body handed to a script, beyond which `rq.response.truncated` is true.
    public static let responseBodyLength = 64 * 1_024 * 1_024

    public init() {}
}
