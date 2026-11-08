import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Stream scripts: a handler's parameter typed as what the API calls it with, and what a stream script's phase and
/// protocol allow.
extension ScriptAnalyzerTests {
    /// What completes at `|`, or at the end.
    private func streamLabels(_ marked: String, protocols: ScriptProtocols?) -> [String] {
        let cursor = marked.contains("|") ? (marked as NSString).range(of: "|").location : (marked as NSString).length
        let text = marked.replacingOccurrences(of: "|", with: "")
        let context = ScriptAnalysisContext(phase: .stream, protocols: protocols)
        return ScriptAnalyzer(text: text, context: context).completions(at: cursor)?.items.map(\.label) ?? []
    }

    private func streamWarnings(_ text: String, phase: ScriptPhase = .stream, protocols: ScriptProtocols?) -> [String] {
        ScriptAnalyzer(text: text, context: ScriptAnalysisContext(phase: phase, protocols: protocols)).diagnostics().map(\.message)
    }

    func testAHandlersParameterCompletesAsWhatItIsCalledWith() {
        let events = ScriptAnalysisContext.protocols(for: .http)
        XCTAssertEqual(streamLabels("rq.onEvent(event => event.", protocols: events), ["id", "event", "data", "retry", "json"])
        XCTAssertEqual(streamLabels("rq.onEvent(async (e) => { e.da| })", protocols: events), ["data"])
        XCTAssertEqual(streamLabels("rq.onMessage(function (m) { m.is| })", protocols: [.webSocket]), ["isBinary"])
        XCTAssertEqual(streamLabels("rq.onMessage(message => message.", protocols: [.grpc]), ["text", "json"])
        XCTAssertEqual(streamLabels("rq.onMessage(m => m.", protocols: nil), [], "A folder's script: a message of either kind")
    }

    func testOnlyAFunctionPassedWholeToACallbackIsTyped() {
        let events = ScriptAnalysisContext.protocols(for: .http)

        XCTAssertEqual(streamWarnings("rq.onEvent(e => e.nope)", protocols: events), ["e has no “nope”."])
        XCTAssertEqual(streamWarnings("rq.onEvent(e => e.json().anything)", protocols: events), [])
        XCTAssertEqual(streamWarnings("[1].map(x => x.nope)", protocols: events), [])
        XCTAssertEqual(streamWarnings("rq.test(\"t\", x => x.nope)", protocols: events), [], "A test's callback gets nothing")
        XCTAssertEqual(streamWarnings("rq.onEvent(c ? e => e.nope : null)", protocols: events), [])
        XCTAssertEqual(streamWarnings("rq.onMessage(m => m.direction)", protocols: nil), [])
        XCTAssertEqual(
            streamWarnings("rq.response.messages[0].direction", phase: .postResponse, protocols: nil),
            [],
            "Either kind of message, so neither is assumed"
        )
    }

    func testAStreamScriptReadsOnlyWhatTheStreamOpenedWith() {
        let events = ScriptAnalysisContext.protocols(for: .http)
        let http = streamLabels("rq.response.", protocols: events)

        XCTAssertTrue(["code", "status", "headers"].allSatisfy(http.contains))
        XCTAssertFalse(http.contains("events") || http.contains("json"))
        XCTAssertEqual(streamLabels("rq.response.", protocols: [.webSocket]), ["code", "headers", "subprotocol"])
        XCTAssertEqual(streamLabels("rq.response.", protocols: [.grpc]), ["metadata"])
        XCTAssertEqual(streamWarnings("rq.response.code", protocols: [.grpc]), ["rq.response.code works only in post-response scripts."])
        XCTAssertEqual(streamWarnings("rq.response.status", protocols: [.webSocket]), ["rq.response.status applies only to HTTP requests."])
        XCTAssertEqual(streamWarnings("rq.onEvent(() => {})", phase: .postResponse, protocols: events), [
            "rq.onEvent works only in stream scripts."
        ])
        XCTAssertEqual(streamWarnings("rq.onEvent(() => {})", protocols: [.webSocket]), ["rq.onEvent applies only to HTTP requests."])
        XCTAssertEqual(streamWarnings("rq.send(1)", protocols: events), ["rq.send applies only to gRPC and WebSocket requests."])
    }

    func testAHandlersHintsAndParameterDescribeWhatItGets() throws {
        let text = "rq.onEvent(event => event.data)"
        let analyzer = ScriptAnalyzer(text: text, context: ScriptAnalysisContext(phase: .stream, protocols: [.eventStream]))
        let help = try XCTUnwrap(analyzer.signatureHelp(at: 11))
        let parameter = try XCTUnwrap(analyzer.hover(at: 21))
        let member = try XCTUnwrap(analyzer.hover(at: 28))

        XCTAssertEqual(help.parameters.map(\.label), ["handler: (event: StreamEvent) => void"])
        XCTAssertEqual(parameter.signature, "event: StreamEvent")
        XCTAssertEqual(parameter.summary, "The event that arrived.")
        XCTAssertEqual(member.signature, "StreamEvent.data: string")
    }
}
