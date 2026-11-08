import ReqlingScriptProtocol

/// The names a script reaches without a receiver: Reqling's own, the web APIs scripts expect, the vendored libraries,
/// and the JavaScript built-ins completion offers.
extension ScriptAPICatalog {
    static let globalMembers: [ScriptMember] = reqlingGlobals + standardGlobals

    static let reqlingGlobals: [ScriptMember] = {
        let callback = ScriptParameter("callback", .function, "What to run.")
        let delay = ScriptParameter("delay", .number, "How long to wait, in milliseconds; 0 by default.", isOptional: true)
        let id = ScriptParameter("id", .number, "What `setTimeout` or `setInterval` gave back.")
        return [
            .property("rq", .named("Reqling"), "Reqling's script API: variables, the request, the response, and tests."),
            .property("pm", .named("Postman"), "Postman's script API, for scripts written for Postman.")
                .postman("rq"),
            .property("console", .named("Console"), "Logs to the response's Tests tab."),
            .property("crypto", .named("WebCrypto"), "Random values, as the Web Crypto API gives them."),
            .method("btoa", [ScriptParameter("text", .string, "Text whose characters are each a byte, from U+0000 to U+00FF.")], returns: .string,
                    "Base64 of text whose characters are each a byte."),
            .method("atob", [ScriptParameter("base64", .string, "Base64 text.")], returns: .string,
                    "Decodes base64 to text with a character per byte."),
            .method("setTimeout", [callback, delay], returns: .number, "Runs the callback once, after the delay in milliseconds."),
            .method("setInterval", [callback, delay], returns: .number, "Runs the callback every delay milliseconds."),
            .method("clearTimeout", [id], returns: .void, "Cancels a timeout."),
            .method("clearInterval", [id], returns: .void, "Cancels an interval."),
            // `ScriptRuntimeConformanceTests` checks these choices are the runner's vendored libraries.
            .method("require", [ScriptParameter("name", .string, "`crypto-js` or `lodash`.",
                                                completion: .choices(["crypto-js", "lodash"], exhaustive: true, matchesCase: true))],
                    returns: .any, "Loads `crypto-js` or `lodash`."),
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
        .method("parseInt", [ScriptParameter("text", .string, "The text to parse."),
                             ScriptParameter("radix", .number, "The base, from 2 to 36; 10 by default.", isOptional: true)],
                returns: .number, "Parses an integer."),
        .method("parseFloat", [ScriptParameter("text", .string, "The text to parse.")], returns: .number, "Parses a number."),
        .method("encodeURIComponent", [ScriptParameter("text", .string, "The text to encode.")], returns: .string,
                "Percent-encodes a URL component."),
        .method("decodeURIComponent", [ScriptParameter("text", .string, "The percent-encoded text.")], returns: .string,
                "Decodes a percent-encoded URL component."),
        .method("isNaN", [ScriptParameter("value", .any, "The value to test, converted to a number first.")], returns: .boolean,
                "Whether the value is NaN.")
    ]

    static let libraryTypes: [ScriptType] = [
        ScriptType("Console", "Logs to the response's Tests tab; objects print as indented JSON.", members:
            ["log", "info", "warn", "error", "debug"].map { name in
                .method(name, [ScriptParameter("values", .any, "What to log; objects print as indented JSON.", isRest: true)], returns: .void,
                        "Logs the values, separated by spaces.")
            }),
        ScriptType("WebCrypto", "Random values.", members: [
            .method("getRandomValues", [ScriptParameter("array", .object, "An integer typed array, such as `new Uint8Array(16)`.")],
                    returns: .object, "Fills an integer typed array with random values."),
            .method("randomUUID", returns: .string, "A random UUID.")
        ]),
        ScriptType("CryptoJS", "crypto-js 4.2.0.", isOpen: true, members: cryptoJSMembers),
        ScriptType("Lodash", "lodash 4.17.21.", isOpen: true, members: ["get", "set", "pick", "omit", "map", "filter", "find", "chunk", "uniq"]
            .map { name in
                .method(name, [ScriptParameter("args", .any, "The arguments lodash's `\(name)` takes.", isRest: true)], returns: .any,
                        "lodash's `\(name)`.")
            }),
        ScriptType("JSONObject", "JSON.", isOpen: true, members: [
            .method("parse", [ScriptParameter("text", .string, "JSON text.")], returns: .any, "Parses JSON."),
            .method("stringify", [ScriptParameter("value", .any, "The value to write."),
                                  ScriptParameter("replacer", .any, "A function that changes each value, or an array of the keys to keep.",
                                                  isOptional: true),
                                  ScriptParameter("space", .any, "Indents with this many spaces, or this text.", isOptional: true)],
                    returns: .string, "Writes JSON.")
        ]),
        ScriptType("MathObject", "Math.", isOpen: true, members: ["abs", "ceil", "floor", "round"].map { name in
            .method(name, [ScriptParameter("value", .number, "The number.")], returns: .number, "Math's `\(name)`.")
        } + ["max", "min"].map { name in
            .method(name, [ScriptParameter("values", .number, "The numbers to compare.", isRest: true)], returns: .number, "Math's `\(name)`.")
        } + [
            .method("random", returns: .number, "A random number from 0 up to, but not including, 1.")
        ])
    ]

    private static let cryptoJSMembers: [ScriptMember] = {
        let message = ScriptParameter("message", .any, "Text, or a `CryptoJS.lib.WordArray`.")
        let key = ScriptParameter("key", .any, "The secret key: text, or a `CryptoJS.lib.WordArray`.")
        let hashes: [ScriptMember] = ["MD5", "SHA1", "SHA256", "SHA512"].map { name in
            .method(name, [message], returns: .object, "Hashes the message.")
        }
        let hmacs: [ScriptMember] = ["HmacSHA1", "HmacSHA256", "HmacSHA512"].map { name in
            .method(name, [message, key], returns: .object, "An HMAC of the message.")
        }
        return hashes + hmacs + [
            .property("enc", .object, "Encoders: `Hex`, `Base64`, `Utf8`, and others."),
            .property("lib", .object, "Building blocks, such as `WordArray`."),
            .property("AES", .object, "AES encryption.")
        ]
    }()
}
