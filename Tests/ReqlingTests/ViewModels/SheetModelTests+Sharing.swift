import AppKit
import Foundation
@testable import ReqlingKit
import XCTest

@testable import Reqling

extension SheetModelTests {
    private func shareProjectToView(ownerName: String? = nil) throws {
        try fixture.library.mutate(project) { document in
            document.defaultEnvironment.variables = [
                Variable(key: "baseUrl", value: "https://api"),
                Variable(key: "token", value: "", isSecret: true)
            ]
        }
        fixture.library.setSharing(ProjectSharing(owner: "owner", permission: .readOnly, canInvite: false, ownerName: ownerName), for: project)
    }

    /// In a project shared to view, Done saves only this person's own secret values; its environments stay as stored,
    /// and Global stays theirs to edit.
    func testTheEnvironmentsOfAProjectSharedToViewTakeOnlyYourSecretValues() throws {
        try shareProjectToView()
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)

        XCTAssertTrue(editor.isSelectedLocked)
        XCTAssertFalse(editor.canRemoveSelected)
        editor.addEnvironment()
        XCTAssertTrue(editor.environments.isEmpty)
        editor.selected.variables[0].value = "https://changed"
        editor.selected.variables[1].value = "mine"

        XCTAssertTrue(editor.save())
        XCTAssertNil(fixture.model.alert)
        let stored = try XCTUnwrap(fixture.library.document(project)).defaultEnvironment.variables
        XCTAssertEqual(stored.map(\.value), ["https://api", "mine"])
        editor.selectedID = editor.globalEnvironment.id
        XCTAssertFalse(editor.isSelectedLocked)
    }

    func testTheSidebarSaysHowAProjectIsShared() throws {
        let unshared = try XCTUnwrap(fixture.library.project(project))
        XCTAssertNil(fixture.model.iCloud.sharingDescription(of: unshared))

        try shareProjectToView(ownerName: "Ann Appleseed")

        let shared = try XCTUnwrap(fixture.library.project(project))
        XCTAssertEqual(fixture.model.iCloud.sharingDescription(of: shared), "Shared with you by Ann Appleseed to view")
    }

    /// A project of this person's own reads as shared once it reaches anyone, by invitation or by its link.
    func testAProjectSharedByYouSaysWhoItReaches() {
        XCTAssertEqual(ShareAudience(people: 1, byLink: false).reach, "1 person")
        XCTAssertEqual(ShareAudience(people: 3, byLink: true).reach, "3 people and anyone who has the link")
        XCTAssertEqual(ShareAudience(people: 0, byLink: true).reach, "anyone who has the link")
    }

    /// The share sheet opens beside where Share… was chosen, or, with that gone from the window, beside the project's
    /// sidebar row; a row view reused for another project stops standing for the one it showed.
    func testTheShareSheetOpensBesideWhereShareWasChosen() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: true)
        let content = try XCTUnwrap(window.contentView)
        let row = NSView()
        let button = NSView()
        content.addSubview(row)
        content.addSubview(button)
        let anchors = ShareAnchors()
        let other = ProjectID()
        anchors.register(row, as: .sidebar(project))
        anchors.register(button, as: .details(project))

        XCTAssertTrue(anchors.anchor(for: .details(project))?.view === button)
        XCTAssertEqual(anchors.anchor(for: .details(project))?.edge, .minY)
        button.removeFromSuperview()
        XCTAssertTrue(anchors.anchor(for: .details(project))?.view === row)
        XCTAssertEqual(anchors.anchor(for: .details(project))?.edge, .maxX)

        anchors.register(row, as: .sidebar(other))
        XCTAssertNil(anchors.anchor(for: .sidebar(project)))
        XCTAssertTrue(anchors.anchor(for: .sidebar(other))?.view === row)
    }
}
