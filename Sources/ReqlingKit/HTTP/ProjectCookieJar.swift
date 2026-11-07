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
}
