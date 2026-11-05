import Foundation
import ReqlingKit
import XCTest

/// Diagnostics for queries against the fixture schema: what GraphQLSwift reports, placed on what the problem names,
/// with `{{templates}}` read as what they stand for.
final class GraphQLDocumentValidatorTests: XCTestCase {
    private var schema: GraphQLTypeSystem!
    private var validator: GraphQLDocumentValidator!

    override func setUp() async throws {
        try await super.setUp()
        schema = try await GraphQLTypeSystem.loading(schemaFile: Data(GraphQLOracle.fixtureSDL.utf8)).typeSystem
        validator = GraphQLDocumentValidator(typeSystem: schema)
    }

    /// The corpus uses deprecated elements on purpose; those are warnings, never errors.
    func testAValidCorpusHasNoErrors() {
        for query in GraphQLAnalysisOracleTests.corpus {
            XCTAssertEqual(validator.diagnostics(for: query).filter { $0.severity == .error }, [], query)
        }
    }

    func testAMisspelledFieldIsMarkedAtItsNameWithASuggestion() throws {
        let query = "{ me { nmae } }"

        let diagnostic = try XCTUnwrap(validator.diagnostics(for: query).first)

        XCTAssertEqual(marked(diagnostic, in: query), "nmae")
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertTrue(diagnostic.message.contains("Did you mean \"name\""), diagnostic.message)
    }

    func testMissingArgumentsWrongValuesAndUnknownEnumValues() {
        XCTAssertEqual(marks("{ node { id } }"), ["node"])
        XCTAssertEqual(marks("{ books(first: \"ten\") { id } }"), ["\"ten\""])
        XCTAssertEqual(marks("{ books(filter: { genre: FANTASY }) { id } }"), ["FANTASY"])
        XCTAssertEqual(marks("{ books(nope: 1) { id } }"), ["nope"])
        XCTAssertEqual(marks("{ book(lookup: { id: \"1\", isbn: \"2\" }) { id } }").count, 1, "@oneOf takes exactly one field")
    }

    func testSelectionsMustMatchWhatTheyAreOn() {
        // As graphql-js does, the selection that should not be there is marked.
        XCTAssertEqual(marks("{ ping { length } }"), ["{"])
        XCTAssertEqual(marks("{ me }"), ["me"])
        XCTAssertEqual(marks("{ me { ... on Book { title } } }"), ["Book"])
    }

    func testVariablesMustBeDeclaredUsedAndOfAnInputType() {
        XCTAssertEqual(marks("query($a: Nope) { books(first: $a) { id } }").first, "Nope")
        XCTAssertEqual(marks("{ books(first: $missing) { id } }"), ["$missing"])
        XCTAssertEqual(marks("query($unused: Int) { ping }"), ["$unused"])
        XCTAssertEqual(marks("query($id: String) { node(id: $id) { id } }"), ["$id"], "a String cannot fill an ID!")
    }

    func testSyntaxErrorsMarkTheTokenAtFaultWithoutGraphQLSwiftsPrefix() throws {
        let colon = try XCTUnwrap(validator.diagnostics(for: "{ me(: 1) { id } }").first)
        let unclosed = try XCTUnwrap(validator.diagnostics(for: "{ me { name }").first)

        XCTAssertEqual(marked(colon, in: "{ me(: 1) { id } }"), ":")
        XCTAssertFalse(colon.message.contains("Syntax Error"), colon.message)
        XCTAssertFalse(colon.message.contains("\n"), colon.message)
        XCTAssertEqual(marked(unclosed, in: "{ me { name }"), "}", "the end of the document marks its last token")
    }

    /// GraphQLSwift counts positions in UTF-8; the marks land right after emoji and accents all the same.
    func testMarksHoldAfterNonASCIIText() {
        XCTAssertEqual(marks("{ search(text: \"📚 café ☕️\") { __typename } me { nmae } }"), ["nmae"])
        XCTAssertEqual(marks("# Ünïcödé 🎉\n{ me(: 1) { id } }"), [":"])
    }

    func testTemplatesAreReadAsWhatTheyStandFor() {
        let fine = [
            "{ node(id: {{id}}) { id } }",
            "{ search(text: \"{{query}} and more\") { __typename } }",
            "{ search(text: \"\"\"{{query}}\"\"\") { __typename } }",
            "{ book(lookup: {{lookup}}) { title } }",
            "{ books(filter: { authorIDs: [{{first}}, {{second}}] }) { id } }",
            "query($n: Int = {{limit}}) { books(first: $n) { id } }",
            "{ me { {{field}} } }",
            "{ me { books({{argument}}: 1) { id } } }"
        ]
        for query in fine {
            XCTAssertEqual(validator.diagnostics(for: query), [], query)
        }
    }

    func testTemplatesDoNotHideProblemsAroundThem() {
        XCTAssertEqual(marks("{ me { nmae } node(id: {{id}}) { id } }"), ["nmae"])
        XCTAssertEqual(marks("{ node(id: {{id}}) { idd } }"), ["idd"])
    }

    func testDeprecatedUseIsAWarning() throws {
        let diagnostics = validator.diagnostics(for: "{ me { nickname } books(legacyPage: 1, filter: { genre: SCIENCE_FICTION }) { id } }")

        XCTAssertEqual(diagnostics.map(\.severity), [.warning, .warning, .warning])
        XCTAssertTrue(diagnostics.first?.message.contains("Use `name`.") == true, "\(diagnostics)")
    }

    func testSeveralOperationsNeedTheOperationFieldToNameOne() {
        let query = "query A { ping } query B { me { id } }"

        XCTAssertEqual(validator.diagnostics(for: query).map(\.severity), [.warning])
        XCTAssertEqual(marks(query), ["query"])
        XCTAssertEqual(validator.diagnostics(for: query, operationName: "B"), [])
        XCTAssertEqual(validator.diagnostics(for: query, operationName: "C").map(\.message), ["No operation here is named “C”."])
        XCTAssertEqual(validator.diagnostics(for: query, operationName: "{{operation}}"), [])
        XCTAssertEqual(validator.diagnostics(for: "query A { ping }", operationName: "Z").count, 1)
    }

    func testWithoutASchemaOnlySyntaxIsChecked() {
        XCTAssertEqual(GraphQLDocumentValidator.syntaxOnly.diagnostics(for: "{ nmae }"), [])
        XCTAssertEqual(GraphQLDocumentValidator.syntaxOnly.diagnostics(for: "{ nmae").count, 1)
        XCTAssertEqual(GraphQLDocumentValidator.syntaxOnly.diagnostics(for: "{ a(id: {{x}}) }"), [])
    }

    func testDocumentsTooDeepToCheckSaySo() {
        let deep = String(repeating: "{ a ", count: 200) + String(repeating: "}", count: 200)

        let diagnostics = validator.diagnostics(for: deep)

        XCTAssertEqual(diagnostics.map(\.severity), [.warning])
        XCTAssertTrue(diagnostics.first?.message.contains("too deep") == true)
    }

    func testDefaultsThatAreNotLiteralsStillLeaveTheRestChecked() {
        let query = GraphQLTypeSystem.NamedType(name: "Query", kind: .object, fields: [
            GraphQLTypeSystem.Field(
                name: "items",
                args: [GraphQLTypeSystem.InputValue(name: "limit", type: .nonNull(.named("Int")), defaultValue: "ten, roughly")],
                type: .named("Int")
            )
        ])
        let odd = GraphQLDocumentValidator(typeSystem: GraphQLTypeSystem(rootTypes: [.query: "Query"], types: [query]))

        XCTAssertEqual(odd.diagnostics(for: "{ items }"), [], "the argument still has a default")
        XCTAssertEqual(odd.diagnostics(for: "{ itemz }").count, 1)
        XCTAssertNil(odd.issue)
    }

    /// The conservative introspection query cannot tell whether a directive repeats; validation must not guess no.
    func testADirectiveOfUnknownRepeatabilityMayRepeat() async throws {
        let conservative = try await GraphQLOracle.decoded(capabilities: .conservative).typeSystem
        let query = "{ me @tag(name: \"a\") @tag(name: \"b\") { id } }"

        XCTAssertEqual(GraphQLDocumentValidator(typeSystem: conservative).diagnostics(for: query), [])
        XCTAssertEqual(validator.diagnostics(for: query), [])
        XCTAssertEqual(validator.diagnostics(for: "{ me @include(if: true) @include(if: false) { id } }").count, 1)
    }

    func testEveryMarkFitsInsideTheDocument() {
        for query in GraphQLAnalysisOracleTests.corpus {
            for cut in stride(from: 1, to: query.utf16.count, by: 7) {
                let text = String(query.utf16.prefix(cut)) ?? ""
                for diagnostic in validator.diagnostics(for: text) {
                    XCTAssertGreaterThan(diagnostic.range.length, 0, text)
                    XCTAssertLessThanOrEqual(NSMaxRange(diagnostic.range), text.utf16.count, text)
                }
            }
        }
    }

    // MARK: - Support

    private func marks(_ query: String) -> [String] {
        validator.diagnostics(for: query).map { marked($0, in: query) }
    }

    private func marked(_ diagnostic: GraphQLDiagnostic, in query: String) -> String {
        (query as NSString).substring(with: diagnostic.range)
    }
}
