import ReqlingScriptProtocol

/// The snippets, in menu order. Values a script saves go to `rq.environment`, as the guide's login example does, so
/// the requests after it can send them.
extension ScriptSnippets {
    static let entries: [Entry] = variableEntries + requestEntries + testEntries

    private static let everyPhase = Set(ScriptPhase.allCases)

    private static let variableEntries: [Entry] = [
        Entry("setVariable", .variables, [
            Variant("Set a variable", everyPhase, nil, #"rq.environment.set("<#name#>", "value")"#)
        ]),
        Entry("readVariable", .variables, [
            Variant("Read a variable", everyPhase, nil, #"const value = rq.variables.get("<#name#>")"#)
        ]),
        Entry("saveJSONValue", .variables, [
            Variant("Save a value from the JSON response", .post, [.http, .grpc], #"rq.environment.set("token", rq.response.json().<#token#>)"#),
            Variant("Save a value from the last message's JSON", .post, [.webSocket], """
                const received = rq.response.messages.filter((message) => message.direction === "received")
                rq.environment.set("token", received.at(-1).json().<#token#>)
                """),
            Variant("Save a value from each event's JSON", .stream, [.http], """
                rq.onEvent((event) => {
                  const value = event.json().<#token#>
                  if (value !== undefined) rq.environment.set("token", value)
                })
                """),
            Variant("Save a value from each message's JSON", .stream, [.grpc, .webSocket], """
                rq.onMessage((message) => {
                  const value = message.json().<#token#>
                  if (value !== undefined) rq.environment.set("token", value)
                })
                """)
        ])
    ]

    private static let requestEntries: [Entry] = [
        Entry("addHeader", .request, [
            Variant("Add a header", .pre, nil, #"rq.request.headers.upsert("<#X-Name#>", "value")"#),
            Variant("Add metadata", .pre, [.grpc], #"rq.request.metadata.upsert("<#x-name#>", "value")"#)
        ]),
        // A gRPC call's headers are its metadata, whose names Reqling lowercases as it sends them.
        Entry("signHMAC", .request, [
            Variant("Sign with an HMAC", .pre, nil, """
                const timestamp = Date.now().toString()
                rq.request.headers.upsert("X-Timestamp", timestamp)
                rq.request.headers.upsert("X-Signature", rq.crypto.hmac("sha256", rq.environment.get("<#apiSecret#>"), timestamp))
                """)
        ])
    ]

    private static let testEntries: [Entry] = [
        Entry("testStatus", .tests, [
            Variant("Test the status code", .opened, [.http], #"rq.test("status is 200", () => rq.expect(rq.response.code).to.equal(<#200#>))"#),
            Variant("Test the status code", .post, [.grpc], #"rq.test("status is OK", () => rq.expect(rq.response.code).to.equal(<#0#>))"#),
            Variant(
                "Test the status code",
                .opened,
                [.webSocket],
                #"rq.test("connection is accepted", () => rq.expect(rq.response.code).to.equal(<#101#>))"#
            )
        ]),
        Entry("testJSONField", .tests, [
            Variant("Test a JSON field", .post, [.http, .grpc], #"rq.test("has an id", () => rq.expect(rq.response.json().<#id#>).to.exist)"#),
            Variant("Test the last message's JSON field", .post, [.webSocket], """
                rq.test("last message has an id", () => {
                  const received = rq.response.messages.filter((message) => message.direction === "received")
                  rq.expect(received.at(-1).json().<#id#>).to.exist
                })
                """),
            Variant(
                "Test each event's JSON field",
                .stream,
                [.http],
                #"rq.onEvent((event) => rq.test("event has an id", () => rq.expect(event.json().<#id#>).to.exist))"#
            ),
            Variant(
                "Test each message's JSON field",
                .stream,
                [.grpc, .webSocket],
                #"rq.onMessage((message) => rq.test("message has an id", () => rq.expect(message.json().<#id#>).to.exist))"#
            )
        ]),
        Entry("testResponseTime", .tests, [
            Variant(
                "Test the response time",
                .post,
                nil,
                #"rq.test("responds quickly", () => rq.expect(rq.response.responseTime).to.be.below(<#1000#>))"#
            )
        ])
    ]
}
