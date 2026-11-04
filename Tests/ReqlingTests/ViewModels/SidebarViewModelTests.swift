import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
final class SidebarViewModelTests: XCTestCase {
    private var fixture: AppFixture!

    override func setUp() async throws {
        fixture = AppFixture()
        for (name, methods) in [("Shop", [HTTPMethod.get, .post]), ("Billing", [.delete])] {
            let id = try fixture.library.createProject(named: name)
            try fixture.library.mutate(id) { document in
                for method in methods {
                    let request = RequestItem(name: "\(name) \(method.rawValue)", kind: .http(HTTPRequestSpec(method: method)))
                    try document.insert(.request(request), into: nil)
                }
            }
        }
    }

    override func tearDown() async throws {
        fixture.tearDown()
        fixture = nil
    }

    private var sidebar: SidebarViewModel {
        fixture.model.sidebar
    }

    func testAnUnfilteredSidebarShowsEveryProjectWithItsCount() {
        XCTAssertFalse(sidebar.isFiltering)
        XCTAssertEqual(sidebar.sections.map(\.project.name), ["Shop", "Billing"])
        XCTAssertEqual(sidebar.sections.map(\.requestCount), [2, 1])
    }

    func testTheQueryAndFiltersNarrowTheSections() {
        sidebar.query = "post"
        XCTAssertEqual(sidebar.sections.map(\.project.name), ["Shop"])
        XCTAssertEqual(sidebar.sections.map(\.requestCount), [1])

        sidebar.query = ""
        sidebar.filter = RequestFilter(methods: [.delete])
        XCTAssertTrue(sidebar.isFiltering)
        XCTAssertEqual(sidebar.sections.map(\.project.name), ["Billing"])

        sidebar.filter = RequestFilter(outcomes: [.succeeded])
        XCTAssertTrue(sidebar.sections.isEmpty)

        sidebar.clearFilters()
        XCTAssertEqual(sidebar.sections.count, 2)
    }

    func testSectionsFollowLibraryChanges() throws {
        _ = sidebar.sections
        let shop = try XCTUnwrap(fixture.library.projects.first?.id)

        try fixture.library.mutate(shop) { try $0.insert(.request(.init(name: "New", kind: .http(HTTPRequestSpec()))), into: nil) }

        XCTAssertEqual(sidebar.sections.first?.requestCount, 3)
    }
}
