#if DEBUG
import Foundation
import ReqlingKit

/// Acme API's Live folder, which only the `events` and `websocket` scenes seed, so every other capture keeps its
/// sidebar: an event stream of order updates, and a WebSocket support chat, each with a cached run. Byte counts are
/// real (each entry's data, and the stream's total as it would arrive on the wire), and offsets are fixed, so both
/// appearances match one `alt`.
@MainActor
struct ScreenshotLiveRequests {
    let folder: RequestFolder
    let orderUpdates: RequestNodeID
    let supportChat: RequestNodeID

    init() {
        let orderUpdates = RequestItem(name: "Order updates", kind: .http(HTTPRequestSpec(
            url: "{{baseUrl}}/orders/stream",
            queryParameters: [KeyValuePair(key: "status", value: "open")],
            headers: [KeyValuePair(key: "Accept", value: "text/event-stream")]
        )))
        let supportChat = RequestItem(name: "Support chat", kind: .webSocket(WebSocketRequestSpec(
            url: "wss://api.acme.dev/support",
            subprotocols: ["chat.v2"],
            messages: [
                WebSocketMessage(text: "{\n  \"type\": \"auth\",\n  \"token\": \"{{token}}\"\n}"),
                WebSocketMessage(text: "Where's order 1041?", sendsOnConnect: false)
            ]
        )))
        folder = RequestFolder(name: "Live", children: [.request(orderUpdates), .request(supportChat)])
        self.orderUpdates = orderUpdates.id
        self.supportChat = supportChat.id
    }

    /// The run the scene opens, cached as if it had just finished.
    func cachedRun(for scene: ScreenshotMode.Scene, startedAt: Date) -> CachedRun? {
        switch scene {
        case .events:
            let url = "https://api.acme.dev/orders/stream?status=open"
            let sent = ResolvedHTTPRequest(method: "GET", url: url, headers: [], bodyPreview: nil, bodyByteCount: 0)
            return CachedRun(request: orderUpdates, sent: sent, outcome: .response(Self.orderStream(url: url, startedAt: startedAt)))
        case .websocket:
            let url = "wss://api.acme.dev/support"
            let sent = ResolvedHTTPRequest(method: "GET", url: url, headers: [], bodyPreview: nil, bodyByteCount: 0)
            return CachedRun(request: supportChat, sent: sent, outcome: .webSocket(Self.chatRecord(url: url, startedAt: startedAt)))
        case .request, .body, .grpc, .graphql:
            return nil
        }
    }

    private static func orderStream(url: String, startedAt: Date) -> HTTPResponseRecord {
        // Short enough that the whole timeline fits the pane, with no Jump to Bottom over it.
        let events = [
            (0.21, "order.created", "1041", #"{"id":1041,"total":"48.00"}"#),
            (1.84, "order.updated", "1042", #"{"id":1041,"status":"paid"}"#),
            (4.37, "order.updated", "1043", #"{"id":1038,"status":"shipped"}"#)
        ]
        let entries = events.enumerated().map { index, event in
            EventStreamEntry(sequence: index, offset: event.0, kind: .event(ServerSentEvent(type: event.1, id: event.2, data: event.3)))
        }
        var response = HTTPResponseRecord(
            statusCode: 200,
            headers: [
                KeyValuePair(key: "Content-Type", value: "text/event-stream; charset=utf-8"),
                KeyValuePair(key: "Cache-Control", value: "no-cache")
            ],
            body: Data(),
            url: url,
            startedAt: startedAt,
            duration: 6.4,
            timing: HTTPTiming(dnsLookup: 0.003, connect: 0.009, tlsHandshake: 0.018, requestSent: 0.0002, waiting: 0.041),
            protocolName: "h2",
            tlsVersion: "TLS 1.3"
        )
        response.eventStream = EventStreamRecord(
            entries: entries,
            receivedByteCount: 211,
            lastEventID: "1043",
            retryMilliseconds: 3_000,
            end: .stopped
        )
        return response
    }

    private static func chatRecord(url: String, startedAt: Date) -> WebSocketRecord {
        func message(_ sequence: Int, _ offset: TimeInterval, _ direction: MessageDirection, _ text: String) -> WebSocketEntry {
            WebSocketEntry(
                sequence: sequence,
                offset: offset,
                kind: .message(WebSocketMessageRecord(direction: direction, format: .text, text: text)),
                byteCount: text.utf8.count
            )
        }
        var record = WebSocketRecord(
            url: url,
            subprotocol: "chat.v2",
            // Plain-text chat after the JSON auth, one row each, so the whole timeline fits the pane.
            entries: [
                message(0, 0.052, .sent, "{\n  \"type\": \"auth\",\n  \"token\": \"••••••\"\n}"),
                message(1, 0.067, .received, "Hi Grace, Ada here. How can I help?"),
                message(2, 3.12, .sent, "Where's order 1041?"),
                message(3, 5.48, .received, "It ships today, tracking to follow."),
                WebSocketEntry(sequence: 4, offset: 15.0, kind: .control(direction: .received, text: "Ping from the server, answered with a pong")),
                WebSocketEntry(sequence: 5, offset: 18.3, kind: .control(direction: .sent, text: "Close 1000 Normal Closure")),
                WebSocketEntry(sequence: 6, offset: 18.31, kind: .control(direction: .received, text: "Close 1000 Normal Closure"))
            ],
            close: WebSocketRecord.Close(code: 1000, byServer: false),
            end: .stopped,
            duration: 18.31
        )
        record.handshake = HTTPResponseRecord(
            statusCode: 101,
            headers: [KeyValuePair(key: "Upgrade", value: "websocket"), KeyValuePair(key: "Sec-WebSocket-Protocol", value: "chat.v2")],
            body: Data(),
            url: url,
            startedAt: startedAt,
            duration: 0.049,
            timing: HTTPTiming(connect: 0.011, tlsHandshake: 0.021, waiting: 0.017),
            protocolName: "http/1.1",
            tlsVersion: "TLS 1.3"
        )
        return record
    }
}
#endif
