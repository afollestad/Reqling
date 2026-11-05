import Foundation

/// The constructs the parser can be inside, and how each takes the next token: it either consumes the token, or ends
/// so the construct around it can try.
extension GraphQLDocumentParser {
    enum Frame: Hashable, Sendable {
        case document
        case operationHeader(location: GraphQLTypeSystem.DirectiveLocation, root: String?, named: Bool)
        case fragmentHeader(FragmentStep)
        case variableDefinitions
        case variableDefinition(name: String?, step: VariableStep)
        case selectionSet(parent: String?)
        /// `name` is nil after an alias's colon, until the field's own name comes.
        case field(parent: String?, name: String?, expectsName: Bool)
        case arguments(owner: GraphQLArgumentOwner?, given: Set<String>)
        case argument(owner: GraphQLArgumentOwner?, name: String, expectsColon: Bool)
        case value(expected: GraphQLTypeRef?, afterDollar: Bool)
        case list(element: GraphQLTypeRef?)
        case object(inputType: String?, given: Set<String>)
        case objectField(inputType: String?, name: String, expectsColon: Bool)
        case directive(location: GraphQLTypeSystem.DirectiveLocation, named: String?)
        case spread(parent: String?, step: SpreadStep)
        /// An opening bracket nothing expected, waiting for its closer.
        case brackets(closer: String)
    }

    enum FragmentStep: Hashable, Sendable {
        case name
        case onKeyword(name: String?)
        case type(name: String?)
        case body(type: String?)
    }

    enum VariableStep: Hashable, Sendable {
        case name
        case colon
        /// The type's tokens so far.
        case type([String])
        case afterType(GraphQLTypeRef?, hasDefault: Bool)
    }

    enum SpreadStep: Hashable, Sendable {
        case start
        /// After `on`, waiting for the type.
        case condition
        case inlineFragment(type: String?)
        case fragmentSpread
    }

    enum Outcome {
        case consumed(GraphQLNameRole?)
        /// The frame cannot continue with this token; it ends and its parent tries.
        case ends
    }

    mutating func handle(_ token: GraphQLToken, in frame: Frame) -> Outcome {
        switch frame {
        case .document: document(token)
        case .operationHeader(let location, let root, let named): operationHeader(token, location: location, root: root, named: named)
        case .fragmentHeader(let step): fragmentHeader(token, step: step)
        case .variableDefinitions: variableDefinitions(token)
        case .variableDefinition(let name, let step): variableDefinition(token, name: name, step: step)
        case .selectionSet(let parent): selectionSet(token, parent: parent)
        case .field(let parent, let name, let expectsName): field(token, parent: parent, name: name, expectsName: expectsName)
        case .arguments(let owner, let given): arguments(token, owner: owner, given: given)
        case .argument(let owner, let name, let expectsColon): argument(token, owner: owner, name: name, expectsColon: expectsColon)
        case .value(let expected, let afterDollar): value(token, expected: expected, afterDollar: afterDollar)
        case .list(let element): list(token, element: element)
        case .object(let inputType, let given): object(token, inputType: inputType, given: given)
        case .objectField(let inputType, let name, let expectsColon): objectField(token, inputType: inputType, name: name, expectsColon: expectsColon)
        case .directive(let location, let name): directive(token, location: location, named: name)
        case .spread(let parent, let step): spread(token, parent: parent, step: step)
        case .brackets(let closer): brackets(token, closer: closer)
        }
    }

    mutating func replaceTop(with frame: Frame) {
        stack[stack.count - 1] = frame
    }

    mutating func push(_ frame: Frame) -> Outcome {
        stack.append(frame)
        return .consumed(nil)
    }

    /// A name, or a template standing where one goes.
    static func isName(_ token: GraphQLToken) -> Bool {
        token.kind == .name || token.kind == .template
    }

    /// A name's text; nil for a template, whose name is unknown until it resolves.
    static func nameText(_ token: GraphQLToken) -> String? {
        token.kind == .name && !token.text.isEmpty ? token.text : nil
    }

    private static func isTypePunctuator(_ token: GraphQLToken) -> Bool {
        token.isPunctuator("[") || token.isPunctuator("]") || token.isPunctuator("!")
    }

    // MARK: - Definitions

    private mutating func document(_ token: GraphQLToken) -> Outcome {
        if token.isPunctuator("{") {
            beginOperation(.query, at: token.range)
            return push(.selectionSet(parent: rootType(.query)))
        }
        guard token.kind == .name else {
            return .consumed(nil)
        }
        if let operation = GraphQLTypeSystem.OperationType(rawValue: token.text) {
            beginOperation(operation, at: token.range)
            let location: GraphQLTypeSystem.DirectiveLocation = switch operation {
            case .query: .query
            case .mutation: .mutation
            case .subscription: .subscription
            }
            stack.append(.operationHeader(location: location, root: rootType(operation), named: false))
            return .consumed(.definitionKeyword(operation: operation))
        }
        if token.text == "fragment" {
            beginFragment()
            stack.append(.fragmentHeader(.name))
        }
        return .consumed(.definitionKeyword(operation: nil))
    }

    private mutating func operationHeader(
        _ token: GraphQLToken,
        location: GraphQLTypeSystem.DirectiveLocation,
        root: String?,
        named: Bool
    ) -> Outcome {
        if Self.isName(token), !named {
            replaceTop(with: .operationHeader(location: location, root: root, named: true))
            Self.nameText(token).map { nameOperation($0) }
            return .consumed(.operationName)
        }
        switch token.kind == .punctuator ? token.text : "" {
        case "(": return push(.variableDefinitions)
        case "@": return push(.directive(location: location, named: nil))
        case "{":
            replaceTop(with: .selectionSet(parent: root))
            return .consumed(nil)
        default: return .ends
        }
    }

    private mutating func fragmentHeader(_ token: GraphQLToken, step: FragmentStep) -> Outcome {
        switch step {
        case .name where Self.isName(token):
            replaceTop(with: .fragmentHeader(.onKeyword(name: Self.nameText(token))))
            return .consumed(.fragmentName)
        case .onKeyword(let name) where Self.isName(token):
            replaceTop(with: .fragmentHeader(.type(name: name)))
            return .consumed(.fragmentOn)
        case .type(let name) where Self.isName(token):
            recordFragment(name, typeCondition: Self.nameText(token))
            replaceTop(with: .fragmentHeader(.body(type: Self.nameText(token))))
            return .consumed(.fragmentTypeCondition)
        default:
            break
        }
        if token.isPunctuator("@") {
            return push(.directive(location: .fragmentDefinition, named: nil))
        }
        if token.isPunctuator("{") {
            if case .body(let type) = step {
                replaceTop(with: .selectionSet(parent: type))
            } else {
                replaceTop(with: .selectionSet(parent: nil))
            }
            return .consumed(nil)
        }
        return .ends
    }

    private mutating func variableDefinitions(_ token: GraphQLToken) -> Outcome {
        if token.isPunctuator("$") {
            return push(.variableDefinition(name: nil, step: .name))
        }
        if token.isPunctuator(")") {
            stack.removeLast()
            return .consumed(nil)
        }
        if token.isPunctuator("{") || token.isPunctuator("}") {
            return .ends
        }
        return .consumed(nil)
    }

    private mutating func variableDefinition(_ token: GraphQLToken, name: String?, step: VariableStep) -> Outcome {
        switch step {
        case .name where Self.isName(token):
            replaceTop(with: .variableDefinition(name: Self.nameText(token), step: .colon))
            return .consumed(.variableDefinition)
        case .colon where token.isPunctuator(":"):
            replaceTop(with: .variableDefinition(name: name, step: .type([])))
            return .consumed(nil)
        case .type(let parts) where Self.isName(token) || Self.isTypePunctuator(token):
            // A template's type is unknown; "?" keeps the parts well-formed without naming a real type.
            let part = token.kind == .template ? "?" : token.text
            replaceTop(with: .variableDefinition(name: name, step: .type(parts + [part])))
            return .consumed(Self.isName(token) ? .variableType : nil)
        default:
            break
        }
        let type: GraphQLTypeRef?
        var hasDefault = false
        switch step {
        case .type(let parts): type = Self.typeRef(parts)
        case .afterType(let known, let defaulted): (type, hasDefault) = (known, defaulted)
        case .name, .colon: return .ends
        }
        if token.isPunctuator("=") {
            replaceTop(with: .variableDefinition(name: name, step: .afterType(type, hasDefault: true)))
            return push(.value(expected: type, afterDollar: false))
        }
        if token.isPunctuator("@") {
            replaceTop(with: .variableDefinition(name: name, step: .afterType(type, hasDefault: hasDefault)))
            return push(.directive(location: .variableDefinition, named: nil))
        }
        return .ends
    }

    // MARK: - Selections

    private mutating func selectionSet(_ token: GraphQLToken, parent: String?) -> Outcome {
        if Self.isName(token) {
            stack.append(.field(parent: parent, name: Self.nameText(token), expectsName: false))
            return .consumed(.field(parent: parent))
        }
        if token.kind == .spread {
            return push(.spread(parent: parent, step: .start))
        }
        switch token.kind == .punctuator ? token.text : "" {
        case "}":
            stack.removeLast()
            return .consumed(nil)
        case "{": return push(.selectionSet(parent: nil))
        case "(": return push(.brackets(closer: ")"))
        case "[": return push(.brackets(closer: "]"))
        default: return .consumed(nil)
        }
    }

    private mutating func field(_ token: GraphQLToken, parent: String?, name: String?, expectsName: Bool) -> Outcome {
        if expectsName, Self.isName(token) {
            replaceTop(with: .field(parent: parent, name: Self.nameText(token), expectsName: false))
            return .consumed(.field(parent: parent))
        }
        switch token.kind == .punctuator ? token.text : "" {
        case ":" where !expectsName:
            replaceTop(with: .field(parent: parent, name: nil, expectsName: true))
            return .consumed(nil)
        case "(":
            let owner = parent.flatMap { parent in name.map { GraphQLArgumentOwner.field(parent: parent, name: $0) } }
            return push(.arguments(owner: owner, given: []))
        case "@":
            return push(.directive(location: .field, named: nil))
        case "{":
            replaceTop(with: .selectionSet(parent: fieldType(name, on: parent)))
            return .consumed(nil)
        default:
            return .ends
        }
    }

    private mutating func spread(_ token: GraphQLToken, parent: String?, step: SpreadStep) -> Outcome {
        switch step {
        case .start where Self.isName(token):
            replaceTop(with: .spread(parent: parent, step: token.text == "on" ? .condition : .fragmentSpread))
            return .consumed(.spread(parent: parent))
        case .condition where Self.isName(token):
            replaceTop(with: .spread(parent: parent, step: .inlineFragment(type: Self.nameText(token))))
            return .consumed(.typeCondition(parent: parent))
        default:
            break
        }
        let conditionType: String? = switch step {
        case .inlineFragment(let type): type
        case .start, .condition: parent
        case .fragmentSpread: nil
        }
        if token.isPunctuator("@") {
            if step == .fragmentSpread {
                return push(.directive(location: .fragmentSpread, named: nil))
            }
            replaceTop(with: .spread(parent: parent, step: .inlineFragment(type: conditionType)))
            return push(.directive(location: .inlineFragment, named: nil))
        }
        if token.isPunctuator("{"), step != .fragmentSpread {
            replaceTop(with: .selectionSet(parent: conditionType))
            return .consumed(nil)
        }
        return .ends
    }

    private mutating func directive(_ token: GraphQLToken, location: GraphQLTypeSystem.DirectiveLocation, named: String?) -> Outcome {
        if named == nil, Self.isName(token) {
            replaceTop(with: .directive(location: location, named: Self.nameText(token) ?? ""))
            return .consumed(.directive(location))
        }
        if let named, token.isPunctuator("(") {
            replaceTop(with: .arguments(owner: named.isEmpty ? nil : .directive(named), given: []))
            return .consumed(nil)
        }
        return .ends
    }

    private mutating func brackets(_ token: GraphQLToken, closer: String) -> Outcome {
        guard token.kind == .punctuator else {
            return .consumed(nil)
        }
        switch token.text {
        case closer:
            stack.removeLast()
            return .consumed(nil)
        case "{": return push(.brackets(closer: "}"))
        case "(": return push(.brackets(closer: ")"))
        case "[": return push(.brackets(closer: "]"))
        case "}", ")", "]": return .ends
        default: return .consumed(nil)
        }
    }
}
