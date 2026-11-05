import Foundation
@_implementationOnly import GraphQL

/// One problem GraphQLSwift found in a document, with UTF-16 ranges into the text it checked.
public struct GraphQLEngineProblem: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case syntax
        /// A spec validation rule failed.
        case invalid
        /// The document uses something deprecated (`NoDeprecatedCustomRule`).
        case deprecated
    }

    public let kind: Kind
    public let message: String
    /// The nodes it names, each narrowed to its name where it has one (`nmae` in `nmae { id }`).
    public let ranges: [NSRange]
    /// Where it points when it names no node, as a syntax error does.
    public let positions: [Int]
}

/// Checks documents against one schema: syntax, every spec validation rule GraphQLSwift implements, and use of
/// deprecated elements. Building the schema is the costly part, so build one per schema and reuse it.
///
/// The schema is captured in a closure rather than stored, so no GraphQLSwift type appears in this module's interface.
public struct GraphQLDocumentChecker: Sendable {
    private let check: @Sendable (String) -> [GraphQLEngineProblem]

    /// Syntax only, for a document with no schema to check it against.
    public static let syntaxOnly = GraphQLDocumentChecker { document in
        switch parsed(document) {
        case .document: []
        case .problem(let problem): [problem]
        }
    }

    private init(check: @escaping @Sendable (String) -> [GraphQLEngineProblem]) {
        self.check = check
    }

    /// Builds a checker from SDL, trusting it: a schema read from a server is what the server runs, even where it
    /// would fail SDL validation, and `assumeValid` also settles `validateSchema`'s cache before any check can race to
    /// fill it.
    public init(sdl: String) throws(GraphQLEngineError) {
        let schema: GraphQLSchema
        do {
            schema = try buildSchema(source: sdl, assumeValid: true, assumeValidSDL: true)
        } catch {
            throw GraphQLEngineError(GraphQLEngine.describe(error, in: sdl))
        }
        check = { document in
            let ast: Document
            switch Self.parsed(document) {
            case .document(let parsed): ast = parsed
            case .problem(let problem): return [problem]
            }
            let invalid = validate(schema: schema, ast: ast).map { Self.problem($0, kind: .invalid, in: document) }
            let deprecated = validate(schema: schema, ast: ast, rules: [NoDeprecatedCustomRule])
                .map { Self.problem($0, kind: .deprecated, in: document) }
            return invalid + deprecated
        }
    }

    public func problems(in document: String) -> [GraphQLEngineProblem] {
        check(document)
    }

    @_implementationOnly private enum Parsed {
        case document(Document)
        case problem(GraphQLEngineProblem)
    }

    private static func parsed(_ document: String) -> Parsed {
        do {
            return .document(try parse(source: Source(body: document)))
        } catch {
            let graphQLError = error as? GraphQLError
            return .problem(GraphQLEngineProblem(
                kind: .syntax,
                message: GraphQLEngine.cleanMessage(graphQLError?.message ?? error.localizedDescription),
                ranges: [],
                positions: (graphQLError?.positions ?? []).map { GraphQLEngine.utf16Offset(ofUTF8Offset: $0, in: document) }
            ))
        }
    }

    private static func problem(_ error: GraphQLError, kind: GraphQLEngineProblem.Kind, in document: String) -> GraphQLEngineProblem {
        let ranges = error.nodes.compactMap { node in
            narrowed(node).map { span in
                let start = GraphQLEngine.utf16Offset(ofUTF8Offset: span.start, in: document)
                let end = GraphQLEngine.utf16Offset(ofUTF8Offset: span.end, in: document)
                return NSRange(location: start, length: max(0, end - start))
            }
        }
        return GraphQLEngineProblem(
            kind: kind,
            message: GraphQLEngine.cleanMessage(error.message),
            ranges: ranges,
            positions: error.positions.map { GraphQLEngine.utf16Offset(ofUTF8Offset: $0, in: document) }
        )
    }

    /// The part of a node a problem should mark, in UTF-8 offsets: its name where it has one, rather than the whole
    /// field, argument, or definition with everything inside it.
    ///
    /// GraphQLSwift's parser takes a named type's and a variable's location before reading their name, so those end
    /// after their first character; their name's location is whole.
    private static func narrowed(_ node: any Node) -> (start: Int, end: Int)? {
        if let variable = node as? Variable ?? (node as? VariableDefinition)?.variable {
            return variable.loc.map { ($0.start, max($0.end, variable.name.loc?.end ?? $0.end)) }
        }
        let location: Location? = switch node {
        case let field as Field: field.name.loc
        case let argument as Argument: argument.name.loc
        case let directive as GraphQL.Directive: directive.name.loc
        case let spread as FragmentSpread: spread.name.loc
        case let fragment as InlineFragment: fragment.typeCondition?.name.loc
        case let fragment as FragmentDefinition: fragment.name.loc
        case let operation as OperationDefinition: operation.name?.loc
        case let field as ObjectField: field.name.loc
        case let type as NamedType: type.name.loc
        case is SelectionSet: nil
        default: node.loc
        }
        if let location {
            return (location.start, location.end)
        }
        // Nothing to name it by: its first token, such as an anonymous operation's `query` or a selection's `{`.
        return node.loc.map { ($0.startToken.start, $0.startToken.end) }
    }
}
