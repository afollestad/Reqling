/// Which way a message on a timeline went, for every protocol that keeps one: gRPC calls and WebSocket connections.
/// Stored by its raw value, which run histories written before WebSockets already used for gRPC.
public enum MessageDirection: String, Hashable, Sendable, Codable {
    case sent
    case received
}
