/// When a script runs: before its request is resolved and sent, or after the response arrives or the stream, call, or
/// connection ends.
public enum ScriptPhase: String, Hashable, Sendable, Codable, CaseIterable {
    case preRequest
    case postResponse
}
