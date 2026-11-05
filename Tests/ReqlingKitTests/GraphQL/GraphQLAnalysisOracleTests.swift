import Foundation
import GraphQL
import Synchronization
import XCTest

@testable import ReqlingKit

/// Completion and the parser's reading of a document, checked against GraphQLSwift over a corpus of queries it
/// validates: every name in a valid query must be one completion would have offered there, and the parser must place
/// each name where GraphQLSwift's own TypeInfo does.
final class GraphQLAnalysisOracleTests: XCTestCase {
    private var schema: GraphQLTypeSystem!
    private var oracleSchema: GraphQLSchema!

    /// ASCII only, so GraphQLSwift's UTF-8 positions and the parser's UTF-16 ones agree.
    static let corpus = [
        """
        query Library($id: ID!, $first: Int = 5, $genre: Genre, $show: Boolean!) @tag(name: "q") {
          node(id: $id) { id ... on Book { title } ...AuthorParts }
          books(filter: { genre: $genre, and: [{ titleContains: "x" }] }, order: { field: TITLE, direction: DESC }, first: $first) {
            heading: title
            genre
            shelves
            author @include(if: $show) { name books(orderBy: { field: CREATED_AT }) { isbn } }
          }
          search(text: "le guin", limit: 3) { __typename ... on Author { name } ... on Book { title on type fragment } }
          me { ...AuthorParts nickname }
        }
        fragment AuthorParts on Author { id name createdAt }
        """,
        """
        mutation AddBook($title: String!) {
          addBook(input: { title: $title, authorID: "author-1", genre: POETRY, tags: ["a", "b"] }) { id title }
          removeBook(id: "book-2")
        }
        """,
        "subscription { bookAdded(genre: FICTION) { id author { name } } }",
        "{ ping __schema { queryType { name } types { name kind } } book(lookup: { isbn: \"x\" }) { title } }",
        "query ($v: [ID!]) { books(filter: { authorIDs: $v }) { id } }",
        "query { me { ... @tag(name: \"x\") { id } ...Names @tag(name: \"y\") } } fragment Names on Author { name }",
        "query Deprecated { books(legacyPage: 2) { genre } }",
        "query V($x: Int @tag(name: \"v\")) { books(first: $x) @skip(if: false) { id } }"
    ]

    override func setUp() async throws {
        try await super.setUp()
        schema = try await GraphQLOracle.decoded().typeSystem
        oracleSchema = try GraphQLOracle.schema()
    }

    func testTheCorpusIsValidAndASCII() throws {
        for query in Self.corpus {
            let errors = validate(schema: oracleSchema, ast: try parse(source: Source(body: query)))

            XCTAssertEqual(errors.map(\.message), [], query)
            XCTAssertTrue(query.allSatisfy(\.isASCII), query)
        }
    }

    /// Completing at the end of every name, in the whole query and in the query cut there, offers that name.
    func testCompletionOffersEveryNameAValidQueryUses() {
        for query in Self.corpus {
            for (token, role) in roles(in: query, includingAliases: false) where Self.isSchemaName(role) {
                let expected = Self.isVariable(role) ? "$" + token.text : token.text
                let whole = GraphQLDocumentAnalyzer(text: query, typeSystem: schema).completions(at: token.end)
                let cut = GraphQLDocumentAnalyzer(text: String((query.utf16.prefix(token.end))) ?? "", typeSystem: schema).completions(at: token.end)

                XCTAssertTrue(whole?.items.contains { $0.insertText == expected } == true, "\(expected) at \(token.end) of \(query)")
                // A cut query loses the fragments defined after the cut, so only the whole one can offer them.
                if case .spread = role, token.text != "on" {
                    continue
                }
                XCTAssertTrue(cut?.items.contains { $0.insertText == expected } == true, "\(expected) at the end of a cut \(query)")
            }
        }
    }

    /// Every prefix of every query, and seeded corruptions of them, analyze without trapping: queries are typed one
    /// character at a time, and pasted in any state.
    func testAnyPrefixOrCorruptionAnalyzesWithoutTrapping() {
        var random = SeededRandom(seed: 0x5EED)
        let alphabet = Array("{}()[]:$@.\" \n#abcxyz!=,{{}}")
        for query in Self.corpus {
            let units = Array(query.utf16)
            for length in 0...units.count {
                analyze(String(decoding: units.prefix(length), as: UTF16.self))
            }
            for _ in 0..<60 {
                var characters = Array(query)
                for _ in 0..<Int.random(in: 1...6, using: &random) {
                    let index = Int.random(in: 0..<characters.count, using: &random)
                    if Bool.random(using: &random) {
                        characters.remove(at: index)
                    } else {
                        characters.insert(alphabet.randomElement(using: &random) ?? " ", at: index)
                    }
                }
                analyze(String(characters))
            }
        }
    }

    /// The parser's parent types, argument owners, input types, and directives match GraphQLSwift's TypeInfo at every
    /// field, argument, input field, enum value, and directive of the corpus.
    func testTheParserPlacesEveryNameWhereGraphQLSwiftDoes() throws {
        for query in Self.corpus {
            let expected = try typeInfo(for: query)
            // GraphQLSwift places an aliased field at its alias.
            let named = roles(in: query, includingAliases: true).map { ($0.token.range.location, $0.role) }
            let ours = Dictionary(named, uniquingKeysWith: { first, _ in first })
            XCTAssertFalse(expected.isEmpty)
            for probe in expected {
                let role = ours[probe.offset]
                switch probe.kind {
                case .field:
                    XCTAssertEqual(role, .field(parent: probe.parentType), "field at \(probe.offset) of \(query)")
                case .argument:
                    guard case .argument(let owner, _) = role else {
                        XCTFail("argument at \(probe.offset): \(String(describing: role))")
                        continue
                    }
                    XCTAssertEqual(owner, probe.argumentOwner, "argument at \(probe.offset) of \(query)")
                case .objectField:
                    guard case .objectField(let inputType, _) = role else {
                        XCTFail("input field at \(probe.offset): \(String(describing: role))")
                        continue
                    }
                    XCTAssertEqual(inputType, probe.parentInputType, "input field at \(probe.offset) of \(query)")
                case .enumValue:
                    guard case .value(let expected) = role else {
                        XCTFail("enum value at \(probe.offset): \(String(describing: role))")
                        continue
                    }
                    XCTAssertEqual(expected?.namedType, probe.inputType, "enum value at \(probe.offset) of \(query)")
                case .directive:
                    let nameOffset = probe.offset + 1
                    guard case .directive = ours[nameOffset] else {
                        XCTFail("directive at \(probe.offset): \(String(describing: ours[nameOffset]))")
                        continue
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: - Support

    private func analyze(_ text: String) {
        let analyzer = GraphQLDocumentAnalyzer(text: text, typeSystem: schema)
        let length = text.utf16.count
        for offset in stride(from: 0, through: length, by: max(1, length / 12)) {
            _ = analyzer.completions(at: offset)
            _ = analyzer.hover(at: offset)
        }
        _ = try? validate(schema: oracleSchema, ast: parse(source: Source(body: text)))
    }

    /// Each name in `query` with the role the parser gives it.
    private func roles(in query: String, includingAliases: Bool) -> [(token: GraphQLToken, role: GraphQLNameRole)] {
        var parser = GraphQLDocumentParser(typeSystem: schema)
        let tokens = GraphQLLexer.tokens(in: query)
        var roles: [(GraphQLToken, GraphQLNameRole)] = []
        for (index, token) in tokens.enumerated() {
            guard let role = parser.consume(token), token.kind == .name else {
                continue
            }
            // An alias is a name the query chooses, not one the schema has.
            let isAlias = index + 1 < tokens.count && tokens[index + 1].isPunctuator(":") && { if case .field = role { true } else { false } }()
            if includingAliases || !isAlias {
                roles.append((token, role))
            }
        }
        return roles
    }

    private static func isSchemaName(_ role: GraphQLNameRole) -> Bool {
        switch role {
        case .operationName, .fragmentName, .variableDefinition: false
        default: true
        }
    }

    private static func isVariable(_ role: GraphQLNameRole) -> Bool {
        if case .variable = role {
            return true
        }
        return false
    }

    private struct Probe {
        let kind: Kind
        let offset: Int
        let parentType: String?
        let argumentOwner: GraphQLArgumentOwner?
        let inputType: String?
        let parentInputType: String?
    }

    /// What GraphQLSwift's TypeInfo knows at each node, recorded by a validation rule that reports nothing.
    private func typeInfo(for query: String) throws -> [Probe] {
        let probes = Mutex<[Probe]>([])
        let rule: @Sendable (ValidationContext) -> Visitor = { context in
            Visitor(enter: { node, _, _, _, _ in
                guard let offset = node.loc?.start, [.field, .argument, .objectField, .enumValue, .directive].contains(node.kind) else {
                    return .continue
                }
                let owner: GraphQLArgumentOwner? = if let directive = context.directive {
                    .directive(directive.name)
                } else if let field = context.fieldDef, let parent = context.parentType {
                    .field(parent: parent.name, name: field.name)
                } else {
                    nil
                }
                probes.withLock {
                    $0.append(Probe(
                        kind: node.kind,
                        offset: offset,
                        parentType: context.parentType?.name,
                        argumentOwner: owner,
                        inputType: Self.namedType(context.inputType),
                        parentInputType: Self.namedType(context.parentInputType)
                    ))
                }
                return .continue
            })
        }
        _ = validate(schema: oracleSchema, ast: try parse(source: Source(body: query)), rules: [rule])
        return probes.withLock { $0 }
    }

    private static func namedType(_ type: (any GraphQLType)?) -> String? {
        switch type {
        case let wrapped as GraphQLNonNull: namedType(wrapped.ofType)
        case let wrapped as GraphQLList: namedType(wrapped.ofType)
        case let named as GraphQLNamedType: named.name
        default: nil
        }
    }
}

/// SplitMix64: the same corruptions on every run.
private struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
