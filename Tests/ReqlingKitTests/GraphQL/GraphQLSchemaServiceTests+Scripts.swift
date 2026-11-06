import Foundation
@testable import ReqlingKit
import XCTest

/// Introspection runs the request's pre-request scripts in preview, only when it asks the server.
@MainActor
extension GraphQLSchemaServiceTests {
    func testIntrospectionRunsPreRequestScriptsOnlyWhenItAsksTheServer() async throws {
        let server = try await start(.init(requiredBearerToken: "from-script"))
        let setup = try makeProject(base: server.url.absoluteString)
        try fixture.library.mutate(setup.project) { document in
            try document.updateRequest(setup.request) { request in
                if var spec = request.kind.httpSpec {
                    spec.headers.append(KeyValuePair(key: "Authorization", value: "Bearer {{auth}}"))
                    request.kind = .http(spec)
                }
                request.scripts.preRequest = """
                rq.variables.set("auth", "from-script")
                rq.request.query.upsert("ts", String(Date.now()))
                rq.environment.set("kept", "no")
                """
            }
        }
        let scripts = ScriptFixtures.countingRunner()
        let runner = makeRunner(scripts: scripts)

        var untrusted: RunFailure?
        do {
            _ = try await runner.graphQLSchema(for: setup.request, in: setup.project)
        } catch {
            untrusted = error
        }
        workspace.updateProject(setup.project) { $0.scriptTrust = .trusted }
        _ = try await runner.graphQLSchema(for: setup.request, in: setup.project)
        _ = try await runner.graphQLSchema(for: setup.request, in: setup.project)

        let note = "since this project's scripts aren't trusted on this Mac."
        XCTAssertTrue(untrusted?.message.hasSuffix(note) ?? false, "\(String(describing: untrusted))")
        XCTAssertTrue(untrusted?.message.contains("auth") ?? false, "Only the scripts define it")
        XCTAssertEqual(scripts.launches, 1, "A cached schema runs no scripts, though one changes the query each time")
        let defaultEnvironment = try XCTUnwrap(fixture.library.document(setup.project)).defaultEnvironment.id
        XCTAssertTrue(fixture.library.currentValues.values(in: .environment(setup.project, defaultEnvironment)).isEmpty)
    }
}
