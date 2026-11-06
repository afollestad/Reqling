import Foundation
import MCP

/// WebSocket connections through the execution tools: a run opens the connection, sends the request's on-connect
/// messages, and returns once its time or message bound (`streamLimit`) closes it, with everything that crossed it.
extension MCPExecutionTools {
    /// A connection's result: the handshake's answer, the newest entries that fit `bodyLimit`, masked, and how it ended.
    /// `end` is `null` while it is still open.
    static func webSocket(_ record: WebSocketRecord, cachedCut: Bool, mask: (String) -> String) -> [String: Value] {
        var kept: [Value] = []
        var budget = bodyLimit
        for entry in record.entries.reversed() {
            let (described, size) = describe(entry, mask: mask)
            budget -= size
            guard budget >= 0 else {
                break
            }
            kept.append(.object(described))
        }
        var description: [String: Value] = [
            "url": .string(mask(record.url)),
            "subprotocol": record.subprotocol.map(Value.string) ?? .null,
            "sentCount": .int(record.sentCount),
            "receivedCount": .int(record.receivedCount),
            "entries": .array(kept.reversed()),
            "durationMs": .int(Int((record.duration * 1_000).rounded())),
            "end": record.end.map { .string(name(of: $0)) } ?? .null
        ]
        if let handshake = record.handshake {
            description["handshake"] = .object(answer(handshake, mask: mask))
        }
        if let close = record.close {
            description["close"] = [
                "code": .int(close.code ?? 1005),
                "reason": .string(mask(close.reason)),
                "byServer": .bool(close.byServer)
            ]
        }
        switch record.end {
        case .refused(let message), .failed(let message):
            description["endMessage"] = .string(mask(message))
        case .closed, .stopped, .limit, nil:
            break
        }
        let omitted = record.omittedEntryCount + record.entries.count - kept.count
        if omitted > 0 || cachedCut {
            description["omittedEntryCount"] = .int(omitted)
            description["note"] = "Only the newest entries are included."
        }
        return description
    }

    /// One timeline entry, and how much of the result's budget its text spends: a message's, masked.
    private static func describe(_ entry: WebSocketEntry, mask: (String) -> String) -> (entry: [String: Value], size: Int) {
        var described: [String: Value] = ["offsetMs": .int(Int((entry.offset * 1_000).rounded()))]
        switch entry.kind {
        case .message(let message):
            let text = mask(message.text)
            described["direction"] = .string(message.direction.rawValue)
            described["format"] = .string(message.format.rawValue)
            described[message.isBase64 ? "base64" : "text"] = .string(text)
            described["byteCount"] = .int(entry.byteCount)
            return (described, text.utf8.count)
        case .control(let direction, let text):
            described["direction"] = .string(direction.rawValue)
            described["control"] = .string(mask(text))
        case .note(let text):
            described["note"] = .string(mask(text))
        }
        return (described, 0)
    }

    /// The server's answer to the handshake; a refusal's body comes along, which usually says why.
    private static func answer(_ head: HTTPResponseRecord, mask: (String) -> String) -> [String: Value] {
        var answer: [String: Value] = [
            "status": .int(head.statusCode),
            "headers": .array(head.headers.map { ["key": .string($0.key), "value": .string(mask($0.value))] })
        ]
        if let tlsVersion = head.tlsVersion {
            answer["tlsVersion"] = .string(tlsVersion)
        }
        if !head.body.isEmpty {
            if let text = String(data: head.body, encoding: .utf8) {
                answer["body"] = .string(mask(text.prefix(utf8Count: bodyLimit)))
            } else {
                answer["bodyBase64"] = .string(head.body.prefix(bodyLimit * 3 / 4).base64EncodedString())
            }
        }
        return answer
    }

    private static func name(of end: WebSocketRecord.End) -> String {
        switch end {
        case .closed: "closed"
        case .stopped: "stopped"
        case .limit: "limit"
        case .refused: "refused"
        case .failed: "failed"
        }
    }

    /// What `resolve_request` returns for a WebSocket: its handshake, and the on-connect messages as they would go.
    static func resolved(_ preview: WebSocketRequestPreview) throws -> [String: Value] {
        [
            "request": try MCPJSON.encode(preview.request),
            "messages": .array(preview.messages.map { ["format": .string($0.format.rawValue), "text": .string($0.text)] }),
            "unresolvedVariables": .array(preview.unresolvedVariables.map(Value.string))
        ]
    }
}
