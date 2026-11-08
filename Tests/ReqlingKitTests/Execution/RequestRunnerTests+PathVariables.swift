import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Path variables in runs: an empty one stops the run, and scripts read, set, and scope cookies by them.
@MainActor
extension RequestRunnerTests {
    private func setURL(_ url: String, pathVariables: [KeyValuePair], of request: RequestNodeID, in project: ProjectID) throws {
        try fixture.library.mutate(project) { document in
            try document.updateRequest(request) { $0.kind = .http(HTTPRequestSpec(url: url, pathVariables: pathVariables)) }
        }
    }

    func testAnEmptyPathVariableFailsBeforeAnythingIsSent() async throws {
        let server = try await echoServer()
        let fixtureProject = try makeProject(base: server.baseURL)
        try setURL("{{base}}/users/:id", pathVariables: [KeyValuePair(key: "id", value: "")], of: fixtureProject.request, in: fixtureProject.id)

        let exchange = await makeRunner().run(fixtureProject.request, in: fixtureProject.id)

        XCTAssertEqual(exchange.failure?.kind, .invalidRequest)
        XCTAssertEqual(exchange.failure?.message, "Path variables without a value: :id. Give them one under Params.")
        XCTAssertTrue(server.requests.isEmpty)

        let allowed = await makeRunner().run(fixtureProject.request, in: fixtureProject.id, options: RunOptions(allowUnresolved: true))
        XCTAssertEqual(body(allowed), "GET /users/:id -")
    }

    func testPreRequestScriptsReadAndSetPathVariables() async throws {
        let server = try await echoServer()
        let project = try scriptedProject(base: server.baseURL)
        try setURL("{{base}}/users/:id", pathVariables: [KeyValuePair(key: "id", value: "1")], of: project.profile.id, in: project.id)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: """
        console.log(rq.request.url, rq.request.pathVariables.get("id"))
        rq.request.pathVariables.upsert("id", "2")
        console.log(pm.request.url.variables.get("id"), pm.request.url.toString())
        """))

        let exchange = await makeRunner().run(project.profile.id, in: project.id)

        XCTAssertEqual(body(exchange), "GET /users/2 -")
        XCTAssertEqual(exchange.scriptReport?.phase(.preRequest)?.console.map(\.text), ["{{base}}/users/:id 1", "2 {{base}}/users/:id"])
        let saved = try XCTUnwrap(fixture.library.document(project.id)?.request(project.profile.id)?.kind.httpSpec)
        XCTAssertEqual(saved.pathVariables.first?.value, "1", "A script's change is for this run only")
    }

    func testAScriptsCookieTakesTheSubstitutedPath() async throws {
        let server = try await echoServer()
        let project = try scriptedProject(base: server.baseURL)
        try setURL("{{base}}/teams/:team/me", pathVariables: [KeyValuePair(key: "team", value: "{{team}}")], of: project.profile.id, in: project.id)
        try fixture.library.mutate(project.id) { $0.defaultEnvironment.variables.append(Variable(key: "team", value: "a b")) }
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: """
        rq.cookies.set("seen", "1", { path: "/teams/a%20b" })
        console.log(rq.cookies.get("seen"))
        """))

        let exchange = await makeRunner().run(project.profile.id, in: project.id)

        XCTAssertEqual(body(exchange), "GET /teams/a%20b/me -")
        XCTAssertEqual(exchange.scriptReport?.phase(.preRequest)?.console.map(\.text), ["1"], "The cookie's path matches the URL sent")
    }
}
