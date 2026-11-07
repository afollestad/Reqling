import Foundation
import MCP
@testable import ReqlingKit
import XCTest

/// The cookie tools against a project's real jar, filled by a loopback server whose /login sets a session cookie and
/// whose /echo echoes the `Cookie` header it received.
@MainActor
final class MCPCookieToolsTests: XCTestCase {
    private var fixture: MCPFixture!
    private var server: TestHTTPServer!
    private var project: Value!
    private var login: Value!
    private var echo: Value!

    override func setUp() async throws {
        fixture = try MCPFixture()
        server = try await TestHTTPServer.start { request in
            if request.uri.hasPrefix("/login") {
                return .text("in", headers: [("Set-Cookie", "session=abc123; Path=/; HttpOnly")])
            }
            return .text(request.header("Cookie") ?? "-")
        }
        project = .string(try await fixture.makeProject().description)
        _ = try await fixture.success("create_variables", ["project": project, "variables": [
            ["key": "baseUrl", "value": .string(server.baseURL)]
        ]])
        login = try await makeRequest("Login", path: "login")
        echo = try await makeRequest("Echo", path: "echo")
    }

    override func tearDown() async throws {
        try await server.shutdown()
        fixture.cleanUp()
    }

    private func makeRequest(_ name: String, path: String) async throws -> Value {
        let created = try await fixture.success("create_request", [
            "project": project, "name": .string(name), "http": ["url": .string("{{baseUrl}}/\(path)")]
        ])
        return try XCTUnwrap(created["request"]?["id"])
    }

    private func execute(_ request: Value) async throws -> [String: Value] {
        try await fixture.success("execute_request", ["project": project, "request": request])
    }

    private func names(_ result: [String: Value], _ key: String = "cookies") -> [String] {
        (result[key]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }.sorted()
    }

    func testListingDescribesTheJarsCookiesWithoutTheirValues() async throws {
        let empty = try await fixture.success("list_cookies", ["project": project])
        _ = try await execute(login)

        let all = try await fixture.success("list_cookies", ["project": project])
        let forEcho = try await fixture.success("list_cookies", ["project": project, "url": .string("\(server.baseURL)/echo")])
        let elsewhere = try await fixture.success("list_cookies", ["project": project, "url": "example.com"])

        XCTAssertEqual(names(empty), [], "A project that sent nothing has no cookies")
        XCTAssertEqual(all["cookies"], [[
            "name": "session", "domain": "127.0.0.1", "path": "/", "hostOnly": true, "expires": .null,
            "secure": false, "httpOnly": true, "sameSite": .null, "valueLength": 6
        ]])
        XCTAssertFalse(MCPJSON.text(.object(all)).contains("abc123"))
        XCTAssertEqual(names(forEcho), ["session"])
        XCTAssertEqual(names(elsewhere), [])
    }

    func testASetCookieGoesOutWithTheNextRequest() async throws {
        let set = try await fixture.success("set_cookie", [
            "project": project, "url": .string(server.baseURL), "name": "csrf", "value": "t0k", "httpOnly": true, "sameSite": "Strict"
        ])
        let echoed = try await execute(echo)

        XCTAssertEqual(set["cookie"]?["sameSite"], "strict")
        XCTAssertEqual(set["cookie"]?["valueLength"], 3)
        XCTAssertNil(set["cookie"]?["value"])
        XCTAssertEqual(echoed["response"]?["body"], "csrf=t0k")
    }

    func testAnExpiryAlreadyPastDeletesTheCookie() async throws {
        let target: Value = .string(server.baseURL)
        _ = try await fixture.success("set_cookie", ["project": project, "url": target, "name": "a", "value": "1"])

        let expired = try await fixture.success("set_cookie", [
            "project": project, "url": target, "name": "a", "value": "1", "expires": "2000-01-01T00:00:00Z"
        ])

        let left = try await fixture.success("list_cookies", ["project": project])
        XCTAssertEqual(expired["cookie"], .null)
        XCTAssertEqual(names(left), [])
    }

    func testDeletingTakesANamedCookieADomainsOrEveryCookie() async throws {
        for (url, name) in [(server.baseURL, "a"), (server.baseURL, "b"), ("https://api.example.com", "c")] {
            _ = try await fixture.success("set_cookie", ["project": project, "url": .string(url), "name": .string(name), "value": "1"])
        }

        let byName = try await fixture.success("delete_cookies", ["project": project, "name": "a"])
        let byDomain = try await fixture.success("delete_cookies", ["project": project, "url": "api.example.com"])
        let rest = try await fixture.success("delete_cookies", ["project": project])
        let left = try await fixture.success("list_cookies", ["project": project])

        XCTAssertEqual(byName["deleted"], 1)
        XCTAssertEqual(names(byName), ["a"])
        XCTAssertEqual(names(byDomain), ["c"])
        XCTAssertEqual(names(rest), ["b"])
        XCTAssertEqual(names(left), [])
    }

    func testWhatNoServerCouldSendOrNoURLCanNameIsRefused() async {
        func refusal(_ arguments: [String: Value]) async -> String {
            await fixture.failure("set_cookie", ["project": project, "name": "a", "value": "1"].merging(arguments) { $1 })
        }

        let template = await refusal(["url": "{{baseUrl}}"])
        let badName = await refusal(["url": "example.com", "name": "bad name"])
        let badDate = await refusal(["url": "example.com", "expires": "tomorrow"])
        let otherDomain = await refusal(["url": "https://api.example.com", "domain": "other.com"])
        let unknownProject = await fixture.failure("list_cookies", ["project": "Nope"])

        XCTAssertTrue(template.contains("resolved URL"), template)
        XCTAssertTrue(badName.contains("can't be a cookie's name"), badName)
        XCTAssertTrue(badDate.contains("ISO 8601"), badDate)
        XCTAssertTrue(otherDomain.contains("not “other.com”"), otherDomain)
        XCTAssertTrue(unknownProject.contains("No project"), unknownProject)
    }

    func testARunsScriptsReportTheCookiesAndVariablesTheyChangedWithoutValues() async throws {
        _ = try await fixture.success("update_request", [
            "project": project,
            "request": login,
            "scripts": ["postResponse": """
            rq.cookies.set("extra", "zz-cookie-zz")
            rq.cookies.remove("session")
            rq.environment.set("token", "zz-variable-zz", { secret: true })
            """]
        ])

        let result = try await execute(login)

        XCTAssertEqual(result["cookieChanges"], [
            ["phase": "postResponse", "name": "extra", "domain": "127.0.0.1", "path": "/", "removed": false],
            ["phase": "postResponse", "name": "session", "domain": "127.0.0.1", "path": "/", "removed": true]
        ])
        XCTAssertEqual(result["variableChanges"], [
            ["phase": "postResponse", "scope": "environment", "name": "token", "unset": false, "secret": true]
        ])
        let text = MCPJSON.text(.object(result))
        XCTAssertFalse(text.contains("zz-cookie-zz") || text.contains("zz-variable-zz"), text)
    }
}
