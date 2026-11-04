import Foundation
import MCP
import ReqlingKit
import XCTest

@testable import Reqling

/// MCP tools against the real window model: an agent's edits land on top of the user's pending ones, and the window
/// shows what the agent asked to reveal.
@MainActor
final class AppModelMCPTests: XCTestCase {
    private var fixture: AppFixture!
    private var gate: SleepGate!
    private var project: ProjectID!

    override func setUp() async throws {
        let gate = SleepGate()
        self.gate = gate
        fixture = AppFixture(sleep: { _ in await gate.sleep() })
        fixture.model.createProject(named: "Agent")
        project = fixture.model.selection?.projectID
        fixture.model.newRequest()
    }

    override func tearDown() async throws {
        gate.releaseAll()
        fixture.tearDown()
        fixture = nil
    }

    private var dispatcher: MCPToolDispatcher {
        fixture.component.mcpServer.dispatcher
    }

    private var editor: RequestEditorViewModel {
        fixture.model.editor!.asHTTP!
    }

    private var saved: HTTPRequestSpec? {
        fixture.library.document(project)?.request(editor.requestID)?.kind.httpSpec
    }

    /// The user edits one header and, during the autosave pause, an agent edits another and removes a third. The
    /// user's edit saves first, so the agent's patch builds on it, and the editor shows the result.
    func testAnAgentsEditDuringTheAutosavePauseBuildsOnTheUsersEdit() async throws {
        let first = KeyValuePair(key: "X-User", value: "1")
        let second = KeyValuePair(key: "X-Agent", value: "1")
        let removed = KeyValuePair(key: "X-Gone", value: "1")
        let request = editor.requestID
        try fixture.library.mutate(project) { try $0.updateRequest(request) { $0.kind = .http(HTTPRequestSpec(headers: [first, second, removed])) } }
        fixture.model.libraryDidChange()
        editor.spec.headers[0].value = "typed"

        let result = await dispatcher.call("update_request", arguments: [
            "project": .string(project.description),
            "request": .string(request.description),
            "spec": ["headers": [["id": .string(first.id.description)], ["id": .string(second.id.description), "value": "agent"]]]
        ])
        fixture.model.libraryDidChange()

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(saved?.headers.map(\.value), ["typed", "agent"])
        XCTAssertEqual(saved?.headers.map(\.id), [first.id, second.id], "Rows named by ID keep it")
        XCTAssertEqual(editor.spec.headers.map(\.value), ["typed", "agent"])
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    func testRevealSelectsTheItemAndBringsTheWindowForward() async throws {
        let request = editor.requestID
        fixture.model.showSettings(.mcp)
        fixture.model.selection = .project(project)

        let result = await dispatcher.call("reveal_item", arguments: ["project": .string(project.description), "item": .string(request.description)])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertEqual(fixture.model.selection, .node(project, request))
        XCTAssertFalse(fixture.model.isShowingSettings)
        XCTAssertEqual(fixture.system.broughtToFront, 1)
    }

    func testThePortFieldTakesOnlyValidPortsAndTheSetupCommandsCarryTheToken() throws {
        let settings = fixture.model.mcpSettings
        settings.portDraft = "80"
        settings.commitPort()
        XCTAssertEqual(settings.portDraft, "39717", "A privileged port puts the saved one back")

        settings.portDraft = " 40100 "
        settings.commitPort()
        XCTAssertEqual(fixture.component.settingsStore.settings.mcpPort, 40_100)

        settings.loadToken()
        let token = try XCTUnwrap(fixture.component.mcpServer.token)
        XCTAssertFalse(settings.claudeCommand(revealing: false).contains(token))
        settings.copyClaudeCommand()
        XCTAssertEqual(
            fixture.system.pasteboard,
            "claude mcp add --transport http reqling http://127.0.0.1:40100/mcp --header \"Authorization: Bearer \(token)\""
        )
        settings.copyCodexConfiguration()
        XCTAssertEqual(fixture.system.pasteboard?.contains("bearer_token_env_var = \"REQLING_MCP_TOKEN\""), true)
        XCTAssertEqual(fixture.system.pasteboard?.contains("export REQLING_MCP_TOKEN=\"\(token)\""), true)
    }
}
