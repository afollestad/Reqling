import ReqlingKit
import XCTest

@testable import Reqling

/// Settings replaces the sidebar selection while it is up and returns to it on close.
@MainActor
extension AppModelTests {
    /// Settings stands in for the selection: it clears the sidebar's but keeps acting on its project, and closing it, or
    /// relaunching from inside it, returns to the item.
    func testSettingsClearsTheSelectionAndClosingRestoresIt() throws {
        model.createProject(named: "Other")
        _ = try makeProject()
        let project = try XCTUnwrap(fixture.library.projects.last?.id)
        XCTAssertNotEqual(fixture.library.projects.first?.id, project, "The fallback to the first project must not mask the check")
        model.selection = .project(project)
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)

        model.showSettings()
        model.showSettings(.mcp)

        XCTAssertTrue(model.isShowingSettings)
        XCTAssertEqual(model.settingsPage, .mcp)
        XCTAssertNil(model.selection)
        XCTAssertNil(model.editor)
        XCTAssertEqual(model.activeProjectID, project)
        XCTAssertEqual(relaunch().selection, .node(project, request))

        model.closeSettings()

        XCTAssertFalse(model.isShowingSettings)
        XCTAssertEqual(model.selection, .node(project, request))
        XCTAssertEqual(model.editor?.requestID, request)
    }

    /// The item can go while Settings is up, so closing falls back to its project, or to nothing once that is gone too.
    /// Closing rechecks on its own, and a library change reconciles what the toolbar and commands act on meanwhile.
    func testClosingSettingsFallsBackWhenItsSelectionIsGone() throws {
        let project = try makeProject()
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)

        model.showSettings()
        try fixture.library.mutate(project) { try $0.removeNode(request) }
        model.closeSettings()

        XCTAssertEqual(model.selection, .project(project))

        model.showSettings()
        model.removeProject(project)
        model.libraryDidChange()

        XCTAssertNil(model.activeProjectID, "A removed project is no longer acted on")

        model.closeSettings()

        XCTAssertNil(model.selection)
        XCTAssertFalse(model.isShowingSettings)
    }

    /// Closing when Settings is not up leaves the selection alone, as it did before Settings cleared it.
    func testClosingSettingsWhenItIsNotUpKeepsTheSelection() throws {
        let project = try makeProject()

        model.closeSettings()

        XCTAssertEqual(model.selection, .project(project))
    }

    /// With the selection cleared, clicking the item Settings replaced leaves Settings; and leaving by choosing an item
    /// drops what Settings would have returned to, so a later empty selection cannot resurrect it.
    func testChoosingAnItemInSettingsClosesItAndForgetsWhatItWouldRestore() throws {
        let project = try makeProject()
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)

        model.showSettings()
        model.selection = .node(project, request)

        XCTAssertFalse(model.isShowingSettings)
        XCTAssertEqual(model.editor?.requestID, request)

        model.createProject(named: "Other")
        let other = try XCTUnwrap(model.selection?.projectID)
        model.selection = .node(project, request)
        model.showSettings()
        model.selection = .project(other)
        model.removeProject(other)

        XCTAssertNil(model.selection)
        XCTAssertNil(relaunch().selection)
    }
}
