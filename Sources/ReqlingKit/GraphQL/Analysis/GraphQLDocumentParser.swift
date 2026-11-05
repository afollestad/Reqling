import Foundation

/// What a name means where it stands. Completion asks what a name typed at the cursor would be; hover asks what the
/// name under the pointer is. Types are by name, resolved against the schema as the parser goes.
enum GraphQLNameRole: Hashable, Sendable {
    /// Where a definition starts: `query`, `mutation`, `subscription`, or `fragment`.
    case definitionKeyword(operation: GraphQLTypeSystem.OperationType?)
    case operationName
    case fragmentName
    /// The `on` of `fragment Name on Type`.
    case fragmentOn
    /// A field, or an alias for one, selected on `parent` (nil when the parent is unknown).
    case field(parent: String?)
    /// An argument name; `given` holds those already written in the same list.
    case argument(GraphQLArgumentOwner?, given: Set<String>)
    case objectField(inputType: String?, given: Set<String>)
    /// An enum value, `true`, `false`, or `null` where a value of `expected` goes.
    case value(expected: GraphQLTypeRef?)
    /// The name after `$` where a value goes.
    case variable(expected: GraphQLTypeRef?)
    /// The name after `$` in an operation's variable definitions.
    case variableDefinition
    case variableType
    case directive(GraphQLTypeSystem.DirectiveLocation)
    /// After `...` in a selection set: a fragment's name, or `on`.
    case spread(parent: String?)
    /// The type after `... on`.
    case typeCondition(parent: String?)
    /// The type after `fragment Name on`.
    case fragmentTypeCondition
}

enum GraphQLArgumentOwner: Hashable, Sendable {
    case field(parent: String, name: String)
    case directive(String)
}

/// Reads a GraphQL executable document one token at a time and never fails: each token is handled by the innermost
/// construct it can belong to, and a construct a token cannot continue ends, so a half-written query still reads the
/// way it would once finished. An opening bracket nothing expects is tracked anyway, so its closer cannot end a real
/// construct early.
///
/// It also collects an outline (each operation's variables, each fragment's type condition) for completion and hover.
struct GraphQLDocumentParser: Sendable {
    struct Outline: Sendable {
        var operations: [Operation] = []
        /// Fragment names, in order, with their type conditions.
        var fragments: [(name: String, typeCondition: String?)] = []
    }

    struct Operation: Sendable {
        var type: GraphQLTypeSystem.OperationType
        var name: String?
        /// Its `query`, `mutation`, or `subscription`, or the `{` of a shorthand query.
        var keywordRange: NSRange
        var variables: [Variable] = []
    }

    struct Variable: Hashable, Sendable {
        var name: String
        var type: GraphQLTypeRef?
        var hasDefault: Bool
    }

    let typeSystem: GraphQLTypeSystem
    var stack: [Frame] = [.document]
    private(set) var outline = Outline()
    /// The operation being read, as an index into `outline.operations`; nil outside one, as in a fragment.
    private(set) var currentOperation: Int?
    /// The construct that consumed the last token, so a template can be told apart as a value or a name.
    private(set) var consumer: Frame?

    init(typeSystem: GraphQLTypeSystem) {
        self.typeSystem = typeSystem
    }

    /// Reads `token`, returning what it means when it is a name (or a template standing where a name goes).
    mutating func consume(_ token: GraphQLToken) -> GraphQLNameRole? {
        if token.kind == .comment {
            return nil
        }
        while true {
            let frame = stack.last ?? .document
            switch handle(token, in: frame) {
            case .consumed(let role):
                consumer = frame
                return role
            case .ends:
                finishTop()
                stack.removeLast()
                if stack.isEmpty {
                    stack = [.document]
                }
            }
        }
    }

    /// What a name would mean if it came next, leaving this parser as it was.
    func role(ofNameAt location: Int) -> GraphQLNameRole? {
        var copy = self
        return copy.consume(GraphQLToken(kind: .name, range: NSRange(location: location, length: 0), text: ""))
    }

    /// Records what is still open at the end of the document, such as a variable definition being typed.
    mutating func finish() {
        while stack.count > 1 {
            finishTop()
            stack.removeLast()
        }
    }

    // MARK: - Outline

    mutating func beginOperation(_ type: GraphQLTypeSystem.OperationType, at keywordRange: NSRange) {
        outline.operations.append(Operation(type: type, keywordRange: keywordRange))
        currentOperation = outline.operations.count - 1
    }

    mutating func nameOperation(_ name: String) {
        if let currentOperation {
            outline.operations[currentOperation].name = name
        }
    }

    mutating func beginFragment() {
        currentOperation = nil
    }

    mutating func recordFragment(_ name: String?, typeCondition: String?) {
        if let name {
            outline.fragments.append((name, typeCondition))
        }
    }

    /// A variable definition is recorded when it ends, once its type and default are known.
    private mutating func finishTop() {
        guard case .variableDefinition(let name?, let step) = stack.last, let currentOperation else {
            return
        }
        let (type, hasDefault): (GraphQLTypeRef?, Bool) = switch step {
        case .name, .colon: (nil, false)
        case .type(let parts): (Self.typeRef(parts), false)
        case .afterType(let type, let hasDefault): (type, hasDefault)
        }
        outline.operations[currentOperation].variables.append(Variable(name: name, type: type, hasDefault: hasDefault))
    }

    /// The type a variable definition spelled, from its tokens (`[`, a name, `]`, `!`), or nil when it is incomplete.
    static func typeRef(_ parts: [String]) -> GraphQLTypeRef? {
        var index = 0
        func parse() -> GraphQLTypeRef? {
            guard index < parts.count else {
                return nil
            }
            let part = parts[index]
            index += 1
            var type: GraphQLTypeRef
            if part == "[" {
                guard let element = parse(), index < parts.count, parts[index] == "]" else {
                    return nil
                }
                index += 1
                type = .list(element)
            } else if part == "]" || part == "!" {
                return nil
            } else {
                type = .named(part)
            }
            if index < parts.count, parts[index] == "!" {
                index += 1
                type = .nonNull(type)
            }
            return type
        }
        let type = parse()
        return index == parts.count ? type : nil
    }

    // MARK: - Schema lookups

    func rootType(_ operation: GraphQLTypeSystem.OperationType) -> String? {
        typeSystem.rootTypes[operation]
    }

    func fieldType(_ name: String?, on parent: String?) -> String? {
        guard let name, let parent else {
            return nil
        }
        return typeSystem.field(name, on: parent)?.type.namedType
    }

    func argumentType(_ name: String, of owner: GraphQLArgumentOwner?) -> GraphQLTypeRef? {
        switch owner {
        case .field(let parent, let field): typeSystem.field(field, on: parent)?.arg(name)?.type
        case .directive(let directive): typeSystem.directive(named: directive)?.args.first { $0.name == name }?.type
        case nil: nil
        }
    }

    func inputFieldType(_ name: String, of inputType: String?) -> GraphQLTypeRef? {
        inputType.flatMap { typeSystem.type(named: $0)?.inputField(name)?.type }
    }
}
