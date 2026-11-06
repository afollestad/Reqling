import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
extension AppModelTests {
    /// The field commits as the selection moves away, so the rename lands on the row it began on, and the end of
    /// editing that removing the field causes cannot rename it again.
    func testAnInPlaceRenameLandsOnTheItemItBeganOnOnce() throws {
        let project = try makeProject()
        model.newRequest()
        let first = try XCTUnwrap(model.selection?.nodeID)
        model.beginRename(.node(project, first))
        model.newRequest()

        model.endRename(.node(project, first), to: "Users")
        model.endRename(.node(project, first), to: "Again")

        let document = try XCTUnwrap(fixture.library.document(project))
        XCTAssertEqual(document.node(first)?.name, "Users")
        XCTAssertNil(model.renaming)
    }

    func testCancellingKeepsTheNameAndAnotherRowsEndIsIgnored() throws {
        let project = try makeProject()
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)
        model.beginRename(.project(project))

        model.endRename(.node(project, request), to: "Elsewhere")
        XCTAssertEqual(model.renaming, .project(project))
        XCTAssertEqual(fixture.library.document(project)?.node(request)?.name, "New Request")

        model.endRename(.project(project), to: nil)
        XCTAssertNil(model.renaming)
        XCTAssertEqual(fixture.library.document(project)?.name, "API")
    }

    /// Deleting the row mid-edit, as an agent or a `git pull` can, commits what was typed as the field goes; with the
    /// item gone there is nothing to rename, and no alert about it.
    func testEndingARenameOfADeletedItemDropsItQuietly() throws {
        let project = try makeProject()
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)
        model.beginRename(.node(project, request))

        model.delete(request, in: project)
        model.endRename(.node(project, request), to: "Users")

        XCTAssertNil(model.renaming)
        XCTAssertNil(model.alert)
    }

    /// A read-only or unavailable project offers no rename, which could only fail, and neither does a missing item.
    func testOnlyALoadedWritableProjectsItemsCanBeRenamed() throws {
        let project = try makeProject()
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)
        XCTAssertTrue(model.canRename(.project(project)))
        XCTAssertTrue(model.canRename(.node(project, request)))
        XCTAssertFalse(model.canRename(.node(project, RequestNodeID())))

        let projectFile = try XCTUnwrap(fixture.library.project(project)?.url.appendingPathComponent("project.json"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: projectFile)) as? [String: Any])
        json["formatVersion"] = ProjectDocument.currentFormatVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: projectFile)
        fixture.library.reload(project)
        XCTAssertEqual(fixture.library.project(project)?.isReadOnly, true)
        XCTAssertFalse(model.canRename(.project(project)))
        model.beginRename(.node(project, request))
        XCTAssertNil(model.renaming)

        try FileManager.default.moveItem(at: projectFile, to: fixture.profile.applicationSupportDirectory.appendingPathComponent("aside.json"))
        fixture.library.reload(project)
        XCTAssertNil(fixture.library.document(project))
        XCTAssertFalse(model.canRename(.project(project)))
    }
}
