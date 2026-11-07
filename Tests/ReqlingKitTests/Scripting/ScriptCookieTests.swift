import Foundation
import ReqlingScriptProtocol
import XCTest

/// The cookie rules the helper, the app, and MCP share: what a scope means, what a jar sends for it, and what may be set.
final class ScriptCookieTests: XCTestCase {
    private func jar() throws -> HTTPCookieStorage {
        try XCTUnwrap(URLSessionConfiguration.ephemeral.httpCookieStorage)
    }

    private func store(_ header: String, from url: String, in jar: HTTPCookieStorage) throws {
        let url = try XCTUnwrap(URL(string: url))
        jar.setCookies(HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url), for: url, mainDocumentURL: nil)
    }

    private func names(_ jar: HTTPCookieStorage, _ url: String) throws -> [String] {
        try jar.cookies(in: .url(XCTUnwrap(URL(string: url)))).map(\.name).sorted()
    }

    func testAJarFilledThroughScriptCookieSendsWhatTheRealJarSends() throws {
        let real = try jar()
        let responses = [
            ("https://example.com/x", "hostOnly=1; Path=/"),
            ("https://example.com/x", "domain=1; Domain=example.com; Path=/"),
            ("https://example.com/x", "secure=1; Path=/; Secure"),
            ("https://example.com/api/v1", "api=1; Path=/api"),
            ("https://example.com/", "none=1; Path=/; SameSite=None; Secure; HttpOnly"),
            ("https://example.com/", "lax=1; Path=/; SameSite=Lax"),
            ("https://example.com/", "strict=1; Path=/; SameSite=Strict"),
            ("https://example.com/", "aged=1; Path=/; Max-Age=3600"),
            ("http://localhost:8080/", "local=1; Path=/"),
            ("http://localhost:8080/", "localSecure=1; Path=/; Secure"),
            ("http://127.0.0.1:9000/", "ip=1; Path=/")
        ]
        for (url, header) in responses {
            try store(header, from: url, in: real)
        }
        let mirror = try jar()
        for cookie in real.cookies ?? [] {
            mirror.setCookie(try XCTUnwrap(ScriptCookie(cookie).httpCookie))
        }

        let urls = [
            "https://example.com/", "http://example.com/", "https://sub.example.com/", "https://example.com/api",
            "https://example.com/apiv2", "http://localhost:8080/", "http://localhost:1/", "http://127.0.0.1:1/"
        ]
        for url in urls {
            XCTAssertEqual(try names(mirror, url), try names(real, url), url)
        }
        XCTAssertEqual(try names(real, "http://localhost:1/"), ["local", "localSecure"], "Secure cookies go to localhost over http, on any port")
        XCTAssertEqual(try names(real, "https://example.com/apiv2").contains("api"), false, "A path matches on a / boundary")
        XCTAssertEqual(Set((mirror.cookies ?? []).map(ScriptCookie.init)), Set((real.cookies ?? []).map(ScriptCookie.init)))
        let described = Dictionary(uniqueKeysWithValues: (real.cookies ?? []).map { ($0.name, ScriptCookie($0)) })
        XCTAssertEqual(described["none"]?.sameSite, "none")
        XCTAssertEqual(described["none"]?.isHTTPOnly, true)
        XCTAssertEqual(described["domain"]?.domain, "example.com")
        XCTAssertEqual(described["domain"]?.isHostOnly, false)
        XCTAssertEqual(described["hostOnly"]?.isHostOnly, true)
        XCTAssertNotNil(described["aged"]?.expires)
    }

    func testAScopeIsABareDomainOrAURLReadAsARequestsIs() throws {
        XCTAssertEqual(try ScriptCookieScope.parse("example.com"), .domain("example.com"))
        XCTAssertEqual(try ScriptCookieScope.parse(" .Example.COM "), .domain("example.com"))
        XCTAssertEqual(try ScriptCookieScope.parse("127.0.0.1"), .domain("127.0.0.1"))
        XCTAssertEqual(try ScriptCookieScope.parse("localhost:8080").text, "http://localhost:8080")
        XCTAssertEqual(try ScriptCookieScope.parse("example.com/api").text, "http://example.com/api")
        XCTAssertEqual(try ScriptCookieScope.parse("wss://api.example.com/socket?token=1#top").text, "https://api.example.com/socket")
        XCTAssertEqual(try ScriptCookieScope.parse("ws://api.example.com").text, "http://api.example.com")
        XCTAssertEqual(try ScriptCookieScope.parse("https://api.example.com/a b").text, "https://api.example.com/a%20b")
        XCTAssertEqual(try ScriptCookieScope.requestURL("example.com").text, "http://example.com", "A request's own URL is always a URL")
        XCTAssertEqual(try ScriptCookieScope.parse("https://API.example.com/").host, "api.example.com")
        for text in ["", "  ", "ftp://example.com", "http://", "a b"] {
            XCTAssertThrowsError(try ScriptCookieScope.parse(text), text)
        }
        let scope = try ScriptCookieScope.parse("https://api.example.com/v1")
        XCTAssertEqual(try ScriptCookieScope.parse(scope.text), scope, "The canonical text reads back as the same scope")
    }

    func testABareDomainCoversItsOwnAndItsParentsCookiesWhateverTheirPathOrSecureFlag() throws {
        let jar = try jar()
        try store("own=1; Path=/admin; Secure", from: "https://api.example.com/admin", in: jar)
        try store("parent=1; Domain=example.com; Path=/", from: "https://example.com/", in: jar)
        try store("parentHostOnly=1; Path=/", from: "https://example.com/", in: jar)
        try store("child=1; Path=/", from: "https://deep.api.example.com/", in: jar)
        try store("other=1; Path=/", from: "https://other.com/", in: jar)
        try store("aging=1; Path=/; Max-Age=60", from: "https://api.example.com/", in: jar)

        XCTAssertEqual(jar.cookies(in: .domain("api.example.com")).map(\.name), ["own", "aging", "parent"], "Most specific first")
        XCTAssertEqual(jar.cookies(in: .domain("example.com")).map(\.name).sorted(), ["parent", "parentHostOnly"])
        XCTAssertEqual(jar.cookies(in: .domain("api.example.com"), now: Date().addingTimeInterval(120)).map(\.name), ["own", "parent"])
        XCTAssertEqual(jar.cookies(in: nil).count, 6)
    }

    func testWritesSetAndRemoveOneCookieByItsNameDomainAndPath() throws {
        let jar = try jar()
        let scope = ScriptCookieScope.url(try XCTUnwrap(URL(string: "https://api.example.com/v1/login")))
        jar.apply(try ScriptCookieSetting(name: "a", value: "1").write(for: scope))
        jar.apply(try ScriptCookieSetting(name: "a", value: "2", path: "/v1").write(for: scope))
        jar.apply(try ScriptCookieSetting(name: "a", value: "3").write(for: scope))

        XCTAssertEqual(jar.cookies(in: scope).map(\.value), ["2", "3"], "A set replaces the cookie of the same name, domain, and path")
        jar.apply(.remove(ScriptCookieIdentity(name: "a", domain: "api.example.com", isHostOnly: true, path: "/v1")))
        XCTAssertEqual(jar.cookies(in: scope).map(\.value), ["3"])
    }

    func testASettingDefaultsToPathSlashAndThisHostAlone() throws {
        let scope = try ScriptCookieScope.parse("https://api.example.com/v1/login")
        let write = try ScriptCookieSetting(name: "csrf", value: "t0k").write(for: scope)

        XCTAssertEqual(write, .set(ScriptCookie(name: "csrf", value: "t0k", domain: "api.example.com", path: "/", isHostOnly: true)))
        let parent = try ScriptCookieSetting(name: "a", value: "1", domain: ".Example.com", sameSite: "LAX").write(for: scope)
        XCTAssertEqual(parent, .set(ScriptCookie(name: "a", value: "1", domain: "example.com", sameSite: "lax", isHostOnly: false)))
        let address = try ScriptCookieSetting(name: "a", value: "1", domain: "127.0.0.1").write(for: .domain("127.0.0.1"))
        XCTAssertEqual(address.identity.isHostOnly, true, "An IP address has no subdomains")
        let expired = try ScriptCookieSetting(name: "a", value: "1", expires: Date(timeIntervalSince1970: 0)).write(for: scope)
        XCTAssertEqual(expired, .remove(ScriptCookieIdentity(name: "a", domain: "api.example.com", isHostOnly: true, path: "/")))
        XCTAssertEqual(try ScriptCookieSetting(name: "a", value: #""quoted""#).write(for: scope).identity.name, "a")
        XCTAssertThrowsError(try ScriptCookieSetting(name: "a", value: #""quoted value""#).write(for: scope), "Quotes don't allow a space")
    }

    func testASettingThatNoServerCouldSendIsRefused() throws {
        let scope = try ScriptCookieScope.parse("https://api.example.com/")
        var limits = ScriptLimits()
        limits.cookieLength = 8
        let refused: [(ScriptCookieSetting, String)] = [
            (ScriptCookieSetting(name: "", value: "1"), "A cookie needs a name."),
            (ScriptCookieSetting(name: "a b", value: "1"), "names can't hold"),
            (ScriptCookieSetting(name: "a", value: "x;y"), "can't hold spaces, quotes"),
            (ScriptCookieSetting(name: "a", value: "x y"), "can't hold spaces, quotes"),
            (ScriptCookieSetting(name: "a", value: "123456789"), "at most 8 bytes"),
            (ScriptCookieSetting(name: "a", value: "1", path: "v1"), "must start with /"),
            (ScriptCookieSetting(name: "a", value: "1", domain: "other.com"), "not “other.com”"),
            (ScriptCookieSetting(name: "a", value: "1", domain: "pi.example.com"), "not “pi.example.com”"),
            (ScriptCookieSetting(name: "a", value: "1", domain: "com"), "not “com”"),
            (ScriptCookieSetting(name: "a", value: "1", sameSite: "sometimes"), "Lax, Strict, or None")
        ]
        for (setting, message) in refused {
            XCTAssertThrowsError(try setting.write(for: scope, limits: limits), setting.name) { error in
                XCTAssertTrue((error as? ScriptCookieError)?.message.contains(message) == true, "\(error)")
            }
        }
        XCTAssertThrowsError(try ScriptCookieSetting(name: "a", value: "1", domain: "0.0.1").write(for: .domain("127.0.0.1")))
    }
}
