import Foundation
import ReqlingKit
import XCTest

/// What completion offers at the cursor (`|` in each query) against the fixture schema.
final class GraphQLCompletionTests: XCTestCase {
    private var schema: GraphQLTypeSystem!

    override func setUp() async throws {
        try await super.setUp()
        schema = try await GraphQLOracle.decoded().typeSystem
    }

    func testDefinitionsStartWithTheirKeywords() {
        XCTAssertEqual(labels("|"), ["query", "mutation", "subscription", "fragment"])
        XCTAssertEqual(labels("qu|"), ["query"])
        XCTAssertEqual(labels("{ ping }\nfr|"), ["fragment"])
    }

    /// The fixture's schema order is GraphQLSwift's introspection order, which sorts fields; sets keep these tests to
    /// what is offered, while the ranking tests below pin the order.
    func testSelectionSetsOfferTheirTypesFieldsWithDeprecatedOnesLast() {
        let authorFields = labels("{ me { | } }")
        XCTAssertEqual(Set(authorFields), ["id", "createdAt", "name", "books", "__typename", "nickname"])
        XCTAssertEqual(authorFields.last, "nickname")
        XCTAssertEqual(Set(labels("{ | }")), ["node", "book", "books", "authors", "search", "me", "ping", "__schema", "__type", "__typename"])
        XCTAssertEqual(labels("{ books { author { books { tit| } } } }"), ["title"])
        XCTAssertEqual(Set(labels("query {\n  me {\n    |\n  }\n}")), Set(authorFields), "on an empty line of the set")
        XCTAssertEqual(Set(labels("mutation { | }")), ["addBook", "removeBook", "__typename"])
        XCTAssertEqual(labels("subscription { | }"), ["bookAdded", "__typename"])
    }

    func testTypedTextNarrowsAndTheWholeNameIsReplaced() throws {
        let list = try XCTUnwrap(completions("{ me { na|me } }"))

        // `__typename` holds n and a in order, so it matches too, after the names that start with them.
        XCTAssertEqual(list.items.map(\.label), ["name", "__typename", "nickname"])
        XCTAssertEqual(list.replacementRange, NSRange(location: 7, length: 4))
        XCTAssertEqual(list.items.first?.detail, "String!")
        XCTAssertEqual(list.items.last?.isDeprecated, true)
    }

    func testAnAliasIsFollowedByTheFieldItNames() {
        XCTAssertEqual(labels("{ me { heading: na| } }").first, "name")
    }

    func testArgumentsSkipThoseAlreadyGiven() {
        XCTAssertEqual(Set(labels("{ books(|) { id } }")), ["filter", "order", "first", "legacyPage"])
        XCTAssertEqual(labels("{ books(|) { id } }").last, "legacyPage")
        XCTAssertEqual(Set(labels("{ books(first: 1, |) { id } }")), ["filter", "order", "legacyPage"])
        XCTAssertEqual(labels("{ me @tag(|) }"), ["name"])
        XCTAssertEqual(completions("{ books(|) { id } }")?.items.first { $0.label == "first" }?.detail, "Int = 20")
    }

    func testValuesOfferEnumValuesBooleansNullAndVariablesThatFit() {
        // Enum values keep their declared order: introspection reports them as written.
        XCTAssertEqual(labels("{ books(filter: { genre: | }) { id } }"), ["FICTION", "NON_FICTION", "POETRY", "null", "SCIENCE_FICTION"])
        XCTAssertEqual(labels("{ me { books(orderBy: { field: | }) { id } } }"), ["TITLE", "CREATED_AT"])
        XCTAssertEqual(labels("query($show: Boolean!, $n: Int) { me @include(if: |) { id } }"), ["true", "false", "$show"])
        XCTAssertEqual(labels("query Q($n: Int) { books(first: |) { id } }"), ["null", "$n"])
        XCTAssertEqual(labels("{ __type(name: |) { name } }"), [], "a non-null String takes neither an enum nor null")
    }

    func testInputObjectsOfferTheirFieldsAtAnyDepth() {
        let filterFields: Set = ["genre", "titleContains", "publishedAfter", "authorIDs", "and", "legacyCode"]
        XCTAssertEqual(Set(labels("{ books(filter: { | }) { id } }")), filterFields)
        XCTAssertEqual(labels("{ books(filter: { | }) { id } }").last, "legacyCode")
        XCTAssertEqual(Set(labels("{ books(filter: { genre: FICTION, | }) { id } }")), filterFields.subtracting(["genre"]))
        XCTAssertEqual(labels("{ books(filter: { and: [{ title| }] }) { id } }"), ["titleContains"])
        XCTAssertEqual(Set(labels("mutation { addBook(input: { | }) { id } }")), ["title", "authorID", "genre", "tags"])
    }

    func testVariablesComeFromTheCurrentOperationAndMustFit() throws {
        let list = try XCTUnwrap(completions("query Q($id: ID!, $n: Int) { node(id: $|) { id } }"))

        XCTAssertEqual(list.items.map(\.label), ["$id"])
        XCTAssertEqual(list.replacementRange, NSRange(location: 38, length: 1), "the $ is replaced too")
        XCTAssertEqual(labels("query A($a: Int) { ping } query B($b: Int) { books(first: $|) { id } }"), ["$b"])
        XCTAssertEqual(labels("query Q($id: ID!) { node(id: $i|) { id } }"), ["$id"])
    }

    func testDirectivesAreOfferedOnlyWhereTheyMayGo() {
        XCTAssertEqual(labels("{ me @| }"), ["tag", "include", "skip"])
        XCTAssertEqual(labels("query @| { ping }"), ["tag"])
        XCTAssertEqual(labels("query($a: Int @|) { ping }"), ["tag"])
        XCTAssertEqual(labels("fragment F on Book @| { id }"), [])
    }

    func testSpreadsOfferOnAndFragmentsThatCanApply() {
        let fragments = "fragment A on Author { name }\nfragment B on Book { title }\n"

        XCTAssertEqual(labels(fragments + "{ me { ...| } }"), ["on", "A"])
        XCTAssertEqual(labels(fragments + "{ search(text: \"x\") { ...| } }"), ["on", "A", "B"])
    }

    func testTypeConditionsOfferTypesThatCanOverlap() {
        XCTAssertEqual(Set(labels("{ search(text: \"x\") { ... on | } }")), ["Author", "Book", "Node", "Entity", "SearchResult"])
        XCTAssertTrue(labels("fragment F on |").contains("Mutations"))
        XCTAssertFalse(labels("fragment F on |").contains("Genre"))
    }

    func testVariableTypesAreInputTypes() {
        let types = labels("query($x: |) { ping }")

        XCTAssertTrue(Set(["ID", "String", "Genre", "BookFilter", "DateTime"]).isSubset(of: Set(types)), "\(types)")
        XCTAssertFalse(types.contains("Book"))
        XCTAssertFalse(types.contains { $0.hasPrefix("__") })
        let narrowed = labels("query($x: [Boo|]) { ping }")
        XCTAssertEqual(Set(narrowed.dropLast()), ["BookFilter", "BookLookup", "BookOrder", "BookField", "Boolean"])
        XCTAssertEqual(narrowed.last, "NewBook", "scattered letters rank after names that start with them")
    }

    func testNothingInsideStringsCommentsAndTemplates() {
        XCTAssertNil(completions("{ search(text: \"le|\") { __typename } }"))
        XCTAssertNil(completions("{ search(text: \"le|"))
        XCTAssertNil(completions("{ me # na|"))
        XCTAssertNil(completions("{ node(id: {{to|"))
        XCTAssertNil(completions("{ node(id: {{tok|en}}) { id } }"))
        XCTAssertNotNil(completions("{ node(id: {{token}}) { | } }"))
    }

    func testNamesNothingInTheSchemaDescribesOfferNothing() {
        XCTAssertEqual(labels("query My| { ping }"), [])
        XCTAssertEqual(labels("fragment Na| on Book { id }"), [])
        XCTAssertEqual(labels("{ unknown { | } }"), [])
    }

    func testHalfWrittenQueriesStillComplete() {
        XCTAssertEqual(labels("{ me { na|"), ["name", "__typename", "nickname"])
        XCTAssertEqual(labels("{ books(filter: { genre: F|"), ["FICTION", "NON_FICTION", "SCIENCE_FICTION"])
        XCTAssertEqual(labels("{ books(first: 1 { tit| } }"), ["title"], "a missing ) still reaches the selection set")
        XCTAssertEqual(Set(labels("{ me { books { title } ) | } }")), ["id", "createdAt", "name", "books", "__typename", "nickname"])
    }

    // MARK: - Ranking

    func testRankingPrefersExactCaseThenAnyCaseThenScatteredLetters() {
        let names = ["firstName", "FirstAid", "first", "lastFirst", "fsn", "other"]

        let ranked = GraphQLCompletionRanking.rank(names, by: "first", name: { $0 }, isDeprecated: { _ in false })
        let scattered = GraphQLCompletionRanking.rank(names, by: "fstn", name: { $0 }, isDeprecated: { _ in false })

        XCTAssertEqual(ranked, ["first", "firstName", "FirstAid", "lastFirst"])
        XCTAssertEqual(scattered, ["firstName"])
        XCTAssertEqual(GraphQLCompletionRanking.rank(names, by: "", name: { $0 }, isDeprecated: { $0 == "first" }).last, "first")
    }

    // MARK: - Support

    /// Completion at the `|` in `marked`, which is removed; a query without one completes at its end.
    private func completions(_ marked: String) -> GraphQLCompletionList? {
        let cursor = (marked as NSString).range(of: "|")
        let text = cursor.location == NSNotFound ? marked : (marked as NSString).replacingCharacters(in: cursor, with: "")
        let location = cursor.location == NSNotFound ? (text as NSString).length : cursor.location
        return GraphQLDocumentAnalyzer(text: text, typeSystem: schema).completions(at: location)
    }

    private func labels(_ marked: String) -> [String] {
        completions(marked)?.items.map(\.label) ?? []
    }
}
