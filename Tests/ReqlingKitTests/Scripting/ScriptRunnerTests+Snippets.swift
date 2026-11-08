import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Every snippet the menu offers, run in the real helper where it's offered: each kind's own, and a folder's run in a
/// request of each kind, which must do there what that kind's own do.
extension ScriptRunnerTests {
    private static let snippetJSON = #"{"id": 1, "token": "abc"}"#

    func testEachKindsSnippetsRunCleanlyAndDoWhatTheySay() async {
        for phase in ScriptPhase.allCases {
            for kind in RequestKind.Name.allCases {
                let snippets = ScriptSnippets.menu(for: phase, kind: kind).sections.flatMap(\.snippets)
                let label = "\(phase.rawValue), \(kind.rawValue)"
                let run = await runSnippets(snippets, phase, as: kind)
                let expected = Self.expectedSnippetRun(phase, kind)

                assertRanCleanly(run, label)
                XCTAssertEqual(run.tests.map(\.name), expected.tests, label)
                XCTAssertEqual(run.writes.map { "\($0.scope) \($0.key)=\($0.value ?? "")" }, expected.writes, label)
                if phase == .preRequest {
                    let header = kind == .grpc ? "x-name" : "X-Name"
                    XCTAssertEqual(run.changes.map(\.name), [header, "X-Timestamp", "X-Signature"], label)
                    XCTAssertEqual(Set(run.changes.map(\.target)), [.header], label)
                }
            }
        }
    }

    func testAFoldersSnippetsDoInARequestOfEachKindWhatThatKindsOwnDo() async {
        for phase in ScriptPhase.allCases {
            let menu = ScriptSnippets.menu(for: phase, kind: nil)
            let snippets = menu.sections.flatMap(\.snippets) + menu.byProtocol.flatMap(\.snippets)
            for kind in RequestKind.Name.allCases {
                let label = "\(phase.rawValue), folder in \(kind.rawValue)"
                let run = await runSnippets(snippets, phase, as: kind)
                let expected = Self.expectedSnippetRun(phase, kind)

                assertRanCleanly(run, label)
                XCTAssertEqual(run.tests.map(\.name).sorted(), expected.tests.sorted(), label)
                XCTAssertEqual(run.writes.map { "\($0.scope) \($0.key)=\($0.value ?? "")" }.sorted(), expected.writes.sorted(), label)
            }
        }
    }

    /// The tests each kind's snippets run, in order, and the variables they set, against `snippetJSON`.
    private static func expectedSnippetRun(_ phase: ScriptPhase, _ kind: RequestKind.Name) -> (tests: [String], writes: [String]) {
        let set = "environment name=value"
        let saved = "environment token=abc"
        switch (phase, kind) {
        case (.preRequest, _):
            return ([], [set])
        case (.postResponse, .http):
            return (["status is 200", "has an id", "responds quickly"], [set, saved])
        case (.postResponse, .grpc):
            return (["status is OK", "has an id", "responds quickly"], [set, saved])
        case (.postResponse, .webSocket):
            return (["connection is accepted", "last message has an id", "responds quickly"], [set, saved])
        case (.stream, .http):
            return (["status is 200", "event has an id"], [set, saved])
        case (.stream, .grpc):
            return (["message has an id"], [set, saved])
        case (.stream, .webSocket):
            return (["connection is accepted", "message has an id"], [set, saved])
        }
    }

    /// One level per snippet, so a failure names the snippet's level.
    private func runSnippets(_ snippets: [ScriptSnippet], _ phase: ScriptPhase, as kind: RequestKind.Name) async -> ScriptRun {
        let json = Self.snippetJSON
        let input = ScriptFixtures.input(
            phase,
            snippets.map(\.code),
            request: ScriptFixtures.request(kind.rawValue),
            response: phase == .postResponse ? Self.snippetResponse(kind) : nil
        )
        switch phase {
        case .stream:
            let item = switch kind {
            case .http: ScriptFixtures.event(json, 1)
            case .grpc: ScriptFixtures.grpcMessage(json, 1)
            case .webSocket: ScriptFixtures.message(json, 1)
            }
            return await fixtures.stream(input, items: [item])
        case .preRequest, .postResponse:
            return await fixtures.run(input, blobs: [Data(json.utf8)])
        }
    }

    private static func snippetResponse(_ kind: RequestKind.Name) -> ScriptResponseSnapshot {
        let json = snippetJSON
        switch kind {
        case .http:
            let size = json.utf8.count
            return .http(ScriptHTTPResponse(
                code: 200, status: "OK", headers: [ScriptRow(name: "Content-Type", value: "application/json")],
                body: ScriptBlob(index: 0, size: size), size: size, truncated: false, responseTime: 12
            ))
        case .grpc:
            return .grpc(ScriptGRPCResponse(
                statusCode: 0, statusName: "ok", statusMessage: nil, metadata: [], trailers: [],
                messages: [json], sentCount: 1, receivedCount: 1, responseTime: 12
            ))
        case .webSocket:
            // A message sent after the last one received, which the snippets must pass over.
            return .webSocket(ScriptWebSocketResponse(
                code: 101, headers: [], subprotocol: nil,
                messages: [
                    ScriptSocketMessage(direction: "received", text: json, base64: nil),
                    ScriptSocketMessage(direction: "sent", text: #"{"bye": true}"#, base64: nil)
                ],
                closeCode: 1000, closeReason: "bye", end: "closed", responseTime: 12
            ))
        }
    }

    private func assertRanCleanly(_ run: ScriptRun, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(run.termination, .finished, label, file: file, line: line)
        XCTAssertEqual(run.callFailures.map { "level \($0.level): \($0.error.message)" }, [], label, file: file, line: line)
        XCTAssertEqual(run.tests.filter { $0.result != .passed }.map { "\($0.name): \($0.message ?? "")" }, [], label, file: file, line: line)
    }
}
