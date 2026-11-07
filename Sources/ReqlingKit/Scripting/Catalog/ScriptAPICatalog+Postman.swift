import ReqlingScriptProtocol

/// `pm`: Postman's names for what `rq` does, so imported scripts run. Completion never offers them; hover names the
/// `rq` equivalent.
extension ScriptAPICatalog {
    static let postmanTypes: [ScriptType] = [
        ScriptType("Postman", "Postman's script API, for scripts written for Postman.", members: postmanMembers),
        ScriptType("PostmanTestFunction", "Runs a named test.", members: [
            .method("skip", [ScriptParameter("name", .string), ScriptParameter("callback", .function, isOptional: true)], returns: .void,
                    "Reports a test as skipped.").postman("rq.test.skip")
        ]),
        ScriptType("PostmanInfo", "Where this script runs.", members: [
            .property("eventName", .string, "`prerequest` or `test`.").postman("rq.info.phase"),
            .property("requestName", .string, "The request's name.").postman("rq.info.requestName"),
            .property("requestId", .string, "The request's ID.").postman("rq.info.requestId"),
            .property("iteration", .number, "Which iteration of the run this is, from 0.").postman("rq.info.iteration"),
            .property("iterationCount", .number, "How many iterations the run makes.").postman("rq.info.iterationCount")
        ]),
        ScriptType("PostmanIterationData", "This iteration's data row.", members: [
            .method("get", [ScriptParameter("name", .string)], returns: .optional(.string), "The column's value.").postman("rq.iterationData.get"),
            .method("has", [ScriptParameter("name", .string)], returns: .boolean, "Whether the row has the column.").postman("rq.iterationData.has"),
            .method("toObject", returns: .object, "Every column with its value.").postman("rq.iterationData.toObject")
        ]),
        ScriptType("PostmanExecution", "What happens to this request, and what the run runs next.", members: [
            .method("skipRequest", returns: .void, "Doesn't send this request.", phases: .pre).postman("rq.execution.skipRequest"),
            .method("setNextRequest", [ScriptParameter("request", .optional(.string))], returns: .void,
                    "Runs this request next; `null` ends the iteration.").postman("rq.execution.setNextRequest")
        ]),
        postmanVariables("PostmanEnvironment", equivalent: "rq.environment", source: .environment, extra: [
            .property("name", .string, "The environment's name.").postman("rq.environment.name")
        ]),
        postmanVariables("PostmanGlobals", equivalent: "rq.globals", source: .globals),
        postmanVariables("PostmanCollectionVariables", equivalent: "rq.defaultEnvironment", source: .defaultEnvironment),
        postmanVariables("PostmanVariables", equivalent: "rq.variables", source: .all, extra: [
            .method("replaceIn", [ScriptParameter("text", .string)], returns: .string, "Resolves `{{name}}` references.")
                .postman("rq.variables.replaceIn")
        ]),
        ScriptType("PostmanRequest", "The request as typed.", members: [
            .property("method", .string, "The HTTP method.", protocols: .http).postman("rq.request.method"),
            .property("headers", .named("PostmanList"), "The headers.").postman("rq.request.headers"),
            .property("url", .named("PostmanURL"), "The URL and its query.").postman("rq.request.url"),
            .property("body", .optional(.named("PostmanBody")), "The body.", protocols: .http).postman("rq.request.body")
        ]),
        ScriptType("PostmanList", "Headers or query parameters, as `{ key, value }`.", members: postmanListMembers),
        ScriptType("PostmanURL", "The URL.", members: [
            .property("query", .named("PostmanList"), "The query parameters.", protocols: .withQuery).postman("rq.request.query"),
            .method("toString", returns: .string, "The URL with its query.").postman("rq.request.url")
        ]),
        ScriptType("PostmanBody", "The body.", members: [
            .property("mode", .string, "The body's mode.").postman("rq.request.body.mode"),
            .property("raw", .optional(.string), "The raw body's text.").postman("rq.request.body.raw")
        ]),
        ScriptType("PostmanResponse", "The HTTP response.", members: postmanResponseMembers),
        ScriptType("PostmanAssertion", "Assertions about the response.", members: [
            .property("have", .named("PostmanHave"), "Asserts what the response has."),
            .property("be", .named("PostmanBe"), "Asserts what the response is."),
            .property("not", .named("PostmanNegatedAssertion"), "Negates the assertion.")
        ]),
        ScriptType("PostmanNegatedAssertion", "Negated assertions about the response.", members: [
            .property("have", .named("PostmanHave"), "Asserts what the response doesn't have."),
            .property("be", .named("PostmanBe"), "Asserts what the response isn't.")
        ]),
        ScriptType("PostmanHave", "Asserts what the response has.", members: [
            .method("status", [ScriptParameter("status", .any)], returns: .void, "The status code, or reason phrase."),
            .method("header", [ScriptParameter("name", .string), ScriptParameter("value", .string, isOptional: true)], returns: .void,
                    "The header, with the value when given."),
            .method("body", [ScriptParameter("body", .any, isOptional: true)], returns: .void, "A body, or this one."),
            .method("jsonBody", [ScriptParameter("path", .string, isOptional: true), ScriptParameter("value", .any, isOptional: true)],
                    returns: .void, "A JSON body, with the dotted path, or the path's value.")
        ]),
        ScriptType("PostmanBe", "Asserts what the response is.", members: [
            .property("ok", .void, "A 2xx response."),
            .property("success", .void, "A 2xx response."),
            .property("json", .void, "A JSON body.")
        ])
    ]

    private static let postmanMembers: [ScriptMember] = [
        .method("test", [ScriptParameter("name", .string), ScriptParameter("callback", .function)], returns: .void,
                "Runs a named test.", functionType: "PostmanTestFunction").postman("rq.test"),
        .method("expect", [ScriptParameter("value", .any), ScriptParameter("message", .string, isOptional: true)],
                returns: .named("Expectation"), "Starts an assertion.").postman("rq.expect"),
        .property("info", .named("PostmanInfo"), "Where this script runs.").postman("rq.info"),
        .property("environment", .named("PostmanEnvironment"), "The active environment's variables.").postman("rq.environment"),
        .property("globals", .named("PostmanGlobals"), "The Global environment's variables.").postman("rq.globals"),
        .property("collectionVariables", .named("PostmanCollectionVariables"), "The project's Default environment's variables.")
            .postman("rq.defaultEnvironment"),
        .property("variables", .named("PostmanVariables"), "Every variable; a value set here lasts for this run.").postman("rq.variables"),
        .property("request", .named("PostmanRequest"), "The request as typed.").postman("rq.request"),
        .property("response", .named("PostmanResponse"), "The HTTP response.", phases: .post, protocols: [.http]).postman("rq.response"),
        .unsupported("sendRequest", "scripts can't make network calls", isMethod: true),
        .unsupported("cookies", "scripts can't read the cookie jar"),
        .unsupported("vault", "Reqling keeps secrets as secret variables"),
        .property("iterationData", .named("PostmanIterationData"), "This iteration's data row.").postman("rq.iterationData"),
        .property("execution", .named("PostmanExecution"), "Skips this request, or picks what runs next.").postman("rq.execution"),
        .unsupported("visualizer", "Reqling shows responses itself")
    ]

    private static func postmanVariables(
        _ name: String,
        equivalent: String,
        source: ScriptVariableSource,
        extra: [ScriptMember] = []
    ) -> ScriptType {
        let key = ScriptParameter("name", .string, completion: .variableName(source))
        let members: [ScriptMember] = [
            .method("get", [key], returns: .optional(.string), "The variable's value.").postman("\(equivalent).get"),
            .method("set", [key, ScriptParameter("value", .any)], returns: .void, "Sets a value.").postman("\(equivalent).set"),
            .method("unset", [key], returns: .void, "Unsets a value.").postman("\(equivalent).unset"),
            .method("has", [key], returns: .boolean, "Whether it has a value.").postman("\(equivalent).has"),
            .method("toObject", returns: .object, "Every variable with its value.").postman("\(equivalent).toObject"),
            .unsupported("clear", "unset each key instead", isMethod: true)
        ]
        return ScriptType(name, "Postman's name for \(equivalent).", members: members + extra)
    }

    private static let postmanListMembers: [ScriptMember] = {
        let item = ScriptParameter("item", .any)
        return [
            .method("get", [ScriptParameter("key", .string)], returns: .optional(.string), "The value.").postman("rq.request.headers.get"),
            .method("has", [ScriptParameter("key", .string)], returns: .boolean, "Whether it's there.").postman("rq.request.headers.has"),
            .method("all", returns: .array(.object), "Every `{ key, value }`.").postman("rq.request.headers.all"),
            .method("toObject", returns: .object, "Every value by key.").postman("rq.request.headers.toObject"),
            .method("add", [item, ScriptParameter("value", .any, isOptional: true)], returns: .void, "Adds one.", phases: .pre)
                .postman("rq.request.headers.add"),
            .method("upsert", [item, ScriptParameter("value", .any, isOptional: true)], returns: .void, "Sets or adds one.", phases: .pre)
                .postman("rq.request.headers.upsert"),
            .method("remove", [item], returns: .void, "Drops one.", phases: .pre).postman("rq.request.headers.remove")
        ]
    }()

    private static let postmanResponseMembers: [ScriptMember] = [
        .property("code", .number, "The status code.").postman("rq.response.code"),
        .property("status", .string, "The reason phrase.").postman("rq.response.status"),
        .property("responseTime", .number, "How long it took, in milliseconds.").postman("rq.response.responseTime"),
        .property("headers", .named("PostmanList"), "The headers.").postman("rq.response.headers"),
        .method("size", returns: .number, "The body's size in bytes.").postman("rq.response.size"),
        .method("text", returns: .string, "The body as text.").postman("rq.response.text"),
        .method("json", returns: .responseJSON, "The body, parsed as JSON.").postman("rq.response.json"),
        .property("to", .named("PostmanAssertion"), "Assertions about the response.").postman("rq.expect")
    ]
}
