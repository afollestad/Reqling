import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// What the snippet menu offers for each phase and kind, and that each snippet parses and draws no warning there.
/// `ScriptRunnerTests+Snippets` runs them.
final class ScriptSnippetsTests: XCTestCase {
    func testEverySnippetParsesAndDrawsNoWarningWhereItIsOffered() {
        for phase in ScriptPhase.allCases {
            for kind in RequestKind.Name.allCases.map(Optional.some) + [nil] {
                let menu = ScriptSnippets.menu(for: phase, kind: kind)
                let label = "\(phase.rawValue), \(kind?.rawValue ?? "folder")"
                for snippet in menu.sections.flatMap(\.snippets) {
                    assertClean(snippet, phase: phase, protocols: kind.map(ScriptAnalysisContext.protocols(for:)), label)
                }
                for section in menu.byProtocol {
                    // A folder's script gets no protocol checks, so each is also checked as its guard's protocol.
                    for snippet in section.snippets {
                        assertClean(snippet, phase: phase, protocols: nil, label)
                        assertClean(snippet, phase: phase, protocols: ScriptAnalysisContext.protocols(for: section.kind), label)
                    }
                }
            }
        }
    }

    func testARequestsMenuOffersOnlyWhatFitsItsPhaseAndKind() {
        XCTAssertEqual(outline(.preRequest, .http), [
            "Variables: Set a variable, Read a variable",
            "Request: Add a header, Sign with an HMAC"
        ])
        XCTAssertEqual(outline(.preRequest, .grpc), [
            "Variables: Set a variable, Read a variable",
            "Request: Add metadata, Sign with an HMAC"
        ])
        XCTAssertEqual(outline(.postResponse, .http), [
            "Variables: Set a variable, Read a variable, Save a value from the JSON response",
            "Tests: Test the status code, Test a JSON field, Test the response time"
        ])
        XCTAssertEqual(outline(.postResponse, .webSocket), [
            "Variables: Set a variable, Read a variable, Save a value from the last message's JSON",
            "Tests: Test the status code, Test the last message's JSON field, Test the response time"
        ])
        XCTAssertEqual(outline(.stream, .http), [
            "Variables: Set a variable, Read a variable, Save a value from each event's JSON",
            "Tests: Test the status code, Test each event's JSON field"
        ])
        // A call's status arrives only with its end.
        XCTAssertEqual(outline(.stream, .grpc), [
            "Variables: Set a variable, Read a variable, Save a value from each message's JSON",
            "Tests: Test each message's JSON field"
        ])
        XCTAssertTrue(RequestKind.Name.allCases.allSatisfy { ScriptSnippets.menu(for: .postResponse, kind: $0).byProtocol.isEmpty })
    }

    func testAFoldersMenuListsWhatDiffersByProtocolUnderEachProtocol() {
        XCTAssertEqual(outline(.preRequest, nil), [
            "Variables: Set a variable, Read a variable",
            "Request: Add a header, Sign with an HMAC"
        ])
        XCTAssertEqual(outline(.postResponse, nil), [
            "Variables: Set a variable, Read a variable",
            "Tests: Test the response time",
            "HTTP ▸ Save a value from the JSON response, Test the status code, Test a JSON field",
            "gRPC ▸ Save a value from the JSON response, Test the status code, Test a JSON field",
            "WebSocket ▸ Save a value from the last message's JSON, Test the status code, Test the last message's JSON field"
        ])
        XCTAssertEqual(outline(.stream, nil), [
            "Variables: Set a variable, Read a variable",
            "HTTP ▸ Save a value from each event's JSON, Test the status code, Test each event's JSON field",
            "gRPC ▸ Save a value from each message's JSON, Test each message's JSON field",
            "WebSocket ▸ Save a value from each message's JSON, Test the status code, Test each message's JSON field"
        ])
    }

    func testAProtocolsSnippetInAFoldersScriptRunsOnlyForThatProtocol() throws {
        let grpc = try XCTUnwrap(ScriptSnippets.menu(for: .postResponse, kind: nil).byProtocol.first { $0.kind == .grpc })
        let status = try XCTUnwrap(grpc.snippets.first { $0.id == "testStatus" })

        XCTAssertEqual(status.code, """
            if (rq.info.protocol === "grpc") {
              rq.test("status is OK", () => rq.expect(rq.response.code).to.equal(0))
            }
            """)
        XCTAssertEqual(placeholderText(status), "0")
    }

    func testThePlaceholderIsSelectedTextWithoutItsMarkers() throws {
        let menu = ScriptSnippets.menu(for: .preRequest, kind: .http)
        let set = try XCTUnwrap(menu.sections.first?.snippets.first)
        let hmac = try XCTUnwrap(menu.sections.last?.snippets.last)

        XCTAssertEqual(set.code, #"rq.environment.set("name", "value")"#)
        XCTAssertEqual(placeholderText(set), "name")
        XCTAssertEqual(placeholderText(hmac), "apiSecret")
    }

    private func outline(_ phase: ScriptPhase, _ kind: RequestKind.Name?) -> [String] {
        let menu = ScriptSnippets.menu(for: phase, kind: kind)
        let sections = menu.sections.map { "\($0.group.title): " + $0.snippets.map(\.title).joined(separator: ", ") }
        return sections + menu.byProtocol.map { "\($0.kind.title) ▸ " + $0.snippets.map(\.title).joined(separator: ", ") }
    }

    private func placeholderText(_ snippet: ScriptSnippet) -> String? {
        snippet.placeholder.map { (snippet.code as NSString).substring(with: $0) }
    }

    private func assertClean(
        _ snippet: ScriptSnippet,
        phase: ScriptPhase,
        protocols: ScriptProtocols?,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let label = "\(label): \(snippet.title)"
        XCTAssertNil(ScriptSyntaxChecker.shared.error(in: snippet.code)?.message, label, file: file, line: line)
        let context = ScriptAnalysisContext(phase: phase, protocols: protocols)
        XCTAssertEqual(ScriptAnalyzer(text: snippet.code, context: context).diagnostics().map(\.message), [], label, file: file, line: line)
        XCTAssertFalse(snippet.code.contains(ScriptSnippet.placeholderOpen), label, file: file, line: line)
        if let placeholder = snippet.placeholder {
            let text = (snippet.code as NSString).substring(with: placeholder)
            XCTAssertFalse(text.isEmpty || text.contains("\n"), label, file: file, line: line)
        }
    }
}
