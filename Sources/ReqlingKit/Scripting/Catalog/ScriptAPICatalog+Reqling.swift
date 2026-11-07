import ReqlingScriptProtocol

/// `rq` and what it holds, apart from the response (`ScriptAPICatalog+Response.swift`).
extension ScriptAPICatalog {
    static let reqlingTypes: [ScriptType] = [
        ScriptType("Reqling", "Reqling's script API.", members: reqlingMembers),
        ScriptType("TestFunction", "Runs a named test.", members: [
            .method("skip", [ScriptParameter("name", .string), ScriptParameter("callback", .function, isOptional: true)], returns: .void,
                    "Reports a test as skipped without running it.")
        ]),
        ScriptType("Info", "Where this script runs.", members: infoMembers),
        ScriptType("IterationData", "This iteration's row of a folder or project run's data file, as text. Empty otherwise.", members: [
            .method("get", [ScriptParameter("name", .string)], returns: .optional(.string), "The column's value in this row, or `undefined`."),
            .method("has", [ScriptParameter("name", .string)], returns: .boolean, "Whether this row has the column."),
            .method("toObject", returns: .object, "Every column of this row with its value.")
        ]),
        ScriptType("Execution", "What happens to this request, and what a folder or project run runs next.", members: [
            .method("skipRequest", returns: .void, "Doesn't send this request. The rest of the pre-request scripts still run.", phases: .pre),
            .method("setNextRequest", [ScriptParameter("request", .optional(.string))], returns: .void,
                    "In a folder or project run, runs the request with this name or ID next; `null` ends the iteration. "
                        + "Ignored when the request runs on its own.")
        ]),
        variableType("Environment", "The active environment's variables: its saved values, with this Mac's current values over them.",
                     source: .environment, named: true),
        variableType("DefaultEnvironment", "The project's Default environment's variables.", source: .defaultEnvironment, named: true),
        variableType("Globals", "The Global environment's variables, which every project shares.", source: .globals, named: true),
        variableType("Variables", "Every variable as `{{name}}` resolves it; values set here last only for this run.", source: .all, named: false),
        ScriptType("Request", "The request as typed, `{{variables}}` unresolved.", members: requestMembers),
        rowsType("Rows", "Headers, query parameters, or metadata. Pre-request scripts can change them for this run.", mutable: true),
        rowsType("ReadonlyRows", "Headers, metadata, or trailers.", mutable: false),
        ScriptType("Row", "One header, query parameter, or metadata entry.", members: [
            .property("name", .string, "Its name."),
            .property("value", .string, "Its value, `{{variables}}` unresolved.")
        ]),
        ScriptType("RequestBody", "An HTTP request's body as typed.", members: [
            .property("mode", .string, "`none`, `raw`, `formData`, `urlEncoded`, `binary`, or `graphQL`."),
            .property("raw", .optional(.string), "The raw body's text."),
            .property("fields", .array(.named("Row")), "Form fields; a file field's value is its path."),
            .property("graphQL", .optional(.named("GraphQLBody")), "A GraphQL body's query, variables, and operation name.")
        ]),
        ScriptType("GraphQLBody", "A GraphQL body.", members: [
            .property("query", .string, "The query."),
            .property("variables", .string, "The variables, as JSON text."),
            .property("operationName", .optional(.string), "The operation to run, when the query has several.")
        ]),
        ScriptType("Crypto", "Hashes and HMACs. Output is hex unless `{ encoding: \"base64\" }`; input is UTF-8 text unless "
            + "`{ inputEncoding: \"hex\" | \"base64\" }`.", members: cryptoMembers),
        ScriptType("Expectation", "A Chai-style assertion: chain words such as `to`, `be`, and `have`, `.not`, `.deep`, and "
            + "assertions such as `equal`, `include`, and `property`.", isOpen: true, members: expectationMembers)
    ]

    private static let reqlingMembers: [ScriptMember] = [
        .property("info", .named("Info"), "Where this script runs: its phase, level, request, and environment."),
        .property("environment", .named("Environment"), "The active environment's variables. A value set here is kept on this Mac."),
        .property("defaultEnvironment", .named("DefaultEnvironment"), "The project's Default environment's variables."),
        .property("globals", .named("Globals"), "The Global environment's variables."),
        .property("variables", .named("Variables"), "Every variable as `{{name}}` resolves it; a value set here lasts for this run."),
        .property("iterationData", .named("IterationData"), "This iteration's row of a folder or project run's data file."),
        .property("execution", .named("Execution"), "Skips this request, or picks what a folder or project run runs next."),
        .property("request", .named("Request"), "The request as typed. Pre-request scripts can change its headers and query."),
        .property("response", .named("Response"), "What came back.", phases: .post),
        .method("test", [ScriptParameter("name", .string), ScriptParameter("callback", .function)], returns: .void,
                "Runs a named test; it fails when the callback throws or its promise rejects.", functionType: "TestFunction"),
        .method("expect", [ScriptParameter("value", .any), ScriptParameter("message", .string, isOptional: true)],
                returns: .named("Expectation"), "Starts a Chai-style assertion about a value."),
        .property("crypto", .named("Crypto"), "Hashes and HMACs for signing requests.")
    ]

    private static let infoMembers: [ScriptMember] = [
        .property("phase", .string, "`preRequest` or `postResponse`."),
        .property("level", .string, "Whose script this is: `project`, `folder`, or `request`."),
        .property("levelName", .string, "The project's, folder's, or request's name."),
        .property("requestName", .string, "The name of the request running."),
        .property("requestId", .string, "The ID of the request running."),
        .property("protocol", .string, "`http`, `grpc`, or `websocket`."),
        .property("environment", .string, "The active environment's name."),
        .property("iteration", .number, "Which iteration of a folder or project run this is, from 0; 0 when the request runs on its own."),
        .property("iterationCount", .number, "How many iterations the folder or project run makes; 1 when the request runs on its own.")
    ]

    private static func variableType(_ name: String, _ summary: String, source: ScriptVariableSource, named: Bool) -> ScriptType {
        let key = ScriptParameter("name", .string, completion: .variableName(source))
        var members: [ScriptMember] = [
            .method("get", [key], returns: .optional(.string), "The variable's value, or `undefined`."),
            .method("set", [key, ScriptParameter("value", .any), ScriptParameter("options", .object, isOptional: true)], returns: .void,
                    "Sets a value; anything but a string is stored as JSON. `{ secret: true }` keeps it in the Keychain and masked."),
            .method("unset", [key], returns: .void, source == .all
                ? "Drops a value set earlier in this run."
                : "Hides the variable until its current value is reset in the Environments sheet."),
            .method("has", [key], returns: .boolean, "Whether the variable has a value."),
            .method("isSecret", [key], returns: .boolean, "Whether the variable's value is secret."),
            .method("toObject", returns: .object, "Every variable with its value.")
        ]
        if named {
            members.append(.property("name", .string, "The environment's name."))
        } else {
            members.append(.method("replaceIn", [ScriptParameter("text", .string)], returns: .string,
                                   "Resolves `{{name}}` references as the request will."))
        }
        return ScriptType(name, summary, members: members)
    }

    private static let requestMembers: [ScriptMember] = [
        .property("protocol", .string, "`http`, `grpc`, or `websocket`."),
        .property("url", .string, "The URL without its query, or a gRPC call's target."),
        .property("method", .string, "The HTTP method.", protocols: .http),
        .property("body", .optional(.named("RequestBody")), "The body as typed.", protocols: .http),
        .property("headers", .named("Rows"), "The headers, or a gRPC call's metadata."),
        .property("query", .named("Rows"), "The query parameters.", protocols: .withQuery),
        .property("metadata", .named("Rows"), "The call's metadata.", protocols: [.grpc]),
        .property("service", .string, "The call's service.", protocols: [.grpc]),
        .property("rpc", .string, "The call's method.", protocols: [.grpc]),
        .property("messages", .array(.string), "The messages it sends, as typed.", protocols: [.grpc, .webSocket])
    ]

    private static func rowsType(_ name: String, _ summary: String, mutable: Bool) -> ScriptType {
        let key = ScriptParameter("name", .string)
        var members: [ScriptMember] = [
            .method("get", [key], returns: .optional(.string), "The first value with the name, or `undefined`; header names ignore case."),
            .method("has", [key], returns: .boolean, "Whether an entry has the name."),
            .method("all", returns: .array(.named("Row")), "Every entry, in order."),
            .method("toObject", returns: .object, "Every entry by name.")
        ]
        if mutable {
            let value = ScriptParameter("value", .any)
            members += [
                .method("upsert", [key, value], returns: .void, "Sets the first entry with the name, dropping the others, or adds one.",
                        phases: .pre),
                .method("add", [key, value], returns: .void, "Adds an entry.", phases: .pre),
                .method("remove", [key], returns: .void, "Drops every entry with the name.", phases: .pre)
            ]
        }
        return ScriptType(name, summary, members: members)
    }

    private static let cryptoMembers: [ScriptMember] = {
        let data = ScriptParameter("data", .string)
        let options = ScriptParameter("options", .object, isOptional: true)
        let digests: [ScriptMember] = ["md5", "sha1", "sha256", "sha384", "sha512"].map { name in
            .method(name, [data, options], returns: .string, "The \(name.uppercased()) hash.")
        }
        return digests + [
            .method("hmac", [ScriptParameter("algorithm", .string), ScriptParameter("key", .string), data, options], returns: .string,
                    "An HMAC with `md5`, `sha1`, `sha256`, `sha384`, or `sha512`; `{ keyEncoding }` reads the key as hex or base64."),
            .method("randomUUID", returns: .string, "A random UUID.")
        ]
    }()

    private static let expectationMembers: [ScriptMember] = {
        let chain = ["to", "be", "been", "is", "that", "which", "and", "has", "have", "with", "at", "of", "same", "not", "deep", "own"]
        let chainMembers: [ScriptMember] = chain.map { .property($0, .named("Expectation"), "Reads on; `not` negates and `deep` compares deeply.") }
        let value = ScriptParameter("expected", .any)
        let methods: [ScriptMember] = [
            .method("equal", [value], returns: .named("Expectation"), "Strictly equal, or deeply after `.deep`."),
            .method("eql", [value], returns: .named("Expectation"), "Deeply equal."),
            .method("include", [value], returns: .named("Expectation"), "Contains the value, substring, or subset."),
            .method("property", [ScriptParameter("name", .string), ScriptParameter("value", .any, isOptional: true)],
                    returns: .named("Expectation"), "Has the property, with the value when given; chains on to it."),
            .method("a", [ScriptParameter("type", .string)], returns: .named("Expectation"), "Is of the type: `string`, `array`, `null`, …"),
            .method("above", [value], returns: .named("Expectation"), "Greater than."),
            .method("below", [value], returns: .named("Expectation"), "Less than."),
            .method("least", [value], returns: .named("Expectation"), "At least."),
            .method("most", [value], returns: .named("Expectation"), "At most."),
            .method("within", [ScriptParameter("low", .number), ScriptParameter("high", .number)], returns: .named("Expectation"), "In the range."),
            .method("match", [ScriptParameter("pattern", .any)], returns: .named("Expectation"), "Matches the regular expression."),
            .method("lengthOf", [ScriptParameter("length", .number)], returns: .named("Expectation"), "Has the length or size."),
            .method("oneOf", [ScriptParameter("values", .array(.any))], returns: .named("Expectation"), "Is one of the values."),
            .method("keys", [ScriptParameter("names", .any)], returns: .named("Expectation"), "Has exactly the keys."),
            .method("members", [ScriptParameter("values", .array(.any))], returns: .named("Expectation"), "Has the same members."),
            .method("throw", [ScriptParameter("expected", .any, isOptional: true)], returns: .named("Expectation"), "The function throws.")
        ]
        let assertions = ["ok", "true", "false", "null", "undefined", "exist", "empty", "NaN"].map { name in
            ScriptMember.property(name, .named("Expectation"), "Asserts as it's read.")
        }
        return chainMembers + methods + assertions
    }()
}
