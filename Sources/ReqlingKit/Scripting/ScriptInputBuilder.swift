import Foundation
import ReqlingScriptProtocol

/// What scripts see of a request and its response, built from Reqling's own models. Only enabled rows appear, as only
/// they are sent; `{{variables}}` stay unresolved, for `rq.variables.replaceIn`.
enum ScriptInputBuilder {
    static func request(_ kind: RequestKind) -> ScriptRequestSnapshot {
        switch kind {
        case .http(let spec):
            return ScriptRequestSnapshot(
                protocolName: "http",
                method: spec.method.rawValue,
                url: spec.url,
                headers: rows(spec.headers),
                query: rows(spec.queryParameters),
                body: body(spec.body)
            )
        case .grpc(let spec):
            return ScriptRequestSnapshot(
                protocolName: "grpc",
                url: spec.target,
                headers: rows(spec.metadata),
                service: spec.service,
                rpc: spec.method,
                messages: spec.messages
            )
        case .webSocket(let spec):
            return ScriptRequestSnapshot(
                protocolName: "websocket",
                url: spec.url,
                headers: rows(spec.headers),
                query: rows(spec.queryParameters),
                messages: spec.messages.map(\.text)
            )
        }
    }

    /// The response a post-response script reads and the raw frames its `ScriptBlob`s point at, or `nil` for a run
    /// that got none. An HTTP body is cut to `ScriptLimits.responseBodyLength`.
    static func response(_ outcome: RequestExchange.Outcome) -> (snapshot: ScriptResponseSnapshot, blobs: [Data])? {
        switch outcome {
        case .response(let response):
            return http(response)
        case .grpc(let call):
            let received = call.events.filter { $0.direction == .received }
            return (.grpc(ScriptGRPCResponse(
                statusCode: call.status?.code,
                statusName: call.status?.name,
                statusMessage: call.status?.message,
                metadata: scriptRows(call.initialMetadata),
                trailers: scriptRows(call.trailers),
                messages: received.map(\.json),
                sentCount: call.sentCount,
                receivedCount: call.receivedCount,
                responseTime: call.duration * 1_000
            )), [])
        case .webSocket(let record):
            return (.webSocket(webSocket(record)), [])
        case .failure:
            return nil
        }
    }

    private static func http(_ response: HTTPResponseRecord) -> (snapshot: ScriptResponseSnapshot, blobs: [Data]) {
        let headers = scriptRows(response.headers)
        let time = response.duration * 1_000
        if let stream = response.eventStream {
            let events = stream.events.map { ScriptStreamEvent(id: $0.id, event: $0.type, data: $0.data, retry: nil) }
            return (.eventStream(ScriptEventStreamResponse(
                code: response.statusCode,
                status: response.reasonPhrase,
                headers: headers,
                events: events,
                end: endName(stream.end),
                omittedEventCount: stream.droppedEventCount + stream.trimmedEntryCount,
                responseTime: time
            )), [])
        }
        let body = response.body.prefix(ScriptLimits.responseBodyLength)
        return (.http(ScriptHTTPResponse(
            code: response.statusCode,
            status: response.reasonPhrase,
            headers: headers,
            body: ScriptBlob(index: 0, size: body.count),
            size: response.body.count,
            truncated: body.count < response.body.count,
            responseTime: time
        )), [Data(body)])
    }

    private static func webSocket(_ record: WebSocketRecord) -> ScriptWebSocketResponse {
        let messages = record.entries.compactMap(\.message).map { message in
            let direction = message.direction == .sent ? "sent" : "received"
            return message.isBase64
                ? ScriptSocketMessage(direction: direction, text: nil, base64: message.text)
                : ScriptSocketMessage(direction: direction, text: message.text, base64: nil)
        }
        let end: String = switch record.end {
        case .closed?: "closed"
        case .stopped?: "stopped"
        case .limit?: "limit"
        case .refused?: "refused"
        case .failed?, nil: "failed"
        }
        return ScriptWebSocketResponse(
            code: record.handshake?.statusCode,
            headers: scriptRows(record.handshake?.headers ?? []),
            subprotocol: record.subprotocol,
            messages: messages,
            closeCode: record.close.map { $0.code ?? 1005 },
            closeReason: record.close?.reason,
            end: end,
            responseTime: record.duration * 1_000
        )
    }

    private static func endName(_ end: EventStreamRecord.End?) -> String {
        switch end {
        case .closed?: "closed"
        case .stopped?: "stopped"
        case .limit?: "limit"
        case .timedOut?: "timedOut"
        case .failed?, nil: "failed"
        }
    }

    private static func rows(_ pairs: [KeyValuePair]) -> [ScriptRow] {
        pairs.filter(\.isEnabled).map { ScriptRow(name: $0.key, value: $0.value) }
    }

    private static func scriptRows(_ pairs: [KeyValuePair]) -> [ScriptRow] {
        pairs.map { ScriptRow(name: $0.key, value: $0.value) }
    }

    /// A file part's project-relative path; a this-Mac-only path stays private to the Mac.
    private static func fileName(_ reference: ProjectPathReference?) -> String {
        if case .relative(let path)? = reference {
            return path
        }
        return ""
    }

    private static func body(_ body: HTTPBody) -> ScriptRequestBody {
        switch body.mode {
        case .none:
            return ScriptRequestBody(mode: "none")
        case .raw:
            return ScriptRequestBody(mode: "raw", raw: body.raw.text)
        case .formData:
            let fields = body.formData.filter(\.isEnabled).map { field in
                ScriptRow(name: field.key, value: field.kind == .text ? field.value : fileName(field.file))
            }
            return ScriptRequestBody(mode: "formData", fields: fields)
        case .urlEncoded:
            return ScriptRequestBody(mode: "urlEncoded", fields: rows(body.urlEncoded))
        case .binary:
            return ScriptRequestBody(mode: "binary")
        case .graphQL:
            return ScriptRequestBody(
                mode: "graphQL",
                graphQLQuery: body.graphQL.query,
                graphQLVariables: body.graphQL.variables,
                graphQLOperationName: body.graphQL.operationName.isEmpty ? nil : body.graphQL.operationName
            )
        }
    }
}
