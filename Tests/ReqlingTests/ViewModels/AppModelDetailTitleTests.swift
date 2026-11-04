import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
final class AppModelDetailTitleTests: XCTestCase {
    private var fixture: AppFixture!

    override func setUp() async throws {
        fixture = AppFixture()
    }

    override func tearDown() async throws {
        fixture.tearDown()
        fixture = nil
    }

    private var model: AppModel {
        fixture.model
    }

    func testTheTitleNamesWhatTheDetailShows() throws {
        XCTAssertEqual(model.detailTitle, DetailTitle(text: AppFixture.appInfo.name, subject: .app, isRenamable: false))

        model.createProject(named: "API")
        let project = try XCTUnwrap(model.selection?.projectID)
        XCTAssertEqual(model.detailTitle, DetailTitle(text: "API", subject: .project(project), isRenamable: true))

        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)
        XCTAssertEqual(model.detailTitle, DetailTitle(text: "New Request", subject: .node(project, request), isRenamable: true))

        model.showSettings()
        XCTAssertEqual(model.detailTitle, DetailTitle(text: "Settings", subject: .settings, isRenamable: false))
    }

    /// The editor stays up, keeping its draft, while its project is unavailable; the title keeps naming its request but
    /// offers no rename, which could only fail. A folder there falls back to its project, as the detail does.
    func testAnUnavailableProjectKeepsItsEditorsTitleButCannotBeRenamed() throws {
        model.createProject(named: "API")
        let project = try XCTUnwrap(model.selection?.projectID)
        model.newFolder()
        let folder = try XCTUnwrap(model.selection?.nodeID)
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)
        let projectFile = try XCTUnwrap(fixture.library.project(project)?.url.appendingPathComponent("project.json"))
        try FileManager.default.moveItem(at: projectFile, to: fixture.profile.applicationSupportDirectory.appendingPathComponent("aside.json"))
        fixture.library.reload(project)
        model.libraryDidChange()

        XCTAssertEqual(model.detailTitle, DetailTitle(text: "New Request", subject: .node(project, request), isRenamable: false))

        model.selection = .node(project, folder)
        XCTAssertEqual(model.detailTitle, DetailTitle(text: "API", subject: .project(project), isRenamable: false))
    }

    /// An inline edit commits as the selection moves away, so a rename must land on the subject it began on.
    func testRenamingTargetsTheGivenSubjectRatherThanTheCurrentSelection() throws {
        model.createProject(named: "API")
        let project = try XCTUnwrap(model.selection?.projectID)
        model.newRequest()
        let first = try XCTUnwrap(model.selection?.nodeID)
        model.newRequest()

        model.rename(.node(project, first), to: "  Users  ")
        model.rename(.project(project), to: "Billing")
        model.rename(.node(project, first), to: "   ")

        let document = try XCTUnwrap(fixture.library.document(project))
        XCTAssertEqual(document.node(first)?.name, "Users", "trimmed, and a blank name keeps the old one")
        XCTAssertEqual(document.name, "Billing")
        XCTAssertEqual(model.detailTitle.text, "New Request")
    }
}
