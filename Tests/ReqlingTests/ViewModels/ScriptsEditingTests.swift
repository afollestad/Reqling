import Foundation
import ReqlingKit
import ReqlingScriptProtocol
import XCTest

@testable import Reqling

/// Editing scripts: a request's in its editor's draft, a folder's or the project's in the detail pane, and the levels
/// that run before them.
@MainActor
final class ScriptsEditingTests: XCTestCase {
    var fixture: AppFixture!
    var gate: SleepGate!
    var project: ProjectID!
    let folder = RequestFolder(name: "Users")
    let request = RequestItem(name: "Me", kind: .http(HTTPRequestSpec(url: "https://api.test/me")))

    override func setUp() async throws {
        let gate = SleepGate()
        self.gate = gate
        fixture = AppFixture(sleep: { _ in await gate.sleep() })
        fixture.model.createProject(named: "Scripts")
        project = fixture.model.selection?.projectID
        try fixture.library.mutate(project) { [folder, request] document in
            try document.insert(.folder(folder), into: nil)
            try document.insert(.request(request), into: folder.id)
        }
        fixture.model.libraryDidChange()
    }

    override func tearDown() async throws {
        gate.releaseAll()
        fixture.tearDown()
        fixture = nil
    }

    var stored: RequestItem? {
        fixture.library.document(project)?.request(request.id)
    }

    func openRequest() throws -> ScriptsEditorModel {
        fixture.model.selection = .node(project, request.id)
        return try XCTUnwrap(fixture.model.editor?.asHTTP?.scriptsEditor)
    }

    func changeExternally(_ change: (inout ProjectDocument) throws -> Void) throws {
        try fixture.library.mutate(project, change)
        fixture.model.libraryDidChange()
    }

    func releaseAutosave() async {
        await waitUntil("the autosave to start waiting") { gate.pendingCount > 0 }
        gate.releaseAll()
    }

    func testARequestsScriptsAutosaveAndMergeWithTheOtherPhaseChangedElsewhere() async throws {
        let scripts = try openRequest()

        scripts.source = "rq.variables.set('a', 1)"
        scripts.setRunsInheritedScripts(false)
        try changeExternally { [request] in try $0.updateRequest(request.id) { $0.scripts.postResponse = "rq.test('elsewhere', () => {})" } }
        XCTAssertEqual(scripts.scripts.postResponse, "", "A dirty draft waits for its save to merge")
        await releaseAutosave()
        await waitUntil("the merged save") { self.stored?.scripts.preRequest == "rq.variables.set('a', 1)" }

        XCTAssertEqual(stored?.scripts.postResponse, "rq.test('elsewhere', () => {})")
        XCTAssertEqual(stored?.runsInheritedScripts, false)
        XCTAssertEqual(scripts.scripts, stored?.scripts)
        XCTAssertFalse(try XCTUnwrap(fixture.model.editor).hasUnsavedChanges)
    }

    func testAScriptChangedElsewhereShowsWhileTheDraftIsClean() throws {
        let scripts = try openRequest()

        try changeExternally { [request] in try $0.updateRequest(request.id) { $0.scripts.preRequest = "console.log('pulled')" } }

        XCTAssertEqual(scripts.source, "console.log('pulled')")
        XCTAssertFalse(try XCTUnwrap(fixture.model.editor).hasUnsavedChanges, "Showing a stored version is no edit")
    }

    func testAFoldersScriptsSaveWhenTheSelectionMovesOnAndTheProjectsGetTheirOwnEditor() throws {
        fixture.model.selection = .node(project, folder.id)
        let folderScripts = try XCTUnwrap(fixture.model.containerScripts)
        XCTAssertEqual(folderScripts.folderID, folder.id)

        folderScripts.scripts.phase = .postResponse
        folderScripts.scripts.source = "rq.test('folder', () => {})"
        folderScripts.scripts.setRunsInheritedScripts(false)
        fixture.model.selection = .project(project)

        let saved = try XCTUnwrap(fixture.library.document(project)?.folder(folder.id))
        XCTAssertEqual(saved.scripts, ScriptSet(postResponse: "rq.test('folder', () => {})"))
        XCTAssertFalse(saved.runsInheritedScripts)
        XCTAssertNil(fixture.model.containerScripts?.folderID)
        XCTAssertFalse(fixture.model.containerScripts?.scripts.canInherit ?? true, "The project inherits nothing")
    }

    func testAProjectsScriptsShowAChangeMadeElsewhereWhileClean() throws {
        fixture.model.selection = .project(project)

        try changeExternally { $0.scripts.preRequest = "console.log('agent')" }

        XCTAssertEqual(fixture.model.containerScripts?.scripts.source, "console.log('agent')")
    }

    func testRunsAfterListsTheLevelsAboveWithScriptsInThePhaseAndOpensThem() throws {
        try changeExternally { [folder] document in
            document.scripts = ScriptSet(preRequest: "// project", postResponse: "// project")
            try document.updateFolder(folder.id) { $0.scripts.preRequest = "// folder" }
        }
        let scripts = try openRequest()

        XCTAssertEqual(scripts.alsoRuns.map(\.title), ["Project", "Users"])
        scripts.phase = .postResponse
        XCTAssertEqual(scripts.alsoRuns.map(\.title), ["Project"], "Only levels with a script in the shown phase")
        try changeExternally { [folder] in try $0.updateFolder(folder.id) { $0.runsInheritedScripts = false } }
        XCTAssertEqual(scripts.alsoRuns.map(\.title), [], "The folder cuts the project off")
        scripts.setRunsInheritedScripts(false)
        scripts.phase = .preRequest
        XCTAssertEqual(scripts.alsoRuns.map(\.title), [], "The request's own toggle cuts everything off")

        scripts.setRunsInheritedScripts(true)
        let link = try XCTUnwrap(scripts.alsoRuns.first)
        fixture.model.openScripts(link, phase: .preRequest, in: project)

        XCTAssertEqual(fixture.model.selection, .node(project, folder.id))
        XCTAssertEqual(fixture.model.containerScripts?.scripts.phase, .preRequest)
        XCTAssertEqual(stored?.runsInheritedScripts, true, "Leaving the request saved its toggle")
    }
}
