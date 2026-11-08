import ReqlingScriptProtocol

/// What `rq.sendRequest` and `rq.runRequest` take and give back. Reqling sends each request, so these work in every
/// phase and for every protocol.
extension ScriptAPICatalog {
    static let fetchTypes: [ScriptType] = [
        ScriptType("OutgoingRequest", "A request for `rq.sendRequest` to send, as given.", members: [
            .property("method", .string, "The HTTP method; `GET` when left out.", completion: .choices(httpMethods)),
            .property("url", .string, "The URL, as given; `rq.variables.replaceIn` resolves `{{variables}}` first."),
            .property("headers", .object, "An object of names and values, or `[name, value]` pairs."),
            .property("body", .any, "Text, an `ArrayBuffer` or typed array, or any other value as JSON, which adds a JSON "
                + "`Content-Type` unless `headers` name one."),
            .property("timeout", .number, "How long to wait for the response, in milliseconds; as long as Settings ▸ Requests says "
                + "when left out. The script's own time limit still applies.")
        ]),
        ScriptType("RunRequestOptions", "How `rq.runRequest` sends a saved request.", members: [
            .property("variables", .object, "Values that beat every other for this request, by name.")
        ]),
        ScriptType("IncomingResponse", "What a request a script sent got back.", members: [
            .property("code", .number, "The HTTP status code."),
            .property("status", .string, "The HTTP reason phrase, such as `OK`."),
            .property("headers", .named("ReadonlyRows"), "The response's headers."),
            .property("size", .number, "The body's size in bytes, as received."),
            .property("truncated", .boolean, "Whether the body was cut to the 64 MB scripts receive."),
            .property("responseTime", .number, "How long it took, in milliseconds."),
            .method("text", returns: .string, "The body as text."),
            .method("json", returns: .any, "The body, parsed as JSON."),
            .method("base64", returns: .string, "The body's bytes, base64.")
        ])
    ]

    /// What `OutgoingRequest.method` completes; any other method token works too.
    private static let httpMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
}
