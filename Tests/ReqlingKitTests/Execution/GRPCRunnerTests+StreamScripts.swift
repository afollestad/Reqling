import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Stream scripts around gRPC calls, through the real helper: they start once the server answers, take each message
/// received, and reply only while the call's request stream is open.
@MainActor
extension GRPCRunnerTests {
    private func setStreamScript(_ script: String, on request: RequestNodeID, in project: ProjectID) throws {
        workspace.updateProject(project) { $0.scriptTrust = .trusted }
        try fixture.library.mutate(project) { try $0.updateRequest(request) { $0.scripts.stream = script } }
    }

    func testStreamScriptsHandleEachMessageAndReplyOnABidirectionalCall() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("Bidi", messages: [#"{"text": "first"}"#]), server: server)
        try setStreamScript("""
            console.log(rq.response.metadata.get("x-initial"))
            rq.onMessage((message) => {
              rq.test("echoed", () => rq.expect(message.json().text).to.be.a("string"))
              if (message.json().text === "first") rq.send({ text: "reply" })
            })
            """, on: request, in: project)
        let runner = makeRunner()
        let key = RunKey(request, in: project)

        let running = Task { await runner.run(request, in: project, options: RunOptions(keepsStreamOpen: true)) }
        await waitUntil("the reply is echoed") { (try? self.texts(runner.latest[key]?.grpc ?? .empty, .received)) == ["first", "reply"] }
        runner.endStream(request, in: project)
        let exchange = await running.value

        let phase = try XCTUnwrap(exchange.scriptReport?.phase(.stream))
        XCTAssertEqual(try texts(try XCTUnwrap(exchange.grpc), .sent), ["first", "reply"])
        XCTAssertEqual(phase.console.map(\.text), ["hello"])
        XCTAssertEqual(phase.levels.last?.tests.first?.tally, ScriptTestCounts(passed: 2))
        XCTAssertEqual(phase.stream?.handledCount, 2)
    }

    func testAServerStreamingCallsHandlersCanNotReply() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("ServerStream", messages: [#"{"text": "s", "index": 2}"#]), server: server)
        try setStreamScript(
            "rq.onMessage((message) => { console.log(message.json().index ?? 0); rq.send({ text: \"no\" }) })",
            on: request,
            in: project
        )
        let runner = makeRunner()

        let exchange = await runner.run(request, in: project)

        let level = try XCTUnwrap(exchange.scriptReport?.phase(.stream)?.levels.last)
        XCTAssertEqual(exchange.scriptReport?.phase(.stream)?.console.map(\.text), ["0", "1"])
        XCTAssertEqual(level.error?.message, "rq.send can't send: the call's request stream is closed.")
        XCTAssertEqual(level.failedItem, 1)
        XCTAssertEqual(level.failedCallCount, 2)
    }
}
