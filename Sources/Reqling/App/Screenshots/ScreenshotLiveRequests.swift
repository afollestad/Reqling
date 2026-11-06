#if DEBUG
import Foundation
import ReqlingKit

/// Acme API's Live folder, which only the `events` and `websocket` scenes seed, so every other capture keeps its
/// sidebar: an event stream of order updates with a cached run, and a WebSocket support chat that
/// `ScreenshotLiveChat` connects live. The stream's byte counts are real (each entry's data, and the total as it would
/// arrive on the wire), and its offsets are fixed, so both appearances match one `alt`.
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
            // Like Acme API's other requests; `ScreenshotLiveChat` points `baseUrl` at its loopback server, and an
            // http(s) URL connects as ws(s).
            url: "{{baseUrl}}/support",
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

    /// The run the scene opens, cached as if it had just finished; the WebSocket's is live instead.
    func cachedRun(for scene: ScreenshotMode.Scene, startedAt: Date) -> CachedRun? {
        switch scene {
        case .events:
            let url = "https://api.acme.dev/orders/stream?status=open"
            let sent = ResolvedHTTPRequest(method: "GET", url: url, headers: [], bodyPreview: nil, bodyByteCount: 0)
            return CachedRun(request: orderUpdates, sent: sent, outcome: .response(Self.orderStream(url: url, startedAt: startedAt)))
        case .request, .grpc, .graphql, .websocket, .scripts:
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
}
#endif
