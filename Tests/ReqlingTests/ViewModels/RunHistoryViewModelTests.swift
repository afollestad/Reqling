import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
final class RunHistoryViewModelTests: XCTestCase {
    private var fixture: AppFixture!
    private var project: ProjectID!
    private var request: RequestNodeID!
    private var staging: EnvironmentID!

    /// A request whose sends fail before reaching the network: `{{host}}` is defined nowhere. Runs are seeded long
    /// ago, so retention keeps them all.
    override func setUp() async throws {
        fixture = AppFixture()
        fixture.model.settings.update { $0.historyRetention = .forever }
        project = try fixture.library.createProject(named: "History")
        let item = RequestItem(name: "Unsendable", kind: .http(HTTPRequestSpec(url: "https://{{host}}/now")))
        let environment = RequestEnvironment(name: "Staging")
        staging = environment.id
        try fixture.library.mutate(project) { document in
            document.environments.append(environment)
            try document.insert(.request(item), into: nil)
        }
        request = item.id
    }

    override func tearDown() async throws {
        fixture.tearDown()
        fixture = nil
    }

    func testSelectingAnOlderRunShowsItUntilShowLatest() async throws {
        let older = seed(status: 500, at: 1, url: "https://example.com/old")
        let newer = seed(status: 200, at: 2, url: "https://example.com/new")
        let editor = open()
        let history = editor.history
        XCTAssertEqual(history.runs.map(\.id), [newer.id, older.id])
        XCTAssertEqual(editor.response.exchange?.id, newer.id)

        history.selection = [newer.id]
        XCTAssertNil(history.pinnedRunID, "the latest shows anyway")

        history.selection = [older.id]
        XCTAssertEqual(history.pinnedStatus, .loading)
        XCTAssertNil(editor.response.exchange)
        await history.loadPinned()
        XCTAssertNil(history.pinnedStatus)
        XCTAssertEqual(editor.response.exchange?.id, older.id)
        XCTAssertEqual(history.pinnedRun?.id, older.id)

        history.showLatest()
        XCTAssertEqual(editor.response.exchange?.id, newer.id)
    }

    func testARunClearedWhileSelectedReadsAsMissing() async {
        let older = seed(status: 500, at: 1, url: "https://example.com/old")
        seed(status: 200, at: 2, url: "https://example.com/new")
        let history = open().history

        history.selection = [older.id]
        fixture.model.runner.clearHistory(for: request, in: project)
        await history.loadPinned()

        XCTAssertEqual(history.pinnedStatus, .missing)
        history.retainSelection(in: history.runs.map(\.id))
        XCTAssertEqual(history.selection, [])
    }

    func testSendingShowsTheNewRun() async {
        let older = seed(status: 500, at: 1, url: "https://example.com/old")
        seed(status: 200, at: 2, url: "https://example.com/new")
        let editor = open()
        editor.history.selection = [older.id]

        editor.send()

        XCTAssertEqual(editor.history.selection, [])
        await waitUntilObserved("recorded") { editor.history.runs.count == 3 }
        XCTAssertEqual(editor.response.exchange?.id, editor.history.runs.first?.id)
    }

    /// A re-run sends the run's own template against the environment it used, whatever the editor and window hold now.
    func testARerunSendsTheRunsTemplateAgainstItsEnvironment() async throws {
        let past = seed(status: 200, at: 1, url: "https://{{host}}/past", environment: staging)
        let editor = open()
        let run = try XCTUnwrap(editor.history.runs.first)

        await editor.history.performRerun(run)

        let rerun = try XCTUnwrap(fixture.model.runner.latest[RunKey(request, in: project)])
        XCTAssertNotEqual(rerun.id, past.id)
        XCTAssertEqual(rerun.spec, past.spec)
        XCTAssertEqual(rerun.environmentID, staging)
        XCTAssertEqual(editor.history.runs.map(\.id), [rerun.id, past.id])
        XCTAssertEqual(editor.spec.url, "https://{{host}}/now", "the editor keeps what it holds")
    }

    func testRestoreAsksThenReplacesTheRequest() async throws {
        seed(status: 200, at: 1, url: "https://example.com/past")
        let editor = open()
        let run = try XCTUnwrap(editor.history.runs.first)

        await editor.history.prepareRestore(run)
        let pending = try XCTUnwrap(editor.history.restorePending)
        XCTAssertEqual(editor.spec.url, "https://{{host}}/now", "nothing changes before the person confirms")
        editor.history.confirmRestore(pending)

        XCTAssertEqual(editor.spec.url, "https://example.com/past")
        XCTAssertNotNil(editor.notice)
        editor.flush()
        XCTAssertEqual(fixture.library.document(project)?.request(request)?.kind.httpSpec?.url, "https://example.com/past")

        await editor.history.prepareRestore(run)
        XCTAssertNil(editor.history.restorePending, "the editor already holds it")
    }

    func testClearingAsksFirstThenEmptiesTheHistory() throws {
        seed(status: 200, at: 1, url: "https://example.com/past")
        let editor = open()

        editor.history.requestClear()
        let scope = try XCTUnwrap(fixture.model.historyClearPending)
        XCTAssertEqual(scope, .request(project, request, name: "Unsendable"))
        fixture.model.clearHistory(scope)

        XCTAssertNil(fixture.model.historyClearPending)
        XCTAssertEqual(editor.history.runs, [])
        XCTAssertNil(editor.response.exchange)
    }

    /// Days follow the window's time zone: 23:30 and 00:30 UTC fall on different days there.
    func testRunsGroupByDayAsTodayYesterdayThenTheDate() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let formats = RunDateFormats(locale: Locale(identifier: "en_US_POSIX"), calendar: Calendar(identifier: .gregorian), timeZone: utc)
        let midnight = formats.calendar.startOfDay(for: now)
        let runs = [
            midnight.addingTimeInterval(1_800),
            midnight.addingTimeInterval(-1_800),
            midnight.addingTimeInterval(-3 * 24 * 60 * 60)
        ].map { startedAt in
            RunSummary(RequestExchange(
                projectID: project, requestID: request, startedAt: startedAt, environmentName: nil, request: nil,
                outcome: .failure(RunFailure(kind: .cancelled, message: "Cancelled"))
            ))
        }

        let days = RunHistoryDay.group(runs, formats: formats, now: now)

        XCTAssertEqual(days.map(\.title), ["Today", "Yesterday", "Nov 11, 2023"])
        XCTAssertEqual(days.map(\.runs.count), [1, 1, 1])
    }

    func testTheInspectorsVisibilityIsRememberedOnThisMac() {
        XCTAssertFalse(fixture.model.showsRunHistory)

        fixture.model.toggleRunHistory()

        XCTAssertTrue(fixture.model.showsRunHistory)
        XCTAssertTrue(WorkspaceStateStore(fileURL: fixture.profile.workspaceStateURL).state.showsRunHistory)
    }

    private func open() -> RequestEditorViewModel {
        fixture.model.selection = .node(project, request)
        return fixture.model.editor!.asHTTP!
    }

    /// Stores a run before anything reads the history, as one recorded in an earlier session.
    @discardableResult
    private func seed(status: Int, at seconds: TimeInterval, url: String, environment: EnvironmentID? = nil) -> RequestExchange {
        let startedAt = Date(timeIntervalSince1970: seconds)
        let body = Data("\(status)".utf8)
        let response = HTTPResponseRecord(statusCode: status, headers: [], body: body, url: url, startedAt: startedAt, duration: 0.1)
        let exchange = RequestExchange(
            projectID: project,
            requestID: request,
            startedAt: startedAt,
            environmentID: environment,
            environmentName: environment == nil ? nil : "Staging",
            spec: .http(HTTPRequestSpec(url: url)),
            request: nil,
            outcome: .response(response)
        )
        RunHistoryStore(directory: fixture.profile.historyDirectory).save(exchange)
        return exchange
    }
}
