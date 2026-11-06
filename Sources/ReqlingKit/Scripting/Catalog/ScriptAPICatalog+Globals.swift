import ReqlingScriptProtocol

/// The names a script reaches without a receiver: Reqling's own, the web APIs scripts expect, the vendored libraries,
/// and the JavaScript built-ins completion offers.
extension ScriptAPICatalog {
    static let globalMembers: [ScriptMember] = reqlingGlobals + standardGlobals

    static let reqlingGlobals: [ScriptMember] = {
        let callback = ScriptParameter("callback", .function)
        let delay = ScriptParameter("delay", .number, isOptional: true)
        let id = ScriptParameter("id", .number)
        return [
            .property("rq", .named("Reqling"), "Reqling's script API: variables, the request, the response, and tests."),
            .property("pm", .named("Postman"), "Postman's script API, for scripts written for Postman.")
                .postman("rq"),
            .property("console", .named("Console"), "Logs to the response's Tests tab."),
            .property("crypto", .named("WebCrypto"), "Random values, as the Web Crypto API gives them."),
            .method("btoa", [ScriptParameter("text", .string)], returns: .string, "Base64 of text whose characters are each a byte."),
            .method("atob", [ScriptParameter("base64", .string)], returns: .string, "Decodes base64 to text with a character per byte."),
            .method("setTimeout", [callback, delay], returns: .number, "Runs the callback once, after the delay in milliseconds."),
            .method("setInterval", [callback, delay], returns: .number, "Runs the callback every delay milliseconds."),
            .method("clearTimeout", [id], returns: .void, "Cancels a timeout."),
            .method("clearInterval", [id], returns: .void, "Cancels an interval."),
            .method("require", [ScriptParameter("name", .string)], returns: .any, "Loads `crypto-js` or `lodash`."),
            .property("CryptoJS", .named("CryptoJS"), "crypto-js 4.2.0, loaded on first use."),
            .property("_", .named("Lodash"), "lodash 4.17.21, loaded on first use.")
        ]
    }()

    /// JavaScript's own, for completion; none is walked or warned about.
    private static let standardGlobals: [ScriptMember] = [
        .property("JSON", .named("JSONObject"), "Parses and writes JSON."),
        .property("Math", .named("MathObject"), "Math functions and constants."),
        .property("Date", .function, "Dates and times."),
        .property("Object", .function, "Object helpers."),
        .property("Array", .function, "Array helpers."),
        .property("String", .function, "Converts to a string."),
        .property("Number", .function, "Converts to a number."),
        .property("Boolean", .function, "Converts to a boolean."),
        .property("Promise", .function, "Promises."),
        .property("RegExp", .function, "Regular expressions."),
        .property("Error", .function, "Errors."),
        .property("Map", .function, "Maps."),
        .property("Set", .function, "Sets."),
        .method("parseInt", [ScriptParameter("text", .string), ScriptParameter("radix", .number, isOptional: true)], returns: .number,
                "Parses an integer."),
        .method("parseFloat", [ScriptParameter("text", .string)], returns: .number, "Parses a number."),
        .method("encodeURIComponent", [ScriptParameter("text", .string)], returns: .string, "Percent-encodes a URL component."),
        .method("decodeURIComponent", [ScriptParameter("text", .string)], returns: .string, "Decodes a percent-encoded URL component."),
        .method("isNaN", [ScriptParameter("value", .any)], returns: .boolean, "Whether the value is NaN.")
    ]

    static let libraryTypes: [ScriptType] = [
        ScriptType("Console", "Logs to the response's Tests tab; objects print as indented JSON.", members:
            ["log", "info", "warn", "error", "debug"].map { name in
                .method(name, [ScriptParameter("values", .any)], returns: .void, "Logs the values, separated by spaces.")
            }),
        ScriptType("WebCrypto", "Random values.", members: [
            .method("getRandomValues", [ScriptParameter("array", .object)], returns: .object, "Fills an integer typed array with random values."),
            .method("randomUUID", returns: .string, "A random UUID.")
        ]),
        ScriptType("CryptoJS", "crypto-js 4.2.0.", isOpen: true, members: ["MD5", "SHA1", "SHA256", "SHA512", "HmacSHA1", "HmacSHA256"]
            .map { name in .method(name, [ScriptParameter("message", .any)], returns: .object, "Hashes the message.") } + [
                .method("HmacSHA512", [ScriptParameter("message", .any)], returns: .object, "Hashes the message."),
                .property("enc", .object, "Encoders: `Hex`, `Base64`, `Utf8`, and others."),
                .property("lib", .object, "Building blocks, such as `WordArray`."),
                .property("AES", .object, "AES encryption.")
            ]),
        ScriptType("Lodash", "lodash 4.17.21.", isOpen: true, members: ["get", "set", "pick", "omit", "map", "filter", "find", "chunk", "uniq"]
            .map { name in .method(name, [ScriptParameter("values", .any)], returns: .any, "lodash's `\(name)`.") }),
        ScriptType("JSONObject", "JSON.", isOpen: true, members: [
            .method("parse", [ScriptParameter("text", .string)], returns: .any, "Parses JSON."),
            .method("stringify", [ScriptParameter("value", .any), ScriptParameter("replacer", .any, isOptional: true),
                                  ScriptParameter("space", .any, isOptional: true)], returns: .string, "Writes JSON.")
        ]),
        ScriptType("MathObject", "Math.", isOpen: true, members: ["abs", "ceil", "floor", "max", "min", "random", "round"].map { name in
            .method(name, [ScriptParameter("value", .number)], returns: .number, "Math's `\(name)`.")
        })
    ]
}
