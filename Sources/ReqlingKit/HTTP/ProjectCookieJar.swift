import Foundation
import ReqlingScriptProtocol

/// A project's cookie jar as scripts and agents reach it, outside a transport. Writes change one cookie at a time and
/// never replace the jar, so a `Set-Cookie` that a request in flight stores meanwhile stays. Reach it only through
/// `RequestRunner.cookieJar(for:creating:)`.
struct ProjectCookieJar {
    let storage: HTTPCookieStorage

    func cookies(in scope: ScriptCookieScope?) -> [ScriptCookie] {
        storage.cookies(in: scope).map(ScriptCookie.init)
    }

    func apply(_ writes: [ScriptCookieWrite]) {
        for write in writes {
            storage.apply(write)
        }
    }

    /// Sets the cookie `setting` describes for `scope`, and returns it as the jar keeps it, which caps an expiry at 400
    /// days; `nil` when an `expires` already past removed it instead.
    func set(_ setting: ScriptCookieSetting, for scope: ScriptCookieScope) throws(ScriptCookieError) -> ScriptCookie? {
        let write = try setting.write(for: scope)
        storage.apply(write)
        guard case .set(let cookie) = write else {
            return nil
        }
        return (storage.cookies ?? []).first(where: cookie.identity.matches).map(ScriptCookie.init) ?? cookie
    }

    /// Removes the cookies `scope` covers, every cookie for `nil`, or only those of them named `name`; returns them.
    func delete(in scope: ScriptCookieScope?, named name: String?) -> [ScriptCookie] {
        let removed = storage.cookies(in: scope).filter { name == nil || $0.name == name }
        for cookie in removed {
            storage.deleteCookie(cookie)
        }
        return removed.map(ScriptCookie.init)
    }
}
