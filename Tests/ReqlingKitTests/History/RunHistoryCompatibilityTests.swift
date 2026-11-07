import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Runs recorded before scripts existed, or before they could change cookies, still decode.
final class RunHistoryCompatibilityTests: XCTestCase {
    func testAnExchangeAndSummaryWithoutScriptFieldsDecode() throws {
        let exchange = RequestExchange(
            projectID: ProjectID(),
            requestID: RequestNodeID(),
            startedAt: Date(timeIntervalSince1970: 0),
            environmentName: "Default",
            request: nil,
            outcome: .failure(RunFailure(kind: .transport, message: "down"))
        )
        let exchangeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(exchange)) as? [String: Any]
        let summaryJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RunSummary(exchange))) as? [String: Any]

        XCTAssertNil(exchangeJSON?["scriptReport"], "Nothing new is written for a run without scripts")
        XCTAssertNil(summaryJSON?["tests"])
        let decoded = try JSONDecoder().decode(RequestExchange.self, from: JSONSerialization.data(withJSONObject: exchangeJSON ?? [:]))
        XCTAssertNil(decoded.scriptReport)
        XCTAssertEqual(try JSONDecoder().decode(RunSummary.self, from: JSONSerialization.data(withJSONObject: summaryJSON ?? [:])).tests, nil)
    }

    func testAScriptReportFromBeforeCookieChangesDecodes() throws {
        let report = ScriptPhaseReport(
            phase: .postResponse,
            variableChanges: [ScriptVariableChange(scope: .environment, key: "token", isUnset: false, isSecret: true)],
            cookieChanges: [ScriptCookieChange(name: "session", domain: "example.com", path: "/", isRemoved: true)]
        )
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertNotNil(json["cookieChanges"])
        json["cookieChanges"] = nil

        let old = try JSONDecoder().decode(ScriptPhaseReport.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.cookieChanges, [])
        XCTAssertEqual(old.variableChanges, report.variableChanges)
        XCTAssertEqual(try JSONDecoder().decode(ScriptPhaseReport.self, from: JSONEncoder().encode(report)), report)
    }

    func testTheHistoryKeepsOnlyTheNewestConsoleOfARun() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = RunHistoryStore(directory: directory.url)
        let line = String(repeating: "x", count: 100 * 1_024)
        var exchange = RequestExchange(
            projectID: ProjectID(),
            requestID: RequestNodeID(),
            startedAt: Date(),
            environmentName: nil,
            request: nil,
            outcome: .failure(RunFailure(kind: .transport, message: "down"))
        )
        exchange.scriptReport = ScriptReport(phases: [ScriptPhaseReport(
            phase: .preRequest,
            console: (0..<10).map { ScriptConsoleEntry(level: 0, severity: .log, text: "\($0)" + line) }
        )])

        _ = store.insert(exchange)
        let stored = try XCTUnwrap(store.latest(for: exchange.requestID, in: exchange.projectID)?.scriptReport?.phases.first)

        XCTAssertTrue(stored.isConsoleTruncated)
        XCTAssertEqual(stored.console.count, 5)
        XCTAssertEqual(stored.console.last?.text.first, "9")
    }
}
