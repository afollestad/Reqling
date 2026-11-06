import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
extension AppModelTests {
    /// The field commits as the selection moves away, or as a newer rename replaces it, so the rename lands on the row
    /// it began on and leaves the newer one going.
    func testAnInPlaceRenameLandsOnTheItemItBeganOn() throws {
        let project = try makeProject()
        model.newRequest()
        let first = try XCTUnwrap(model.selection?.nodeID)
        XCTAssertEqual(model.renaming, .node(project, first), "a new request starts renamed")
        model.newRequest()
        let second = try XCTUnwrap(model.selection?.nodeID)

        model.endRename(.node(project, first), to: "Users")

        XCTAssertEqual(fixture.library.document(project)?.node(first)?.name, "Users")
        XCTAssertEqual(model.renaming, .node(project, second))
        model.endRename(.node(project, second), to: nil)
        XCTAssertNil(model.renaming)
    }

    func testCancellingKeepsTheName() throws {
        let project = try makeProject()
        model.beginRename(.project(project))

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
        model.endRename(.node(project, request), to: nil)
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
