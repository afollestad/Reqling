import ReqlingScriptProtocol

/// `rq.response`, whose members depend on how the request was answered.
extension ScriptAPICatalog {
    static let responseTypes: [ScriptType] = [
        ScriptType("Response", "What came back: an HTTP response, an event stream, a gRPC call, or a WebSocket connection.",
                   members: responseMembers),
        ScriptType("StreamEvent", "One event of an event stream.", members: [
            .property("id", .optional(.string), "Its `id:`."),
            .property("event", .optional(.string), "Its `event:` type."),
            .property("data", .string, "Its data."),
            .property("retry", .optional(.number), "Its `retry:` delay, in milliseconds."),
            .method("json", returns: .any, "Its data, parsed as JSON.")
        ]),
        ScriptType("GRPCStatus", "How the call ended.", members: [
            .property("code", .optional(.number), "The status code; 0 is OK."),
            .property("name", .optional(.string), "The status's canonical name, such as `OK` or `NOT_FOUND`."),
            .property("message", .optional(.string), "The server's message.")
        ]),
        ScriptType("GRPCMessage", "One message the call received.", members: [
            .method("text", returns: .string, "The message as JSON text."),
            .method("json", returns: .any, "The message, parsed.")
        ]),
        ScriptType("SocketMessage", "One message the connection sent or received.", members: [
            .property("direction", .string, "`sent` or `received`."),
            .property("text", .optional(.string), "A text message's text."),
            .property("isBinary", .boolean, "Whether it was a binary message."),
            .property("base64", .optional(.string), "A binary message's bytes, base64."),
            .method("json", returns: .any, "A text message, parsed as JSON.")
        ]),
        ScriptType("Close", "How the connection closed.", members: [
            .property("code", .number, "The close code."),
            .property("reason", .string, "The close reason.")
        ])
    ]

    private static let responseMembers: [ScriptMember] = [
        .property("code", .number, "The HTTP status code.", phases: .opened, protocols: .http),
        .property("code", .optional(.number), "The gRPC status code; 0 is OK.", phases: .post, protocols: [.grpc]),
        .property("code", .optional(.number), "The handshake's HTTP status code.", phases: .opened, protocols: [.webSocket]),
        .property("status", .string, "The HTTP reason phrase, such as `OK`.", phases: .opened, protocols: .http),
        .property("status", .named("GRPCStatus"), "How the call ended.", phases: .post, protocols: [.grpc]),
        .property("headers", .named("ReadonlyRows"), "The response's headers, or the handshake's.", phases: .opened,
                  protocols: [.http, .eventStream, .webSocket]),
        .property("size", .number, "The body's size in bytes, as received.", phases: .post, protocols: [.http]),
        .property("truncated", .boolean, "Whether the body was cut to the 64 MB scripts receive.", phases: .post, protocols: [.http]),
        .property("responseTime", .number, "How long it took, in milliseconds.", phases: .post),
        .method("text", returns: .string, "The body as text.", phases: .post, protocols: .http),
        .method("json", returns: .responseJSON, "The body, or the last message received, parsed as JSON.", phases: .post,
                protocols: [.http, .grpc]),
        .method("base64", returns: .string, "The body's bytes, base64.", phases: .post, protocols: [.http]),
        .property("events", .array(.named("StreamEvent")), "Every event received, in order.", phases: .post, protocols: [.eventStream]),
        .property("omittedEventCount", .number, "Events received but not kept.", phases: .post, protocols: [.eventStream]),
        .property("end", .string, "How the stream or connection ended: `closed`, `stopped`, `limit`, `timedOut`, `refused`, or `failed`.",
                  phases: .post, protocols: [.eventStream, .webSocket]),
        .property("metadata", .named("ReadonlyRows"), "The call's response metadata.", phases: .opened, protocols: [.grpc]),
        .property("trailers", .named("ReadonlyRows"), "The call's trailers.", phases: .post, protocols: [.grpc]),
        .property("messages", .array(.named("GRPCMessage")), "Every message received, in order.", phases: .post, protocols: [.grpc]),
        .property("sentCount", .number, "How many messages the call sent.", phases: .post, protocols: [.grpc]),
        .property("receivedCount", .number, "How many messages the call received.", phases: .post, protocols: [.grpc]),
        .property("messages", .array(.named("SocketMessage")), "Every message sent and received, in order.", phases: .post,
                  protocols: [.webSocket]),
        .property("subprotocol", .optional(.string), "The subprotocol the server chose.", phases: .opened, protocols: [.webSocket]),
        .property("close", .optional(.named("Close")), "How the connection closed, if it did.", phases: .post, protocols: [.webSocket])
    ]
}
