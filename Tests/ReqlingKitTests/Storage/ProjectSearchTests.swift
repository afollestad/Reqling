import ReqlingKit
import XCTest

final class ProjectSearchTests: XCTestCase {
    private let document: ProjectDocument = {
        let users = RequestFolder(name: "Users", children: [
            .request(.http("List users", url: "{{baseUrl}}/users")),
            .request(.http("Delete user", method: .delete, url: "{{baseUrl}}/users/{{id}}"))
        ])
        let billing = RequestFolder(name: "Billing", children: [
            .request(.http("Invoices", url: "{{baseUrl}}/invoices")),
            .folder(RequestFolder(name: "Refunds", children: [.request(.http("Créer un remboursement", method: .post, url: "/refunds"))]))
        ])
        return ProjectDocument(name: "Shop API", items: [.folder(users), .folder(billing), .request(.http("Health", url: "/health"))])
    }()

    private func names(_ nodes: [RequestNode]?) -> [String] {
        (nodes ?? []).flatMap { node -> [String] in
            switch node {
            case .request(let request): [request.name]
            case .folder(let folder): [folder.name + "/"] + names(folder.children)
            }
        }
    }

    func testAnEmptyQueryOrMatchingProjectNameKeepsEverything() {
        XCTAssertEqual(document.filtered(matching: "  ")?.count, 3)
        XCTAssertEqual(document.filtered(matching: "shop")?.count, 3)
    }

    func testRequestsMatchOnNameMethodOrURLAndKeepTheirFolders() {
        XCTAssertEqual(names(document.filtered(matching: "users")), ["Users/", "List users", "Delete user"])
        XCTAssertEqual(names(document.filtered(matching: "delete")), ["Users/", "Delete user"])
        XCTAssertEqual(names(document.filtered(matching: "invoices")), ["Billing/", "Invoices"])
        XCTAssertEqual(names(document.filtered(matching: "/health")), ["Health"])
    }

    func testAMatchingFolderKeepsItsContents() {
        XCTAssertEqual(names(document.filtered(matching: "refunds")), ["Billing/", "Refunds/", "Créer un remboursement"])
    }

    func testEveryWordMustMatchIgnoringCaseAndDiacritics() {
        XCTAssertEqual(names(document.filtered(matching: "creer POST")), ["Billing/", "Refunds/", "Créer un remboursement"])
        XCTAssertNil(document.filtered(matching: "creer GET"))
        XCTAssertNil(document.filtered(matching: "nothing here"))
    }

    func testFiltersNarrowByMethodAndLastResultAndHideEmptyFolders() {
        let deleteID = document.allRequests.first { $0.request.name == "Delete user" }!.request.id
        let outcome: (RequestNodeID) -> RunOutcomeKind = { $0 == deleteID ? .failed : .notSent }

        XCTAssertEqual(names(document.filtered(matching: "", filter: RequestFilter(methods: [.delete]))), ["Users/", "Delete user"])
        let posts = document.filtered(matching: "", filter: RequestFilter(methods: [.post]))
        XCTAssertEqual(names(posts), ["Billing/", "Refunds/", "Créer un remboursement"])
        let failures = document.filtered(matching: "", filter: RequestFilter(outcomes: [.failed]), outcome: outcome)
        XCTAssertEqual(names(failures), ["Users/", "Delete user"])
        XCTAssertEqual(names(document.filtered(matching: "users", filter: RequestFilter(methods: [.get]))), ["Users/", "List users"])
        // A matching project name keeps only what passes the filter.
        XCTAssertEqual(names(document.filtered(matching: "shop", filter: RequestFilter(methods: [.delete]))), ["Users/", "Delete user"])
        XCTAssertNil(document.filtered(matching: "health", filter: RequestFilter(methods: [.post])))
    }
}
