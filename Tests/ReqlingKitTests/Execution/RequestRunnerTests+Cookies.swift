import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Scripts' cookie changes against the project's real jar, through real runs: what goes out, what comes back, and when
/// changes land.
@MainActor
extension RequestRunnerTests {
    /// Sets `session=abc` on /login and echoes every other request's `Cookie` header.
    func cookieServer() async throws -> TestHTTPServer {
        let server = try await TestHTTPServer.start { request in
            if request.uri.hasPrefix("/login") {
                return .text("in", headers: [("Set-Cookie", "session=abc; Path=/")])
            }
            return .text(request.header("Cookie") ?? "-")
        }
        servers.append(server)
        return server
    }

    /// The echoed `Cookie` header's pairs, whatever their order.
    func sentCookies(_ exchange: RequestExchange) -> Set<String> {
        Set((body(exchange) ?? "").components(separatedBy: "; "))
    }

    func setHeaders(_ project: ScriptedProject, request: RequestNodeID, _ headers: [KeyValuePair]) throws {
        try fixture.library.mutate(project.id) { document in
            try document.updateRequest(request) { item in
                if case .http(var spec) = item.kind {
                    spec.headers = headers
                    item.kind = .http(spec)
                }
            }
        }
    }

    func testAPreRequestCookieGoesOutWithTheRequestAndStaysInTheJar() async throws {
        let server = try await cookieServer()
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: "rq.cookies.set('csrf', 't0k')"))
        let runner = makeRunner()

        let first = await runner.run(project.profile.id, in: project.id)
        try setScripts(project, request: project.profile.id, ScriptSet())
        let second = await runner.run(project.profile.id, in: project.id)

        XCTAssertEqual(body(first), "csrf=t0k")
        XCTAssertEqual(body(second), "csrf=t0k", "The cookie stays in the project's jar")
        XCTAssertEqual(
            first.scriptReport?.phase(.preRequest)?.cookieChanges,
            [ScriptCookieChange(name: "csrf", domain: "127.0.0.1", path: "/", isRemoved: false)]
        )
    }

    func testAPostResponseScriptSeesTheResponsesSetCookieAndTheReportKeepsNoValue() async throws {
        let server = try await cookieServer()
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.login.id, ScriptSet(postResponse: """
        console.log(rq.cookies.get("session"))
        rq.cookies.set("extra", "zz-cookie-value-zz")
        """))
        let runner = makeRunner()

        let login = await runner.run(project.login.id, in: project.id)
        let profile = await runner.run(project.profile.id, in: project.id)

        XCTAssertEqual(login.scriptReport?.phase(.postResponse)?.console.map(\.text), ["abc"])
        XCTAssertEqual(sentCookies(profile), ["session=abc", "extra=zz-cookie-value-zz"])
        let report = try XCTUnwrap(String(bytes: JSONEncoder().encode(login.scriptReport), encoding: .utf8))
        XCTAssertTrue(report.contains("\"cookieChanges\""))
        XCTAssertFalse(report.contains("zz-cookie-value-zz"), "The report never holds a cookie's value")
    }

    func testAPostResponseRemoveTakesTheCookieOutOfTheJar() async throws {
        let server = try await cookieServer()
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(postResponse: "rq.cookies.remove('session')"))
        let runner = makeRunner()

        _ = await runner.run(project.login.id, in: project.id)
        let first = await runner.run(project.profile.id, in: project.id)
        let second = await runner.run(project.profile.id, in: project.id)

        XCTAssertEqual(body(first), "session=abc")
        XCTAssertEqual(body(second), "-")
        XCTAssertEqual(first.scriptReport?.phase(.postResponse)?.cookieChanges.map(\.isRemoved), [true])
    }

    func testCookiesSetBeforeAPreRequestScriptThrowsAreKept() async throws {
        let server = try await cookieServer()
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: "rq.cookies.set('kept', '1')\nthrow new Error('no')"))
        let runner = makeRunner()

        let failed = await runner.run(project.profile.id, in: project.id)
        try setScripts(project, request: project.profile.id, ScriptSet())
        let next = await runner.run(project.profile.id, in: project.id)

        XCTAssertEqual(failed.failure?.kind, .script)
        XCTAssertEqual(body(next), "kept=1")
        XCTAssertEqual(server.requests.count, 1, "The failed run sent nothing")
    }

    func testAPreviewKeepsNoCookie() async throws {
        let server = try await cookieServer()
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: "rq.cookies.set('previewed', '1')"))
        let runner = makeRunner()

        _ = try await runner.prepare(project.profile.id, in: project.id)
        try setScripts(project, request: project.profile.id, ScriptSet())
        let sent = await runner.run(project.profile.id, in: project.id)

        XCTAssertEqual(body(sent), "-")
    }

    func testATypedCookieHeaderSkipsTheJarButScriptChangesStillLandInIt() async throws {
        let server = try await cookieServer()
        let project = try scriptedProject(base: server.baseURL)
        try setHeaders(project, request: project.login.id, [KeyValuePair(key: "Cookie", value: "mine=1")])
        try setHeaders(project, request: project.profile.id, [KeyValuePair(key: "Cookie", value: "mine=1")])
        try setScripts(project, request: project.login.id, ScriptSet(postResponse: """
        console.log(String(rq.cookies.get("session")), rq.response.headers.get("Set-Cookie"))
        """))
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: "rq.cookies.set('csrf', 't0k')"))
        let runner = makeRunner()

        let login = await runner.run(project.login.id, in: project.id)
        let typed = await runner.run(project.profile.id, in: project.id)
        try setHeaders(project, request: project.profile.id, [])
        let fromJar = await runner.run(project.profile.id, in: project.id)

        XCTAssertEqual(login.scriptReport?.phase(.postResponse)?.console.map(\.text), ["undefined session=abc; Path=/"])
        XCTAssertEqual(body(typed), "mine=1", "Only the typed header goes")
        XCTAssertEqual(body(fromJar), "csrf=t0k", "The script's cookie landed; the typed login's Set-Cookie didn't")
    }

    func testAWebSocketHandshakeCarriesACookieSetBeforeIt() async throws {
        let server = try await socketServer { _ in .refuse(status: 403, reason: "Forbidden") }
        let key = try makeSocketProject(url: "\(server.url)/chat")
        workspace.updateProject(key.projectID) { $0.scriptTrust = .trusted }
        try fixture.library.mutate(key.projectID) { document in
            try document.updateRequest(key.requestID) { $0.scripts = ScriptSet(preRequest: "rq.cookies.set('ticket', 'w5')") }
        }

        _ = await makeRunner(sleep: patientSleeper).run(key.requestID, in: key.projectID)

        XCTAssertEqual(server.handshakes.first?.header("Cookie"), "ticket=w5")
    }

    func testAForgottenProjectsJarNeverComesBack() throws {
        let project = try fixture.library.createProject(named: "Gone")
        let runner = makeRunner()

        XCTAssertNil(runner.cookieJar(for: project, creating: false), "Reading makes no executor")
        XCTAssertNotNil(runner.cookieJar(for: project, creating: true))
        XCTAssertNotNil(runner.cookieJar(for: project, creating: false))
        fixture.library.removeProject(project)
        runner.forget(project)

        XCTAssertNil(runner.cookieJar(for: project, creating: true))
    }
}
