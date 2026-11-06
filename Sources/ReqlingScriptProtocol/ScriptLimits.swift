/// Bounds on what one phase may report. The helper enforces them as scripts run, and the app trims again, so a script
/// stuck in a loop of `console.log` or `set` can neither flood the pipe nor bloat the run history.
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

    public static let standard = ScriptLimits()

    /// The most of a response body handed to a script, beyond which `rq.response.truncated` is true.
    public static let responseBodyLength = 64 * 1_024 * 1_024

    public init() {}
}
