import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

extension SnapshotTests {
    private static let inspectorSize = CGSize(width: 280, height: 420)

    /// Runs over two days, newest first: HTTP statuses by class, a failure that never got a response, and another
    /// environment. The history is built without an editor, which would load the latest exchange and so highlight the run
    /// the pane follows; an offscreen capture draws that selection as a solid bar.
    func testRunHistoryInspector() throws {
        let project = try SnapshotProject.make(in: fixture)
        let day: TimeInterval = 24 * 60 * 60
        let base: TimeInterval = 1_700_000_000
        storeResponse(503, at: base - day - 600, duration: 2.4, bytes: 120, in: project)
        project.storeRun(.failure(RunFailure(kind: .timedOut, message: "Timed out")), for: project.listUsers, at: base - day, in: fixture)
        storeResponse(404, at: base - 300, duration: 0.088, bytes: 64, environment: "Staging", in: project)
        storeResponse(200, at: base, duration: 0.142, bytes: 18_432, in: project)
        let history = RunHistoryViewModel(projectID: project.id, requestID: project.listUsers, app: fixture.model)

        assertBothAppearances(RunHistoryInspector(history: history), size: Self.inspectorSize)
    }

    func testRunHistoryInspectorEmpty() throws {
        let project = try SnapshotProject.make(in: fixture)
        let editor = try project.editor(project.listUsers, in: fixture)

        assertBothAppearances(RunHistoryInspector(history: editor.history), size: Self.inspectorSize)
    }

    /// A past run shows under a bar naming it, with re-run, restore, and the way back to the latest.
    func testResponsePinnedToAPastRun() async throws {
        let project = try SnapshotProject.make(in: fixture)
        let base: TimeInterval = 1_700_000_000
        let older = storeResponse(500, at: base - 300, duration: 0.31, bytes: 40, in: project)
        storeResponse(200, at: base, duration: 0.142, bytes: 18_432, in: project)
        let editor = try project.editor(project.listUsers, in: fixture)
        editor.history.selection = [older.id]
        await editor.history.loadPinned()

        assertBothAppearances(ResponseView(response: editor.response, model: fixture.model), size: CGSize(width: 820, height: 340))
    }

    /// Two runs' JSON bodies as a unified diff: a gutter of old and new line numbers, and changed lines washed.
    func testRunComparison() async throws {
        let project = try SnapshotProject.make(in: fixture)
        let base: TimeInterval = 1_700_000_000
        let older = storeJSON(#"{"users":[{"id":1,"name":"Ada","active":true},{"id":2,"name":"Grace","active":false}],"next":null}"#,
                              status: 200, at: base - 300, duration: 0.31, in: project)
        storeJSON(#"{"users":[{"id":1,"name":"Ada","active":true},{"id":2,"name":"Grace","active":true}],"next":"page2"}"#,
                  status: 200, at: base, duration: 0.142, environment: "Staging", in: project)
        let editor = try project.editor(project.listUsers, in: fixture)
        editor.history.compareWithLatest(older.id)
        await editor.history.loadComparison()

        assertBothAppearances(ResponseView(response: editor.response, model: fixture.model), size: CGSize(width: 820, height: 420))
    }

    func testSettingsHistory() {
        fixture.model.showSettings(.history)

        assertBothAppearances(SettingsScreen(model: fixture.model), size: CGSize(width: 1000, height: 460))
    }

    @discardableResult
    private func storeJSON(
        _ body: String,
        status: Int,
        at seconds: TimeInterval,
        duration: TimeInterval,
        environment: String = "Default",
        in project: SnapshotProject
    ) -> RequestExchange {
        let response = HTTPResponseRecord(
            statusCode: status,
            headers: [KeyValuePair(key: "Content-Type", value: "application/json")],
            body: Data(body.utf8),
            url: "https://api.example.com/users",
            startedAt: Date(timeIntervalSince1970: seconds),
            duration: duration
        )
        return project.storeRun(.response(response), for: project.listUsers, at: seconds, environment: environment, in: fixture)
    }

    /// A run of "List users" with a JSON body of about `bytes`, so rows show realistic sizes and a shown run parses.
    @discardableResult
    private func storeResponse(
        _ status: Int,
        at seconds: TimeInterval,
        duration: TimeInterval,
        bytes: Int,
        environment: String = "Default",
        in project: SnapshotProject
    ) -> RequestExchange {
        let padding = String(repeating: "x", count: max(0, bytes - 30))
        let response = HTTPResponseRecord(
            statusCode: status,
            headers: [KeyValuePair(key: "Content-Type", value: "application/json")],
            body: Data(#"{"status":\#(status),"detail":"\#(padding)"}"#.utf8),
            url: "https://api.example.com/users",
            startedAt: Date(timeIntervalSince1970: seconds),
            duration: duration
        )
        return project.storeRun(.response(response), for: project.listUsers, at: seconds, environment: environment, in: fixture)
    }
}
