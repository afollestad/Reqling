import Foundation
import MCP
import ReqlingScriptProtocol

/// A project's cookie jar: what its requests send and store, and its scripts read and change, kept in memory until
/// Reqling quits. A target is a URL, for what a request to it sends, or a bare domain, for every cookie of that host and
/// its parent domains, as `rq.cookies.for` takes it (`ScriptCookieScope`).
@MainActor
struct MCPCookieTools {
    let context: MCPToolContext

    var tools: [MCPTool] {
        [listCookies, setCookie, deleteCookies]
    }

    private var listCookies: MCPTool {
        MCPTool(
            "list_cookies",
            title: "List cookies",
            description: "A project's cookies, without their values: name, domain, path, expiry, flags, and value length. `url` "
                + "keeps those a request to it sends, or every cookie of a bare domain.",
            properties: ["project": MCPSchema.project, "url": Self.target("Which cookies; all of them when omitted.")],
            required: ["project"],
            annotations: .read
        ) { arguments in
            let project = try context.project(try arguments.string("project"))
            let scope = try Self.scope(try arguments.optionalString("url"))
            let cookies = context.runner.cookieJar(for: project.id, creating: false)?.cookies(in: scope) ?? []
            return .object(["cookies": .array(cookies.map(Self.describe))])
        }
    }

    private var setCookie: MCPTool {
        MCPTool(
            "set_cookie",
            title: "Set cookie",
            description: "Sets a cookie in a project's jar, which its later requests send; for path `/` and the URL's host alone, "
                + "lasting until Reqling quits, unless the options say otherwise.",
            properties: [
                "project": MCPSchema.project,
                "url": Self.target("The cookie's URL or domain."),
                "name": MCPSchema.string("The cookie's name."),
                "value": MCPSchema.string("Its value, cookie-safe characters only; encode anything else."),
                "path": MCPSchema.string("The path it's sent under; `/` when omitted."),
                "domain": MCPSchema.string("The URL's host or a parent domain, so subdomains get it too; the host alone when omitted."),
                "expires": MCPSchema.string("When it expires, in ISO 8601, at most 400 days out; one already past deletes it."),
                "secure": MCPSchema.boolean("Send it only over HTTPS, and to localhost."),
                "httpOnly": MCPSchema.boolean("Mark it HttpOnly."),
                "sameSite": MCPSchema.enumeration(["Lax", "Strict", "None"], "Its SameSite policy.")
            ],
            required: ["project", "url", "name", "value"],
            annotations: .edit
        ) { arguments in
            let project = try context.project(try arguments.string("project"))
            let scope = try Self.scope(try arguments.string("url"))
            guard let value = try arguments.optionalRawString("value") else {
                throw MCPToolError("value is required.")
            }
            let setting = ScriptCookieSetting(
                name: try arguments.string("name"),
                value: value,
                path: try arguments.optionalString("path"),
                domain: try arguments.optionalString("domain"),
                expires: try Self.date(try arguments.optionalString("expires")),
                isSecure: try arguments.optionalBool("secure") ?? false,
                isHTTPOnly: try arguments.optionalBool("httpOnly") ?? false,
                sameSite: try arguments.optionalString("sameSite")
            )
            guard let scope, let jar = context.runner.cookieJar(for: project.id, creating: true) else {
                throw MCPToolError("“\(project.name)” has no cookie jar.")
            }
            do throws(ScriptCookieError) {
                let cookie = try jar.set(setting, for: scope)
                return .object(["cookie": cookie.map(Self.describe) ?? .null])
            } catch {
                throw MCPToolError(error.message)
            }
        }
    }

    private var deleteCookies: MCPTool {
        MCPTool(
            "delete_cookies",
            title: "Delete cookies",
            description: "Deletes a project's cookies: those `url` covers, only those named `name` when given, or every cookie when "
                + "both are omitted. Cookies don't go to the Trash, so this can't be undone.",
            properties: [
                "project": MCPSchema.project,
                "url": Self.target("Which cookies; all of them when omitted."),
                "name": MCPSchema.string("Only the cookies with this name.")
            ],
            required: ["project"],
            annotations: .destroy
        ) { arguments in
            let project = try context.project(try arguments.string("project"))
            let scope = try Self.scope(try arguments.optionalString("url"))
            let name = try arguments.optionalString("name")
            let deleted = context.runner.cookieJar(for: project.id, creating: false)?.delete(in: scope, named: name) ?? []
            return .object(["deleted": .int(deleted.count), "cookies": .array(deleted.map(Self.describe))])
        }
    }

    /// A cookie as agents see it, never with its value: nothing here tells a session token from any other cookie.
    static func describe(_ cookie: ScriptCookie) -> Value {
        [
            "name": .string(cookie.name),
            "domain": .string(cookie.domain),
            "path": .string(cookie.path),
            "hostOnly": .bool(cookie.isHostOnly),
            "expires": cookie.expires.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "secure": .bool(cookie.isSecure),
            "httpOnly": .bool(cookie.isHTTPOnly),
            "sameSite": cookie.sameSite.map(Value.string) ?? .null,
            "valueLength": .int(cookie.value.utf8.count)
        ]
    }

    private static func target(_ summary: String) -> Value {
        MCPSchema.string(
            "\(summary) A URL means the cookies a request to it sends; a bare domain such as `example.com`, every cookie of that "
                + "host and its parent domains."
        )
    }

    /// A template is refused rather than resolved: which environment would resolve it is the agent's to say.
    private static func scope(_ text: String?) throws -> ScriptCookieScope? {
        guard let text else {
            return nil
        }
        guard !text.contains("{{") else {
            throw MCPToolError("url takes a resolved URL, not a template; resolve_request shows a request's.")
        }
        do {
            return try ScriptCookieScope.parse(text)
        } catch {
            throw MCPToolError(error.message)
        }
    }

    private static func date(_ text: String?) throws -> Date? {
        guard let text else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) {
            return date
        }
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let date = formatter.date(from: text) else {
            throw MCPToolError("expires must be an ISO 8601 date, such as 2027-01-01T00:00:00Z.")
        }
        return date
    }
}
