import Foundation
import JavaScriptCore
import ReqlingScriptProtocol

/// The natives `runtime.js` builds `rq.cookies` from. A scope arrives as `null`, for the request's URL, or as the text
/// `cookieTarget` settled on, so `rq.cookies.for(…)` resolves its `{{variables}}` once. Options arrive already checked
/// and normalized by the runtime: `expires` in milliseconds since 1970, or `null`.
extension ScriptLevelHost {
    func installCookies(on native: JSValue) {
        let cookies = phase.cookies
        let target: @convention(block) (String) -> JSValue = { [unowned self] text in
            attempt { () throws(ScriptFailure) -> String in
                try cookies.target(text)
            }
        }
        let read: @convention(block) (JSValue) -> JSValue = { [unowned self] scope in
            do throws(ScriptFailure) {
                let found = try cookies.cookies(in: cookies.scope(Self.text(scope)))
                return JSValue(object: found.map(Self.description), in: context)
            } catch {
                fail(error.message)
                return JSValue(undefinedIn: context)
            }
        }
        let setCookie: @convention(block) (JSValue, String, String, JSValue) -> Void = { [unowned self] scope, name, value, options in
            perform { () throws(ScriptFailure) in
                try cookies.set(Self.setting(name: name, value: value, options: options), in: cookies.scope(Self.text(scope)))
            }
        }
        let remove: @convention(block) (JSValue, String) -> Void = { [unowned self] scope, name in
            perform { () throws(ScriptFailure) in
                try cookies.remove(named: name, in: cookies.scope(Self.text(scope)))
            }
        }
        let clear: @convention(block) (JSValue) -> Void = { [unowned self] scope in
            perform { () throws(ScriptFailure) in
                try cookies.clear(in: cookies.scope(Self.text(scope)))
            }
        }
        set(native, "cookieTarget", target)
        set(native, "cookieRead", read)
        set(native, "cookieSet", setCookie)
        set(native, "cookieRemove", remove)
        set(native, "cookieClear", clear)
    }

    private func perform(_ body: () throws(ScriptFailure) -> Void) {
        do {
            try body()
        } catch {
            fail(error.message)
        }
    }

    private static func text(_ value: JSValue) -> String? {
        value.isNull || value.isUndefined ? nil : value.toString()
    }

    private static func setting(name: String, value: String, options: JSValue) -> ScriptCookieSetting {
        func option(_ key: String) -> JSValue? {
            guard let property = options.objectForKeyedSubscript(key), !property.isNull, !property.isUndefined else {
                return nil
            }
            return property
        }
        return ScriptCookieSetting(
            name: name,
            value: value,
            path: option("path")?.toString(),
            domain: option("domain")?.toString(),
            expires: option("expires").map { Date(timeIntervalSince1970: $0.toDouble() / 1_000) },
            isSecure: option("secure")?.toBool() ?? false,
            isHTTPOnly: option("httpOnly")?.toBool() ?? false,
            sameSite: option("sameSite")?.toString()
        )
    }

    /// What `runtime.js` hands scripts for each cookie; absent values are `null`.
    private static func description(of cookie: ScriptCookie) -> [String: Any] {
        [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "expires": ScriptResponseAccess.nullable(cookie.expires?.formatted(.iso8601)),
            "secure": cookie.isSecure,
            "httpOnly": cookie.isHTTPOnly,
            "sameSite": ScriptResponseAccess.nullable(cookie.sameSite),
            "hostOnly": cookie.isHostOnly
        ]
    }
}
