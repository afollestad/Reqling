import Foundation
import GraphQL
import ReqlingKit
import XCTest

/// graphql-language-service's autocomplete cases for executable documents (`GraphQLFixtures/graphql-language-service`),
/// against its schema, as a second opinion on what completion offers.
///
/// Where Reqling deliberately differs, each case compares only what both mean to offer: they hide deprecated fields
/// and the `__` meta types, while Reqling lists deprecated fields last and leaves meta types out; Reqling adds `null`
/// for nullable values and `on` after `...`. They also leave out type conditions the spec allows (`... on TestUnion`
/// inside a `Character`), so every type condition Reqling offers is checked against GraphQLSwift instead.
final class GraphQLLanguageServiceCompletionTests: XCTestCase {
    private var schema: GraphQLTypeSystem!
    private var sdl = ""

    override func setUp() async throws {
        try await super.setUp()
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "StarWarsSchema",
            withExtension: "graphql",
            subdirectory: "GraphQLFixtures/graphql-language-service"
        ))
        sdl = try String(contentsOf: url, encoding: .utf8)
        schema = try await GraphQLTypeSystem.loading(schemaFile: Data(sdl.utf8)).typeSystem
    }

    func testRootFields() {
        let root: Set = ["__typename", "droid", "hero", "human", "inputTypeTest", "union"]

        XCTAssertEqual(offered(" {}", at: 2), root)
        XCTAssertEqual(offered("{ ", at: 2), root)
        XCTAssertEqual(offered("{ h ", at: 3), ["hero", "human"])
    }

    func testFieldsOfAnAliasedFieldAFragmentAndAnInlineFragment() {
        let human: Set = ["__typename", "appearsIn", "friends", "id", "name", "secretBackstory"]

        XCTAssertEqual(offered("{ alias: human(id: \"1\") { ", at: 26), human)
        XCTAssertEqual(offered("fragment test on Human { ", at: 25), human)
        XCTAssertEqual(offered("fragment Foo on Character { ... on Human { }}", at: 42), human)
    }

    func testArguments() {
        XCTAssertEqual(offered("{ human (", at: 9), ["id"])
        XCTAssertEqual(offered("{ aliasTest: human( ", at: 20), ["id"])
        XCTAssertEqual(offered("{ test @deprecated(", at: 19), ["reason"])
    }

    func testInputTypesForVariables() {
        XCTAssertEqual(offered("query($exampleVariable: ) { ", at: 24), ["Boolean", "Episode", "InputType", "Int", "String"])
        XCTAssertEqual(offered("query($exampleVariable: In) { ", at: 26), ["InputType", "Int", "String"])
    }

    func testTypeConditions() throws {
        let composite: Set = ["AnotherInterface", "Character", "Droid", "Human", "Query", "TestInterface", "TestType", "TestUnion"]

        XCTAssertEqual(offered("fragment test on ", at: 17), composite)
        XCTAssertEqual(offered("fragment Foo on {}", at: 16), composite)
        XCTAssertEqual(offered("{ ... on ", at: 9), ["Query"])
        XCTAssertTrue(offered("{ hero(episode: JEDI) { ... on } }", at: 31).isSuperset(of: ["Character", "Droid", "Human"]))
        XCTAssertTrue(offered("fragment Foo on Character { ... on }", at: 35).isSuperset(of: ["Character", "Droid", "Human"]))
        try assertEveryConditionValid(in: "{ hero(episode: JEDI) { ... on } }", at: 31)
        try assertEveryConditionValid(in: "fragment Foo on Character { ... on } { hero { ...Foo } }", at: 35)
    }

    func testEnumValuesAndVariables() {
        XCTAssertEqual(offered("{ hero(episode: ", at: 16), ["EMPIRE", "JEDI", "NEWHOPE"])
        XCTAssertEqual(offered("query($id: String, $ep: Episode!){ hero(episode: $ }", at: 51), ["$ep"])
        XCTAssertEqual(offered("query($id: String!, $episode: Episode!){ hero(episode: ", at: 55), ["$episode", "EMPIRE", "JEDI", "NEWHOPE"])
    }

    func testFragmentNamesDefinedBeforeOrAfter() {
        let fragment = "fragment Foo on Human { id }"

        XCTAssertEqual(offered("\(fragment) query { human(id: \"1\") { ...", at: 57), ["Foo"])
        XCTAssertEqual(offered("query { human(id: \"1\") { ... }} \(fragment)", at: 28), ["Foo"])
        XCTAssertEqual(offered("\(fragment) query { hero(episode: JEDI) { ...", at: 62), ["Foo"])
    }

    func testDirectives() {
        let field: Set = ["include", "skip", "test"]

        XCTAssertEqual(offered("{ test @ }", at: 8), field)
        XCTAssertEqual(offered("{ test @", at: 8), field)
        XCTAssertEqual(offered("{ aliasTest: test @ }", at: 19), field)
        XCTAssertEqual(offered("query @", at: 7), [])
    }

    func testInputObjectFields() {
        XCTAssertEqual(offered("{ inputTypeTest(args: {", at: 23), ["key", "obj", "value"])
        XCTAssertEqual(offered("{ inputTypeTest(args: { obj: {", at: 30), ["key", "obj", "value"])
    }

    // MARK: - Support

    /// The labels completion offers, less what graphql-language-service leaves out by design (deprecated items and
    /// meta types) and what Reqling adds (`null`, and `on` after `...`).
    private func offered(_ text: String, at cursor: Int) -> Set<String> {
        let items = GraphQLDocumentAnalyzer(text: text, typeSystem: schema).completions(at: cursor)?.items ?? []
        return Set(items.filter { !$0.isDeprecated && !["__schema", "__type", "null", "on"].contains($0.label) }.map(\.label))
    }

    /// Every type condition offered at `cursor` makes a document GraphQLSwift accepts.
    private func assertEveryConditionValid(in text: String, at cursor: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let oracle = try buildSchema(source: sdl)
        for type in offered(text, at: cursor) {
            let filled = (text as NSString).replacingCharacters(in: NSRange(location: cursor, length: 0), with: "\(type) { __typename }")
            let errors = validate(schema: oracle, ast: try parse(source: Source(body: filled)))
            XCTAssertEqual(errors.map(\.message), [], "\(type) in \(filled)", file: file, line: line)
        }
    }
}
