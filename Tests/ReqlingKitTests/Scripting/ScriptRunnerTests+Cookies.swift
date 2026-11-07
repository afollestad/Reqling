import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import XCTest

/// `rq.cookies` and `pm.cookies` in the real helper, over a jar the input carries.
@MainActor
extension ScriptRunnerTests {
    private var jar: [ScriptCookie] {
        [
            ScriptCookie(name: "session", value: "abc", domain: "api.example.com"),
            ScriptCookie(name: "secure", value: "s", domain: "api.example.com", isSecure: true),
            ScriptCookie(name: "admin", value: "a", domain: "api.example.com", path: "/admin"),
            ScriptCookie(name: "parent", value: "p", domain: "example.com", isHostOnly: false),
            ScriptCookie(name: "other", value: "o", domain: "other.com")
        ]
    }

    private func layers(_ saved: [String: String]) -> VariableLayers {
        VariableLayers(defaultEnvironment: VariableLayer(saved: saved.mapValues { TemplateVariable(value: $0) }))
    }

    func testTheRequestsCookiesAreWhatItsResolvedURLWouldSend() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, [
            """
            console.log(JSON.stringify(Object.entries(rq.cookies.toObject()).sort()))
            console.log(rq.cookies.get("session"), rq.cookies.has("admin"), rq.cookies.has("secure"))
            console.log(JSON.stringify(rq.cookies.all().find((cookie) => cookie.name === "parent")))
            console.log(rq.cookies.for("https://api.example.com/admin").has("secure"), rq.cookies.for("{{base}}/admin").get("admin"))
            """
        ], variables: layers(["base": "http://api.example.com"]), cookies: jar))

        XCTAssertEqual(run.failures, [:])
        XCTAssertEqual(run.console, [
            #"[["parent","p"],["session","abc"]]"#,
            "abc false false",
            #"{"name":"parent","value":"p","domain":"example.com","path":"/","expires":null,"secure":false,"httpOnly":false,"#
                + #""sameSite":null,"hostOnly":false}"#,
            "true a"
        ])
    }

    func testChangesReachLaterLevelsAndAreReportedBeforeAThrow() async throws {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, [
            """
            rq.cookies.set("csrf", "t0k")
            rq.cookies.remove("session")
            """,
            """
            console.log(rq.cookies.get("csrf"), rq.cookies.has("session"))
            rq.cookies.set("later", 1)
            throw new Error("boom")
            """
        ], variables: layers(["base": "https://api.example.com"]), cookies: jar))

        XCTAssertEqual(run.console, ["t0k false"])
        XCTAssertEqual(run.failures[1]?.message, "boom")
        XCTAssertEqual(run.cookieWrites, [
            .set(ScriptCookie(name: "csrf", value: "t0k", domain: "api.example.com")),
            .remove(ScriptCookieIdentity(name: "session", domain: "api.example.com", isHostOnly: true, path: "/")),
            .set(ScriptCookie(name: "later", value: "1", domain: "api.example.com"))
        ])
    }

    func testForReachesAnotherURLOrEveryCookieOfADomain() async throws {
        let run = await fixtures.run(ScriptFixtures.input(.postResponse, [
            """
            console.log(rq.cookies.for("api.example.com").all().map((cookie) => cookie.name).join())
            console.log(rq.cookies.for("wss://api.example.com/socket").get("session"))
            rq.cookies.for("{{auth}}").set("sid", "x", {
              domain: "example.com", path: "/v1", secure: true, httpOnly: true, sameSite: "Strict", expires: new Date(Date.now() + 86400000)
            })
            const sid = rq.cookies.for("example.com").all().find((cookie) => cookie.name === "sid")
            console.log(Math.round((Date.parse(sid.expires) - Date.now()) / 3600000), sid.expires.endsWith("Z"))
            for (const attempt of [
              () => rq.cookies.for("{{missing}}"),
              () => rq.cookies.for("ftp://example.com"),
              () => rq.cookies.for("example.com").set("bad name", "1"),
              () => rq.cookies.for("example.com").set("a", "1", { maxAge: 60 }),
              () => rq.cookies.for("example.com").set("a", "1", { expires: "someday" }),
              () => rq.cookies.for(),
            ]) {
              try { attempt(); console.log("no error") } catch (error) { console.log(error.message) }
            }
            """
        ], variables: layers(["auth": "https://auth.example.com/login"]), response: Self.emptyResponse, cookies: jar), blobs: [Data()])

        XCTAssertEqual(run.failures, [:])
        XCTAssertEqual(run.console, [
            "admin,secure,session,parent",
            "abc",
            "24 true",
            "rq.cookies.for: {{missing}} isn't defined.",
            "rq.cookies.for: Cookies belong to http and https URLs, not “ftp://example.com”.",
            "“bad name” can't be a cookie's name: names can't hold spaces, control characters, or ( ) < > @ , ; : \\ \" / [ ] ? = { }.",
            #"A cookie has no option "maxAge"; it takes path, domain, expires, secure, httpOnly, sameSite."#,
            #"A cookie's expires is a Date, a date string, or milliseconds since 1970, not someday."#,
            #"rq.cookies.for needs a URL or a domain, such as "https://api.example.com" or "example.com"."#
        ])
        guard case .set(var cookie) = try XCTUnwrap(run.cookieWrites.first), let expires = cookie.expires else {
            return XCTFail("\(run.cookieWrites)")
        }
        XCTAssertEqual(expires.timeIntervalSinceNow, 86_400, accuracy: 60)
        cookie.expires = nil
        XCTAssertEqual(cookie, ScriptCookie(
            name: "sid", value: "x", domain: "example.com", path: "/v1", isSecure: true, isHTTPOnly: true, sameSite: "strict", isHostOnly: false
        ))
        XCTAssertEqual(run.cookieWrites.count, 1)
    }

    func testAGRPCCallOrAnUndefinedURLReachesTheJarOnlyThroughFor() async {
        let attempts = """
        try { rq.cookies.get("session") } catch (error) { console.log(error.message) }
        rq.cookies.for("example.com").set("a", "1")
        """
        let grpc = await fixtures.run(ScriptFixtures.input(.preRequest, [attempts], request: ScriptFixtures.request("grpc"), cookies: jar))
        let undefined = await fixtures.run(ScriptFixtures.input(.preRequest, [attempts], cookies: jar))

        XCTAssertEqual(grpc.console, ["A gRPC call has no URL for cookies; use rq.cookies.for(url)."])
        XCTAssertEqual(undefined.console, ["This request's URL uses {{base}}, which isn't defined, so it has no cookies; use rq.cookies.for(url)."])
        XCTAssertEqual(grpc.cookieWrites.map(\.identity.name), ["a"])
        XCTAssertEqual(undefined.cookieWrites.map(\.identity.name), ["a"])
    }

    func testCookieWritesStopAtThePhasesLimitAndAClearPastItRemovesNothing() async {
        var limits = ScriptLimits()
        limits.cookieWrites = 3
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, [
            """
            rq.cookies.set("a", "1")
            rq.cookies.set("b", "2")
            try { rq.cookies.for("api.example.com").clear() } catch (error) { console.log(error.message) }
            rq.cookies.set("c", "3")
            try { rq.cookies.set("d", "4") } catch (error) { console.log(error.message) }
            """
        ], variables: layers(["base": "https://api.example.com"]), cookies: jar, limits: limits))

        XCTAssertEqual(run.console, [
            "Scripts can set or remove at most 3 cookies in one phase.",
            "Scripts can set or remove at most 3 cookies in one phase."
        ])
        XCTAssertEqual(run.cookieWrites.map(\.identity.name), ["a", "b", "c"])
    }

    func testPostmansCookiesAndJarMapOntoRqCookies() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, [
            """
            console.log(pm.cookies.get("session"), pm.cookies.has("nope"), Object.keys(pm.cookies.toObject()).sort().join())
            const jar = pm.cookies.jar()
            const url = "https://api.example.com"
            jar.set(url, "a", "1", (error, cookie) => console.log("set", error, cookie.name, cookie.value))
            jar.set(url, { name: "b", value: "2", httpOnly: true, maxAge: 60 }, (error, cookie) => {
              console.log("object", cookie.httpOnly, cookie.expires !== null)
            })
            jar.get(url, "a", (error, value) => console.log("get", error, value))
            jar.getAll(url, (error, cookies) => console.log("getAll", cookies.map((cookie) => cookie.name).sort().join()))
            jar.unset(url, "a", (error) => console.log("unset", error, rq.cookies.has("a")))
            jar.set(url, "bad name", "1", (error) => console.log("error", error.message.startsWith("“bad name”")))
            let calls = 0
            try { jar.get(url, "b", () => { calls += 1; throw new Error("callback threw") }) } catch (error) { console.log(error.message, calls) }
            try { jar.set(url, { name: "c", value: "3", session: true }) } catch (error) { console.log(error.message) }
            jar.clear("api.example.com", (error) => console.log("clear", error, rq.cookies.for("api.example.com").all().length))
            """
        ], variables: layers(["base": "https://api.example.com"]), cookies: jar))

        XCTAssertEqual(run.failures, [:])
        XCTAssertEqual(run.console, [
            "abc false parent,secure,session",
            "set null a 1",
            "object true true",
            "get null 1",
            "getAll a,b,parent,secure,session",
            "unset null false",
            "error true",
            "callback threw 1",
            "pm.cookies.jar().set takes name, value, domain, path, expires, maxAge, secure, httpOnly, sameSite, not \"session\".",
            "clear null 0"
        ])
    }

    func testWhatForJarAndACookieHoldIsWhatTheCatalogDocuments() async throws {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, [
            """
            const keys = (value) => Object.keys(value).sort().join()
            console.log(keys(rq.cookies.for("example.com")))
            console.log(keys(pm.cookies.jar()))
            console.log(keys(rq.cookies.for("example.com").all()[0]))
            """
        ], cookies: jar))
        let catalog = ScriptAPICatalog.standard
        func members(_ type: String) throws -> String {
            try XCTUnwrap(catalog.type(type)).members.map(\.name).sorted().joined(separator: ",")
        }

        XCTAssertEqual(run.console, [try members("Cookies"), try members("PostmanCookieJar"), try members("Cookie")])
    }

    private static let emptyResponse = ScriptResponseSnapshot.http(ScriptHTTPResponse(
        code: 200, status: "OK", headers: [], body: ScriptBlob(index: 0, size: 0), size: 0, truncated: false, responseTime: 1
    ))
}
