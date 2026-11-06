import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

/// Pre-request and post-response scripts around a gRPC call, through the real helper.
@MainActor
extension GRPCRunnerTests {
    func testScriptsSetACallsMetadataAndMessageThenTestWhatCameBack() async throws {
        let server = try await start()
        let (project, request) = try makeProject(
            echoSpec("Unary", messages: [#"{"text": "{{greeting}}"}"#]),
            server: server,
            variables: [Variable(key: "token", value: "s3cr3t-token", isSecret: true)]
        )
        workspace.updateProject(project) { $0.scriptTrust = .trusted }
        try setScripts(ScriptSet(
            preRequest: """
            rq.variables.set("greeting", "scripted")
            rq.request.metadata.upsert("x-secret", rq.environment.get("token"))
            """,
            postResponse: """
            rq.test("ok", () => rq.expect(rq.response.status.name).to.equal("OK"))
            rq.test("echoed", () => rq.expect(rq.response.json().text).to.equal("scripted"))
            """
        ), on: request, in: project)
        let runner = makeRunner()

        let exchange = await runner.run(request, in: project)
        try setScripts(ScriptSet(preRequest: "throw new Error('no')"), on: request, in: project)
        let stopped = await runner.run(request, in: project)

        let call = try XCTUnwrap(exchange.grpc, "\(exchange.outcome)")
        XCTAssertEqual(try texts(call, .sent), ["scripted"], "A message resolves against what the scripts set")
        XCTAssertEqual(log.received.first?["x-secret"], "s3cr3t-token")
        XCTAssertTrue(call.sentMetadata.contains(key: "x-secret", value: TemplateResolver.mask))
        XCTAssertEqual(call.scriptChangedMetadata, ["x-secret"])
        XCTAssertEqual(exchange.scriptReport?.testCounts, ScriptTestCounts(passed: 2))
        XCTAssertEqual(stopped.failure?.kind, .script)
        XCTAssertEqual(log.received.count, 1, "A failed pre-request script stops the call before it reaches the server")
    }

    private func setScripts(_ scripts: ScriptSet, on request: RequestNodeID, in project: ProjectID) throws {
        try fixture.library.mutate(project) { try $0.updateRequest(request) { $0.scripts = scripts } }
    }
}
