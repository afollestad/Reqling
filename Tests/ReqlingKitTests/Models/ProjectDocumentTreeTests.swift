import ReqlingKit
import XCTest

final class ProjectDocumentTreeTests: XCTestCase {
    func testInsertingAFolderRefusesAnIDAlreadyInTheTreeAnywhereInsideIt() throws {
        let existing = RequestItem.http("Existing")
        var document = ProjectDocument(name: "Tree", items: [.request(existing)])
        let before = document
        let imported = RequestFolder(name: "Imported", children: [.folder(RequestFolder(name: "Nested", children: [.request(existing)]))])

        XCTAssertThrowsError(try document.insert(.folder(imported), into: nil)) { error in
            XCTAssertEqual(error as? ProjectTreeError, .duplicateID)
        }
        XCTAssertEqual(document, before)
    }

    func testInsertingAFolderRefusesChildrenThatRepeatOneID() throws {
        let child = RequestItem.http("Child")
        var document = ProjectDocument(name: "Tree")
        let before = document
        let twins = RequestFolder(name: "Twins", children: [.request(child), .request(child)])

        XCTAssertThrowsError(try document.insert(.folder(twins), into: nil)) { error in
            XCTAssertEqual(error as? ProjectTreeError, .duplicateID)
        }
        XCTAssertEqual(document, before)
    }
}
