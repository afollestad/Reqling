import ReqlingScriptProtocol

/// `rq.cookies`: the project's cookie jar, scoped to the request's URL or, through `for(…)`, to any other URL or domain.
/// The request-scoped methods are HTTP's and WebSocket's: a gRPC call is sent to no URL, so its scripts use `for(…)`.
extension ScriptAPICatalog {
    static let cookieTypes: [ScriptType] = [
        ScriptType(
            "RequestCookies",
            "The project's cookies that go to this request's URL. Pre-request changes go out with the request, and every change "
                + "stays in the project's jar until Reqling quits.",
            members: cookieMembers(protocols: .withCookies) + [
                .method("for", [ScriptParameter("target", .string, "A URL, or a bare domain such as `example.com` for every cookie it has.")],
                        returns: .named("Cookies"),
                        "The cookies for another URL, or every cookie for a bare domain such as `example.com`; `{{variables}}` resolve.")
            ]
        ),
        ScriptType("Cookies", "The project's cookies for a URL, or every cookie for a domain.", members: cookieMembers(protocols: nil)),
        ScriptType("Cookie", "One cookie.", members: [
            .property("name", .string, "Its name."),
            .property("value", .string, "Its value."),
            .property("domain", .string, "The host it's for, without a leading dot."),
            .property("path", .string, "The path it's sent under."),
            .property("expires", .optional(.string), "When it expires, in ISO 8601; `null` lasts until Reqling quits."),
            .property("secure", .boolean, "Sent only over HTTPS, and to localhost."),
            .property("httpOnly", .boolean, "Marked `HttpOnly`."),
            .property("sameSite", .optional(.string), "`lax`, `strict`, `none`, or `null`."),
            .property("hostOnly", .boolean, "Sent only to `domain` itself, not to its subdomains.")
        ]),
        ScriptType("CookieOptions", "How `set` sets a cookie.", members: [
            .property("path", .string, "The path it's sent under; `/` when left out."),
            .property("domain", .string, "A domain it goes to with its subdomains; this host alone when left out."),
            .property("expires", .any, "A `Date`, a date string, or milliseconds since 1970; until Reqling quits when left out. One "
                + "already past removes the cookie."),
            .property("secure", .boolean, "Sends it only over HTTPS, and to localhost."),
            .property("httpOnly", .boolean, "Marks it `HttpOnly`."),
            .property("sameSite", .string, "`lax`, `strict`, or `none`.", completion: .choices(["lax", "strict", "none"]))
        ])
    ]

    /// A cookie's name, which `pm.cookies` shares.
    static let cookieName = ScriptParameter("name", .string, "The cookie's name.")

    private static func cookieMembers(protocols: ScriptProtocols?) -> [ScriptMember] {
        let name = cookieName
        let value = ScriptParameter("value", .any, "Its value; anything but a string is written as JSON.")
        let options = ScriptParameter(
            "options",
            .named("CookieOptions"),
            "`{ path, domain, expires, secure, httpOnly, sameSite }`; path `/`, this host alone, until Reqling quits by default.",
            isOptional: true
        )
        return [
            .method("get", [name], returns: .optional(.string), "The value of the first cookie with the name, or `undefined`.",
                    protocols: protocols),
            .method("has", [name], returns: .boolean, "Whether a cookie has the name.", protocols: protocols),
            .method("all", returns: .array(.named("Cookie")), "Every cookie, the most specific first.", protocols: protocols),
            .method("toObject", returns: .object, "Every cookie's value by name.", protocols: protocols),
            .method("set", [name, value, options], returns: .void,
                    "Sets a cookie for path `/` and this host alone, lasting until Reqling quits, unless "
                        + "`{ path, domain, expires, secure, httpOnly, sameSite }` say otherwise. An `expires` already past removes it.",
                    protocols: protocols),
            .method("remove", [name], returns: .void, "Removes every cookie with the name.", protocols: protocols),
            .method("clear", returns: .void, "Removes every cookie.", protocols: protocols)
        ]
    }
}
