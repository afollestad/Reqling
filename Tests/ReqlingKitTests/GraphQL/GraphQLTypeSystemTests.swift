import Foundation
import GraphQL
import ReqlingKit
import XCTest

/// Decoding introspection and printing SDL, checked against GraphQLSwift: a schema introspected, decoded, printed, and
/// rebuilt must introspect exactly as the original does.
final class GraphQLTypeSystemTests: XCTestCase {
    func testRoundTripKeepsEverythingIntrospectionReports() async throws {
        let original = try GraphQLOracle.schema()
        let decoded = try await GraphQLOracle.decoded(capabilities: .all)

        let rebuilt = try buildSchema(source: decoded.typeSystem.sdl())

        XCTAssertEqual(decoded.issues, [])
        try await assertDescribedAlike(rebuilt, original)
        XCTAssertEqual(decoded.typeSystem.types.count, original.typeMap.count)
    }

    /// What graphql-js's default query reads round-trips too, for a schema that uses nothing newer.
    func testConservativeRoundTripKeepsAnOlderSchemaWhole() async throws {
        let sdl = """
            "Old-style root"
            type Query {
              "The thing."
              thing(id: ID!, size: Int = 3): Thing
              things: [Thing!]! @deprecated
            }
            interface Named { name: String! }
            type Thing implements Named { name: String!, kind: Kind @deprecated(reason: "Gone soon.") }
            enum Kind { BIG SMALL @deprecated }
            input Filter { kind: Kind = BIG, names: [String!] }
            directive @audit(note: String) on FIELD | QUERY
            """
        let decoded = try await GraphQLOracle.decoded(sdl, capabilities: .conservative)

        let rebuilt = try buildSchema(source: decoded.typeSystem.sdl())

        try await assertDescribedAlike(rebuilt, try GraphQLOracle.schema(sdl), capabilities: .conservative)
    }

    func testReadsTheFixtureSchemaAsGraphQLSwiftDescribesIt() async throws {
        let schema = try await GraphQLOracle.decoded().typeSystem

        XCTAssertEqual(schema.rootTypes, [.query: "Root", .mutation: "Mutations", .subscription: "Events"])
        XCTAssertTrue(schema.description?.contains("📚") == true)
        let books = try XCTUnwrap(schema.field("books", on: "Author"))
        XCTAssertEqual(books.type, .nonNull(.list(.nonNull(.named("Book")))))
        XCTAssertEqual(books.arg("orderBy")?.defaultValue, "{ field: TITLE, direction: DESC }")
        XCTAssertTrue(books.description?.contains("\n\nPages hold at most 100.") == true)
        XCTAssertEqual(schema.field("shelves", on: "Book")?.type.description, "[[String!]!]!")
        XCTAssertEqual(schema.type(named: "Author")?.interfaces, ["Entity", "Node"])
        XCTAssertEqual(Set(schema.type(named: "Node")?.possibleTypes ?? []), ["Author", "Book"])
        XCTAssertEqual(schema.type(named: "DateTime")?.specifiedByURL, "https://scalars.graphql.org/andimarek/date-time")
        XCTAssertEqual(schema.type(named: "BookLookup")?.isOneOf, true)
        XCTAssertEqual(schema.type(named: "Genre")?.enumValues.first { $0.isDeprecated }?.name, "SCIENCE_FICTION")
        XCTAssertEqual(schema.directive(named: "tag")?.locations.contains(.variableDefinition), true)
        XCTAssertEqual(schema.field("__typename", on: "SearchResult")?.type.description, "String!")
        XCTAssertNotNil(schema.field("__schema", on: "Root"))
        XCTAssertNil(schema.field("__schema", on: "Book"), "only the query root has __schema")
    }

    // MARK: - What older or odder servers send

    func testAcceptsAWholeResponseABareSchemaOrTheSchemaObject() async throws {
        let response = try GraphQLOracle.object(try await GraphQLOracle.introspectionResponse())
        let bare = try XCTUnwrap(response["data"] as? [String: Any])
        let schemaObject = try XCTUnwrap(bare["__schema"])

        let shapes = try [response, bare, schemaObject].map { try GraphQLTypeSystem.decoding(introspection: GraphQLOracle.data($0)).typeSystem }

        XCTAssertEqual(shapes[0], shapes[1])
        XCTAssertEqual(shapes[1], shapes[2])
    }

    func testReadsGraphQLJS15sSpellingAndAMissingRepeatability() async throws {
        let edited = try await editedSchema { schema in
            schema["types"] = (schema["types"] as? [[String: Any]])?.map { type in
                var type = type
                type["specifiedByUrl"] = type.removeValue(forKey: "specifiedByURL")
                return type
            }
            schema["directives"] = (schema["directives"] as? [[String: Any]])?.map { directive in
                var directive = directive
                directive.removeValue(forKey: "isRepeatable")
                return directive
            }
        }

        XCTAssertEqual(edited.typeSystem.type(named: "DateTime")?.specifiedByURL, "https://scalars.graphql.org/andimarek/date-time")
        let tag = try XCTUnwrap(edited.typeSystem.directive(named: "tag"))
        XCTAssertNil(tag.isRepeatable)
        XCTAssertFalse(edited.typeSystem.sdl(forDirective: "tag")?.contains("repeatable") ?? true)
    }

    func testLeavesOutWhatItCannotReadAndSaysWhy() async throws {
        let edited = try await editedSchema { schema in
            schema["types"] = (schema["types"] as? [[String: Any]])?.map { type in
                var type = type
                if type["name"] as? String == "JSON" {
                    type["kind"] = "MYSTERY"
                }
                if type["name"] as? String == "Book" {
                    // The type reference stops where a shallower query would have stopped reading.
                    type["fields"] = (type["fields"] as? [[String: Any]])?.map { field in
                        var field = field
                        if field["name"] as? String == "shelves" {
                            field["type"] = ["kind": "NON_NULL", "name": NSNull(), "ofType": ["kind": "LIST", "name": NSNull(), "ofType": NSNull()]]
                        }
                        return field
                    }
                }
                return type
            }
        }

        XCTAssertNil(edited.typeSystem.type(named: "JSON"))
        XCTAssertNil(edited.typeSystem.field("shelves", on: "Book"))
        XCTAssertNotNil(edited.typeSystem.field("title", on: "Book"))
        XCTAssertEqual(edited.issues.count, 2)
        XCTAssertTrue(edited.issues.contains { $0.contains("JSON") && $0.contains("MYSTERY") }, "\(edited.issues)")
        XCTAssertTrue(edited.issues.contains { $0.contains("Book.shelves") && $0.contains("deeper") }, "\(edited.issues)")
    }

    func testADeprecationWithoutAReasonGetsTheDefaultOne() async throws {
        let edited = try await editedSchema { schema in
            schema["types"] = (schema["types"] as? [[String: Any]])?.map { type in
                var type = type
                if type["name"] as? String == "Genre" {
                    type["enumValues"] = (type["enumValues"] as? [[String: Any]])?.map { value in
                        var value = value
                        value["deprecationReason"] = NSNull()
                        return value
                    }
                }
                return type
            }
        }

        let deprecated = edited.typeSystem.type(named: "Genre")?.enumValues.first { $0.name == "SCIENCE_FICTION" }

        XCTAssertEqual(deprecated?.deprecationReason, "No longer supported")
        XCTAssertEqual(edited.typeSystem.type(named: "Genre")?.enumValues.first?.isDeprecated, false)
    }

    func testRefusesWhatHoldsNoSchema() {
        let cases: [(String, GraphQLSchemaDecodingError)] = [
            ("<html></html>", .notJSON),
            (#"{"data":{"me":{"name":"x"}}}"#, .noSchema),
            (#"{"__schema":{"types":[]}}"#, .noQueryType)
        ]
        for (body, expected) in cases {
            XCTAssertThrowsError(try GraphQLTypeSystem.decoding(introspection: Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? GraphQLSchemaDecodingError, expected)
            }
        }
    }

    // MARK: - Schema files

    /// A file reads as its server would describe it, and better: GraphQLSwift-based servers drop input fields' defaults
    /// from introspection, which reading the file restores.
    func testAnSDLFileReadsAsAServerDescribesItWithItsInputDefaults() async throws {
        let fromFile = try await GraphQLTypeSystem.loading(schemaFile: Data(GraphQLOracle.fixtureSDL.utf8))
        let fromServer = try await GraphQLOracle.decoded()

        XCTAssertEqual(fromFile.issues, [])
        XCTAssertEqual(fromFile.typeSystem.type(named: "NewBook")?.inputField("genre")?.defaultValue, "FICTION")
        XCTAssertEqual(fromFile.typeSystem.type(named: "NewBook")?.inputField("tags")?.defaultValue, #"["new"]"#)
        XCTAssertEqual(fromFile.typeSystem.type(named: "BookOrder")?.inputField("direction")?.defaultValue, "ASC")
        XCTAssertNil(fromServer.typeSystem.type(named: "NewBook")?.inputField("genre")?.defaultValue)
        XCTAssertEqual(Self.withoutInputDefaults(fromFile.typeSystem), fromServer.typeSystem)
    }

    func testAJSONFileReadsWithOrWithoutItsByteOrderMark() async throws {
        let json = try await GraphQLOracle.introspectionResponse()

        let plain = try await GraphQLTypeSystem.loading(schemaFile: json)
        let marked = try await GraphQLTypeSystem.loading(schemaFile: Data([0xEF, 0xBB, 0xBF]) + json)

        XCTAssertEqual(plain.typeSystem, marked.typeSystem)
        XCTAssertNotNil(plain.typeSystem.type(named: "Book"))
    }

    /// GraphQLSwift's own line numbers miscount after non-ASCII text; the error names the line that is really wrong.
    func testAnUnreadableSDLFileNamesTheLineAtFault() async {
        let sdl = "\"Café ☕️ menu\"\ntype Query {\n  coffee: Coffee\n  tea: Tea\n}\ntype Coffee { name String }\n"

        do {
            _ = try await GraphQLTypeSystem.loading(schemaFile: Data(sdl.utf8))
            XCTFail("Loaded an invalid schema")
        } catch {
            XCTAssertTrue(error.message.hasPrefix("The schema could not be read: line 6: "), error.message)
            XCTAssertFalse(error.message.contains("Syntax Error"), error.message)
        }
    }

    func testAnSDLFileWithoutAQueryTypeSaysSo() async {
        do {
            _ = try await GraphQLTypeSystem.loading(schemaFile: Data("type Book { title: String }".utf8))
            XCTFail("Loaded a schema with no query type")
        } catch {
            XCTAssertTrue(error.message.contains("no query type"), error.message)
        }
    }

    func testAnSDLFileWithFixableProblemsStillLoadsAndSaysSo() async throws {
        let decoded = try await GraphQLTypeSystem.loading(schemaFile: Data("type Query { a: Int @unknownDirective }".utf8))

        XCTAssertNotNil(decoded.typeSystem.field("a", on: "Query"))
        XCTAssertEqual(decoded.issues.count, 1)
        XCTAssertTrue(decoded.issues.first?.contains("unknownDirective") == true, "\(decoded.issues)")
    }

    // MARK: - Printing

    /// Descriptions with leading indentation, surrounding blank lines, or control characters cannot be block strings
    /// without changing them; whatever form they print in, GraphQLSwift must read them back exactly.
    func testDescriptionsSurvivePrintingWhateverTheyHold() throws {
        let descriptions = [
            "Plain.",
            "Two\nlines",
            "  Indented\n  throughout",
            "\nBlank first line",
            "Ends with a quote \"",
            "Has \"\"\" triple quotes",
            "Tab\tand bell \u{07}",
            "Back\\slash"
        ]
        let types = descriptions.enumerated().map { index, description in
            GraphQLTypeSystem.NamedType(name: "T\(index)", kind: .scalar, description: description)
        }
        let query = GraphQLTypeSystem.NamedType(name: "Query", kind: .object, fields: [GraphQLTypeSystem.Field(name: "a", type: .named("Int"))])
        let schema = GraphQLTypeSystem(rootTypes: [.query: "Query"], types: [query] + types)

        let rebuilt = try buildSchema(source: schema.sdl())

        for (index, description) in descriptions.enumerated() {
            XCTAssertEqual((rebuilt.getType(name: "T\(index)") as? GraphQLScalarType)?.description, description, description)
        }
    }

    /// The generated schema is large enough to show that nothing grows faster than the schema does.
    func testAThousandsOfTypesSchemaLoadsPrintsAndRebuilds() async throws {
        var lines = ["type Query { first: T0 }"]
        for index in 0..<2_000 {
            let next = (index + 1) % 2_000
            lines.append("type T\(index) { id: ID!, next: T\(next), list(limit: Int = 10, kind: K\(index % 50)): [T\(next)!]! }")
        }
        for index in 0..<50 {
            lines.append("enum K\(index) { A B C }")
        }

        let decoded = try await GraphQLTypeSystem.loading(schemaFile: Data(lines.joined(separator: "\n").utf8))
        let rebuilt = try buildSchema(source: decoded.typeSystem.sdl())

        // GraphQLSwift reports only the built-in scalars a schema uses: String, Boolean (introspection's own), and ID, Int.
        XCTAssertEqual(decoded.typeSystem.types.filter { !$0.name.hasPrefix("__") }.count, 2_000 + 50 + 1 + 4)
        XCTAssertEqual(rebuilt.typeMap.count, decoded.typeSystem.types.count)
    }

    func testPrintsInputFieldDefaultsSoTheyStayOptional() throws {
        let filter = GraphQLTypeSystem.NamedType(name: "Filter", kind: .inputObject, inputFields: [
            GraphQLTypeSystem.InputValue(name: "limit", type: .nonNull(.named("Int")), defaultValue: "10")
        ])
        let query = GraphQLTypeSystem.NamedType(name: "Query", kind: .object, fields: [
            GraphQLTypeSystem.Field(name: "items", args: [GraphQLTypeSystem.InputValue(name: "filter", type: .named("Filter"))], type: .named("Int"))
        ])
        let schema = try buildSchema(source: GraphQLTypeSystem(rootTypes: [.query: "Query"], types: [query, filter]).sdl())

        let result = graphQLValidation(of: "{ items(filter: {}) }", against: schema)

        XCTAssertEqual(result, [])
    }

    // MARK: - Browsing

    func testSearchFindsTypesBeforeFieldsAndReferencesNameEveryUse() async throws {
        let schema = try await GraphQLTypeSystem.loading(schemaFile: Data(GraphQLOracle.fixtureSDL.utf8)).typeSystem

        let hits = schema.search("genre")
        let uses = Set(schema.references(to: "Genre").map(\.path))

        XCTAssertEqual(hits.first, .type("Genre"))
        XCTAssertTrue(hits.contains(.field(type: "Book", name: "genre")))
        XCTAssertTrue(hits.contains(.field(type: "NewBook", name: "genre")), "input fields too")
        XCTAssertEqual(uses, ["Book.genre", "BookFilter.genre", "NewBook.genre", "Events.bookAdded(genre:)"])
        XCTAssertEqual(Set(schema.implementations(of: "Entity").map(\.name)), ["Author", "Book"])
        XCTAssertFalse(schema.browsableTypes.contains { $0.name.hasPrefix("__") })
        XCTAssertEqual(schema.search("", limit: 3).count, 3)
    }

    // MARK: - Support

    /// Compares what introspection reports of two schemas, naming each type or directive that differs.
    private func assertDescribedAlike(
        _ actual: GraphQLSchema,
        _ expected: GraphQLSchema,
        capabilities: GraphQLIntrospection.Capabilities = .all,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let actual = try await GraphQLOracle.described(actual, capabilities: capabilities)
        let expected = try await GraphQLOracle.described(expected, capabilities: capabilities)
        for key in ["types", "directives"] {
            let actualByName = actual[key] as? [String: Any] ?? [:]
            let expectedByName = expected[key] as? [String: Any] ?? [:]
            XCTAssertEqual(Set(actualByName.keys), Set(expectedByName.keys), key, file: file, line: line)
            for (name, value) in expectedByName where (actualByName[name] as? NSDictionary) != (value as? NSDictionary) {
                XCTFail("\(key) \(name) differs:\n\(actualByName[name] ?? "missing")\nexpected:\n\(value)", file: file, line: line)
            }
        }
        let otherKeys = Set((actual.allKeys + expected.allKeys).compactMap { $0 as? String }).subtracting(["types", "directives"])
        for key in otherKeys {
            XCTAssertEqual(actual[key] as? NSObject, expected[key] as? NSObject, key, file: file, line: line)
        }
    }

    private func graphQLValidation(of query: String, against schema: GraphQLSchema) -> [String] {
        guard let document = try? parse(source: Source(body: query)) else {
            return ["unparsable"]
        }
        return validate(schema: schema, ast: document).map(\.message)
    }

    private static func withoutInputDefaults(_ typeSystem: GraphQLTypeSystem) -> GraphQLTypeSystem {
        let types = typeSystem.types.map { type in
            var type = type
            type.inputFields = type.inputFields.map { field in
                var field = field
                field.defaultValue = nil
                return field
            }
            return type
        }
        return GraphQLTypeSystem(
            description: typeSystem.description,
            rootTypes: typeSystem.rootTypes,
            types: types,
            directives: typeSystem.directives
        )
    }

    /// The fixture's introspection with `edit` applied to its `__schema` object, then decoded.
    private func editedSchema(_ edit: (inout [String: Any]) -> Void) async throws -> GraphQLTypeSystem.Decoded {
        var response = try GraphQLOracle.object(try await GraphQLOracle.introspectionResponse())
        var data = try XCTUnwrap(response["data"] as? [String: Any])
        var schema = try XCTUnwrap(data["__schema"] as? [String: Any])
        edit(&schema)
        data["__schema"] = schema
        response["data"] = data
        return try GraphQLTypeSystem.decoding(introspection: GraphQLOracle.data(response))
    }
}
