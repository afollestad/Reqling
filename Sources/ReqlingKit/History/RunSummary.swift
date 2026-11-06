import Foundation

/// One run in a request's history without its bodies: what the history list shows, built when the run is recorded, so
/// listing never decodes a response.
public struct RunSummary: Hashable, Sendable, Codable, Identifiable {
    public enum Status: Hashable, Sendable, Codable {
        case http(code: Int)
        /// `code` and `name` are `nil` for a call that ended without a status.
        case grpc(code: Int?, name: String?)
        case webSocket(WebSocketStatus)
        case failure(RunFailure.Kind)
    }

    /// How a WebSocket run ended, as its badge shows it.
    public enum WebSocketStatus: Hashable, Sendable, Codable {
        /// The server answered the handshake with this HTTP status instead of switching protocols.
        case refused(statusCode: Int)
        /// A close frame ended it, with this code; `nil` when the frame carried none (1005).
        case closed(code: Int?)
        /// It ended without a close frame: the connection dropped, or Reqling quit.
        case unclosed
    }

    public let id: RunID
    public let startedAt: Date
    public let environmentName: String?
    public let status: Status
    /// `nil` for a run that failed before a response.
    public let duration: TimeInterval?
    /// The response as received, before the history cut it: an HTTP body's bytes, every byte of an event stream's
    /// bodies, the bytes of every message a gRPC call kept, or every byte a WebSocket received; `nil` for a failure.
    public let responseByteCount: Int?
    /// The protocol of the template the run sent, which re-running and restoring it need; `nil` when it kept none.
    public let specKind: RequestKind.Name?
    /// The exchange's own, for the sidebar's result filter.
    public let outcomeKind: RunOutcomeKind

    public init(_ exchange: RequestExchange) {
        id = exchange.id
        startedAt = exchange.startedAt
        environmentName = exchange.environmentName
        specKind = exchange.spec?.name
        outcomeKind = exchange.outcomeKind
        switch exchange.outcome {
        case .response(let response):
            status = .http(code: response.statusCode)
            duration = response.duration
            responseByteCount = response.eventStream?.receivedByteCount ?? response.body.count
        case .grpc(let call):
            status = .grpc(code: call.status?.code, name: call.status?.name)
            duration = call.duration
            responseByteCount = call.events.reduce(0) { $0 + ($1.direction == .received ? $1.byteCount : 0) }
        case .webSocket(let record):
            if case .refused = record.end, let handshake = record.handshake {
                status = .webSocket(.refused(statusCode: handshake.statusCode))
            } else if let close = record.close {
                status = .webSocket(.closed(code: close.code))
            } else {
                status = .webSocket(.unclosed)
            }
            duration = record.duration
            responseByteCount = record.receivedByteCount
        case .failure(let failure):
            status = .failure(failure.kind)
            duration = nil
            responseByteCount = nil
        }
    }
}
