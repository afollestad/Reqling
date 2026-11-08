/// When a script runs: before its request is resolved and sent; while an event stream, gRPC call, or WebSocket
/// connection is open, its handlers taking each event or message as it arrives (`stream`); or after the response
/// arrives or the stream, call, or connection ends.
public enum ScriptPhase: String, Hashable, Sendable, Codable, CaseIterable {
    case preRequest
    case stream
    case postResponse
}
