import Foundation
import ReqlingKit
import XCTest

/// What hovering over each kind of name shows, against the fixture schema. `|` marks where the pointer is.
final class GraphQLHoverTests: XCTestCase {
    private var schema: GraphQLTypeSystem!

    override func setUp() async throws {
        try await super.setUp()
        // Read from SDL, which keeps input fields' defaults (GraphQLSwift's introspection leaves them out).
        schema = try await GraphQLTypeSystem.loading(schemaFile: Data(GraphQLOracle.fixtureSDL.utf8)).typeSystem
    }

    func testFieldsShowTheirParentArgumentsTypeAndDescription() throws {
        let hover = try XCTUnwrap(hover("{ me { bo|oks { title } } }"))

        XCTAssertEqual(
            hover.signature,
            "Author.books(first: Int = 10, after: String, orderBy: BookOrder = { field: TITLE, direction: DESC }): [Book!]!"
        )
        XCTAssertTrue(hover.description?.hasPrefix("The author's books") == true)
        XCTAssertEqual(hover.range, NSRange(location: 7, length: 5))
        XCTAssertEqual(self.hover("{ me { books { ti|tle } } }")?.signature, "Book.title: String!")
        XCTAssertEqual(self.hover("{ me { nick|name } }")?.deprecationReason, "Use `name`.")
        XCTAssertEqual(self.hover("{ search(text: \"x\") { __type|name } }")?.signature, "SearchResult.__typename: String!")
    }

    func testAnAliasShowsTheFieldItNames() {
        XCTAssertEqual(hover("{ me { head|ing: name } }")?.signature, "Author.name: String!")
    }

    func testArgumentsInputFieldsAndEnumValues() {
        XCTAssertEqual(hover("{ books(fir|st: 1) { id } }")?.signature, "first: Int = 20")
        XCTAssertEqual(hover("{ books(legacy|Page: 1) { id } }")?.deprecationReason, "Use `first`.")
        XCTAssertEqual(hover("{ books(order: { dir|ection: ASC }) { id } }")?.signature, "BookOrder.direction: Direction = ASC")
        XCTAssertEqual(hover("{ books(filter: { genre: POE|TRY }) { id } }")?.signature, "Genre.POETRY")
        XCTAssertEqual(hover("{ books(filter: { genre: POE|TRY }) { id } }")?.description, "Poems and verse.")
        XCTAssertEqual(hover("{ books(filter: { genre: SCIENCE|_FICTION }) { id } }")?.deprecationReason, "Use `FICTION` with a tag.")
    }

    func testVariablesShowTheTypeTheirOperationDeclares() throws {
        let usage = try XCTUnwrap(hover("query Q($id: ID!) { node(id: $i|d) { id } }"))
        let dollar = try XCTUnwrap(hover("query Q($id: ID!) { node(id: |$id) { id } }"))
        let definition = try XCTUnwrap(hover("query Q($i|d: ID!) { node(id: $id) { id } }"))

        XCTAssertEqual(usage.signature, "$id: ID!")
        XCTAssertEqual(usage.range, NSRange(location: 29, length: 3), "the $ is part of the name")
        XCTAssertEqual(dollar, usage)
        XCTAssertEqual(definition.signature, "$id: ID!")
    }

    func testTypesShowTheirDeclaration() {
        XCTAssertEqual(hover("{ search(text: \"x\") { ... on Bo|ok { id } } }")?.signature, "type Book implements Entity & Node")
        XCTAssertEqual(hover("{ search(text: \"x\") { ... on Bo|ok { id } } }")?.description, "A book in the catalog.")
        XCTAssertEqual(hover("query($f: BookFil|ter) { books(filter: $f) { id } }")?.signature, "input BookFilter")
        XCTAssertEqual(hover("fragment F on Search|Result { __typename }")?.signature, "union SearchResult = Book | Author")
        XCTAssertEqual(hover("qu|ery { ping }")?.signature, "type Root")
    }

    func testDirectivesAndFragments() {
        XCTAssertEqual(hover("{ me @ta|g(name: \"x\") { id } }")?.signature, "@tag(name: String!)")
        XCTAssertEqual(hover("{ me @tag(na|me: \"x\") { id } }")?.signature, "name: String!")
        XCTAssertEqual(hover("{ me { ...Par|ts } } fragment Parts on Author { id }")?.signature, "fragment Parts on Author")
    }

    func testNothingWhereTheSchemaDescribesNothing() {
        XCTAssertNil(hover("{ me |{ id } }"))
        XCTAssertNil(hover("{ search(text: \"x|\") { __typename } }"))
        XCTAssertNil(hover("{ unkn|own }"))
        XCTAssertNil(hover("query Na|me { ping }"))
        XCTAssertNil(hover("{ books(first: {{ty|pe}}) { id } }"))
    }

    // MARK: - Support

    private func hover(_ marked: String) -> GraphQLHover? {
        let marker = (marked as NSString).range(of: "|")
        let text = (marked as NSString).replacingCharacters(in: marker, with: "")
        return GraphQLDocumentAnalyzer(text: text, typeSystem: schema).hover(at: marker.location)
    }
}
