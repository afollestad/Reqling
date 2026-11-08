import ReqlingScriptProtocol

/// `pm`: Postman's names for what `rq` does, so imported scripts run. Completion never offers them; hover names the
/// `rq` equivalent.
extension ScriptAPICatalog {
    static let postmanTypes: [ScriptType] = [
        ScriptType("Postman", "Postman's script API, for scripts written for Postman.", members: postmanMembers),
        ScriptType("PostmanTestFunction", "Runs a named test.", members: [
            .method("skip", [testParameters[0], ScriptParameter("callback", .function, "The test's body, which doesn't run.", isOptional: true)],
                    returns: .void, "Reports a test as skipped.").postman("rq.test.skip")
        ]),
        ScriptType("PostmanInfo", "Where this script runs.", members: [
            .property("eventName", .string, "`prerequest` or `test`.").postman("rq.info.phase"),
            .property("requestName", .string, "The request's name.").postman("rq.info.requestName"),
            .property("requestId", .string, "The request's ID.").postman("rq.info.requestId"),
            .property("iteration", .number, "Which iteration of the run this is, from 0.").postman("rq.info.iteration"),
            .property("iterationCount", .number, "How many iterations the run makes.").postman("rq.info.iterationCount")
        ]),
        ScriptType("PostmanIterationData", "This iteration's data row.", members: [
            .method("get", [column], returns: .optional(.string), "The column's value.").postman("rq.iterationData.get"),
            .method("has", [column], returns: .boolean, "Whether the row has the column.").postman("rq.iterationData.has"),
            .method("toObject", returns: .object, "Every column with its value.").postman("rq.iterationData.toObject")
        ]),
        ScriptType("PostmanExecution", "What happens to this request, and what the run runs next.", members: [
            .method("skipRequest", returns: .void, "Doesn't send this request.", phases: .pre).postman("rq.execution.skipRequest"),
            .method("setNextRequest", [ScriptParameter("request", .optional(.string), "A request's name or ID, or `null` to end the iteration.")],
                    returns: .void,
                    "Runs this request next; `null` ends the iteration.").postman("rq.execution.setNextRequest"),
            .method("runRequest", [ScriptParameter("request", .string, "The saved request's ID or name."),
                                   ScriptParameter("options", .named("RunRequestOptions"),
                                                   "`{ variables }`: values that beat every other for this request.", isOptional: true)],
                    returns: .promise(.named("PostmanSentResponse")), "Sends a saved request.").postman("rq.runRequest")
        ]),
        postmanVariables("PostmanEnvironment", equivalent: "rq.environment", source: .environment, extra: [
            .property("name", .string, "The environment's name.").postman("rq.environment.name")
        ]),
        postmanVariables("PostmanGlobals", equivalent: "rq.globals", source: .globals),
        postmanVariables("PostmanCollectionVariables", equivalent: "rq.defaultEnvironment", source: .defaultEnvironment),
        postmanVariables("PostmanVariables", equivalent: "rq.variables", source: .all, extra: [
            .method("replaceIn", [ScriptParameter("text", .string, "Text holding `{{name}}` references.")], returns: .string,
                    "Resolves `{{name}}` references.")
                .postman("rq.variables.replaceIn")
        ]),
        ScriptType("PostmanRequest", "The request as typed.", members: [
            .property("method", .string, "The HTTP method.", protocols: .http).postman("rq.request.method"),
            .property("headers", .named("PostmanList"), "The headers.").postman("rq.request.headers"),
            .property("url", .named("PostmanURL"), "The URL and its query.").postman("rq.request.url"),
            .property("body", .optional(.named("PostmanBody")), "The body.", protocols: .http).postman("rq.request.body")
        ]),
        ScriptType("PostmanList", "Headers or query parameters, as `{ key, value }`.", members: postmanListMembers),
        ScriptType("PostmanCookies", "The cookies for the request's URL.", members: [
            .method("get", [cookieName], returns: .optional(.string), "The cookie's value.", protocols: .withCookies)
                .postman("rq.cookies.get"),
            .method("has", [cookieName], returns: .boolean, "Whether there's a cookie with the name.",
                    protocols: .withCookies).postman("rq.cookies.has"),
            .method("toObject", returns: .object, "Every cookie's value by name.", protocols: .withCookies).postman("rq.cookies.toObject"),
            .method("jar", returns: .named("PostmanCookieJar"), "The project's whole jar, by URL.").postman("rq.cookies.for")
        ]),
        ScriptType("PostmanCookieJar", "The project's cookie jar, by URL. Each callback gets `(error, result)` before the call returns.",
                   members: postmanJarMembers),
        ScriptType("PostmanURL", "The URL.", members: [
            .property("query", .named("PostmanList"), "The query parameters.", protocols: .withQuery).postman("rq.request.query"),
            .method("toString", returns: .string, "The URL with its query.").postman("rq.request.url")
        ]),
        ScriptType("PostmanBody", "The body.", members: [
            .property("mode", .string, "The body's mode.").postman("rq.request.body.mode"),
            .property("raw", .optional(.string), "The raw body's text.").postman("rq.request.body.raw")
        ]),
        ScriptType("PostmanResponse", "The HTTP response.", members: postmanResponseMembers(json: .responseJSON, equivalent: "rq.response")),
        // Its JSON isn't this request's response's, whose keys `.responseJSON` would complete.
        ScriptType("PostmanSentResponse", "What a request `pm.sendRequest` sent got back.",
                   members: postmanResponseMembers(json: .any, equivalent: "IncomingResponse")),
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
            .method("status", [ScriptParameter("status", .any, "A status code such as `200`, or a reason phrase such as `\"OK\"`.")], returns: .void,
                    "The status code, or reason phrase."),
            .method("header", [ScriptParameter("name", .string, "The header's name, in any case."),
                               ScriptParameter("value", .string, "The value it must have.", isOptional: true)], returns: .void,
                    "The header, with the value when given."),
            .method("body", [ScriptParameter("body", .any, "The whole body's text, or a regular expression it matches.", isOptional: true)],
                    returns: .void, "A body, or this one."),
            .method("jsonBody", [ScriptParameter("path", .string, "A dotted path into the JSON, such as `data.id`.", isOptional: true),
                                 ScriptParameter("value", .any, "The value at the path, compared as JSON.", isOptional: true)],
                    returns: .void, "A JSON body, with the dotted path, or the path's value.")
        ]),
        ScriptType("PostmanBe", "Asserts what the response is.", members: [
            .property("ok", .void, "A 2xx response."),
            .property("success", .void, "A 2xx response."),
            .property("json", .void, "A JSON body.")
        ])
    ]

    private static let postmanMembers: [ScriptMember] = [
        .method("test", testParameters, returns: .void, "Runs a named test.", functionType: "PostmanTestFunction").postman("rq.test"),
        .method("expect", expectParameters, returns: .named("Expectation"), "Starts an assertion.").postman("rq.expect"),
        .property("info", .named("PostmanInfo"), "Where this script runs.").postman("rq.info"),
        .property("environment", .named("PostmanEnvironment"), "The active environment's variables.").postman("rq.environment"),
        .property("globals", .named("PostmanGlobals"), "The Global environment's variables.").postman("rq.globals"),
        .property("collectionVariables", .named("PostmanCollectionVariables"), "The project's Default environment's variables.")
            .postman("rq.defaultEnvironment"),
        .property("variables", .named("PostmanVariables"), "Every variable; a value set here lasts for this run.").postman("rq.variables"),
        .property("request", .named("PostmanRequest"), "The request as typed.").postman("rq.request"),
        .property("response", .named("PostmanResponse"), "The HTTP response.", phases: .post, protocols: [.http]).postman("rq.response"),
        .method("sendRequest", [
            ScriptParameter("request", .any, "A URL, or a Postman request: `{ url, method, header, body }`."),
            ScriptParameter("callback", .callback([
                ScriptParameter("error", .optional(.object), "Why the request failed, or `null`."),
                ScriptParameter("response", .named("PostmanSentResponse"), "What came back.")
            ]), "Called with `(error, response)` once it's answered; without it, the call returns a promise.", isOptional: true)
        ], returns: .promise(.named("PostmanSentResponse")), "Sends a request.").postman("rq.sendRequest"),
        .property("cookies", .named("PostmanCookies"), "The cookies for the request's URL.").postman("rq.cookies"),
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
        let key = ScriptParameter("name", .string, "The variable's name.", completion: .variableName(source))
        let value = ScriptParameter("value", .any, "Its new value; anything but a string is stored as JSON.")
        let members: [ScriptMember] = [
            .method("get", [key], returns: .optional(.string), "The variable's value.").postman("\(equivalent).get"),
            .method("set", [key, value], returns: .void, "Sets a value.").postman("\(equivalent).set"),
            .method("unset", [key], returns: .void, "Unsets a value.").postman("\(equivalent).unset"),
            .method("has", [key], returns: .boolean, "Whether it has a value.").postman("\(equivalent).has"),
            .method("toObject", returns: .object, "Every variable with its value.").postman("\(equivalent).toObject"),
            .unsupported("clear", "unset each key instead", isMethod: true)
        ]
        return ScriptType(name, "Postman's name for \(equivalent).", members: members + extra)
    }

    private static let postmanListMembers: [ScriptMember] = {
        let key = ScriptParameter("key", .string, "The entry's key; header keys ignore case.")
        let item = ScriptParameter("item", .any, "A `{ key, value }` object, or the entry's key.")
        let value = ScriptParameter("value", .any, "The value, when `item` is a key.", isOptional: true)
        return [
            .method("get", [key], returns: .optional(.string), "The value.").postman("rq.request.headers.get"),
            .method("has", [key], returns: .boolean, "Whether it's there.").postman("rq.request.headers.has"),
            .method("all", returns: .array(.object), "Every `{ key, value }`.").postman("rq.request.headers.all"),
            .method("toObject", returns: .object, "Every value by key.").postman("rq.request.headers.toObject"),
            .method("add", [item, value], returns: .void, "Adds one.", phases: .pre)
                .postman("rq.request.headers.add"),
            .method("upsert", [item, value], returns: .void, "Sets or adds one.", phases: .pre)
                .postman("rq.request.headers.upsert"),
            .method("remove", [item], returns: .void, "Drops one.", phases: .pre).postman("rq.request.headers.remove")
        ]
    }()

    private static let postmanJarMembers: [ScriptMember] = {
        let url = ScriptParameter("url", .string, "The URL whose cookies these are, or a bare domain for every cookie it has.")
        let name = ScriptParameter("name", .string, "The cookie's name.")
        let callback = ScriptParameter("callback", .function, "Called with `(error, result)` before the call returns.", isOptional: true)
        return [
            .method("get", [url, name, callback], returns: .void, "The cookie's value.").postman("rq.cookies.for(url).get"),
            .method("getAll", [url, callback], returns: .void, "Every cookie for the URL.").postman("rq.cookies.for(url).all"),
            .method("set", [url, ScriptParameter("name", .any, "The cookie's name, or `{ name, value, ...options }`."),
                            ScriptParameter("value", .any, "Its value, when `name` is a name.", isOptional: true), callback], returns: .void,
                    "Sets a cookie, by name and value or as `{ name, value, ...options }`.").postman("rq.cookies.for(url).set"),
            .method("unset", [url, name, callback], returns: .void, "Removes the cookie.").postman("rq.cookies.for(url).remove"),
            .method("clear", [url, callback], returns: .void, "Removes every cookie for the URL.").postman("rq.cookies.for(url).clear")
        ]
    }()

    /// A Postman response's members, `json` returning `json`, each named after `equivalent`'s.
    private static func postmanResponseMembers(json: ScriptValueType, equivalent: String) -> [ScriptMember] {
        [
            .property("code", .number, "The status code.").postman("\(equivalent).code"),
            .property("status", .string, "The reason phrase.").postman("\(equivalent).status"),
            .property("responseTime", .number, "How long it took, in milliseconds.").postman("\(equivalent).responseTime"),
            .property("headers", .named("PostmanList"), "The headers.").postman("\(equivalent).headers"),
            .method("size", returns: .number, "The body's size in bytes.").postman("\(equivalent).size"),
            .method("text", returns: .string, "The body as text.").postman("\(equivalent).text"),
            .method("json", returns: json, "The body, parsed as JSON.").postman("\(equivalent).json"),
            .property("to", .named("PostmanAssertion"), "Assertions about the response.").postman("rq.expect")
        ]
    }
}
