import Foundation

/// One suggestion for what to type at the cursor.
public struct GraphQLCompletionItem: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case field
        case argument
        case inputField
        case enumValue
        case variable
        case directive
        case type
        case fragment
        case keyword
    }

    public let label: String
    public let kind: Kind
    /// The type it has or takes, or what a fragment or keyword applies to.
    public let detail: String?
    public let documentation: String?
    public let isDeprecated: Bool
    /// What accepting it puts in place of the list's `replacementRange`.
    public let insertText: String
    /// What typed text is matched against: the label, less a variable's `$`.
    let filterText: String

    init(label: String, kind: Kind, detail: String? = nil, documentation: String? = nil, isDeprecated: Bool = false, filterText: String? = nil) {
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.isDeprecated = isDeprecated
        insertText = label
        self.filterText = filterText ?? label
    }
}

/// What may be typed at the cursor, ranked by what is already typed there.
public struct GraphQLCompletionList: Hashable, Sendable {
    /// What an accepted item replaces: the whole name the cursor is in, or an empty range at the cursor.
    public let replacementRange: NSRange
    public let items: [GraphQLCompletionItem]
}

/// The candidates for each kind of name, before ranking.
struct GraphQLCompletionCandidates {
    let typeSystem: GraphQLTypeSystem
    let outline: GraphQLDocumentParser.Outline
    let operation: Int?

    func items(for role: GraphQLNameRole) -> [GraphQLCompletionItem] {
        switch role {
        case .definitionKeyword: definitionKeywords()
        case .operationName, .fragmentName, .variableDefinition: []
        case .fragmentOn: [GraphQLCompletionItem(label: "on", kind: .keyword)]
        case .field(let parent): parent.map(fields(on:)) ?? []
        case .argument(let owner, let given): arguments(of: owner).filter { !given.contains($0.label) }
        case .objectField(let inputType, let given): inputFields(of: inputType).filter { !given.contains($0.label) }
        case .value(let expected): values(for: expected)
        case .variable(let expected): variables(for: expected)
        case .variableType: types { $0.kind.isInput }
        case .directive(let location): directives(at: location)
        case .spread(let parent): [GraphQLCompletionItem(label: "on", kind: .keyword, detail: "inline fragment")] + fragments(within: parent)
        case .typeCondition(let parent): types { $0.kind.isComposite && overlaps($0.name, parent) }
        case .fragmentTypeCondition: types { $0.kind.isComposite }
        }
    }

    private func definitionKeywords() -> [GraphQLCompletionItem] {
        var keywords = ["query"]
        if typeSystem.rootTypes[.mutation] != nil {
            keywords.append("mutation")
        }
        if typeSystem.rootTypes[.subscription] != nil {
            keywords.append("subscription")
        }
        return (keywords + ["fragment"]).map { GraphQLCompletionItem(label: $0, kind: .keyword) }
    }

    private func fields(on parent: String) -> [GraphQLCompletionItem] {
        typeSystem.selectableFields(on: parent).map { field in
            GraphQLCompletionItem(
                label: field.name,
                kind: .field,
                detail: field.type.description,
                documentation: field.description,
                isDeprecated: field.isDeprecated
            )
        }
    }

    private func arguments(of owner: GraphQLArgumentOwner?) -> [GraphQLCompletionItem] {
        let args: [GraphQLTypeSystem.InputValue] = switch owner {
        case .field(let parent, let name): typeSystem.field(name, on: parent)?.args ?? []
        case .directive(let name): typeSystem.directive(named: name)?.args ?? []
        case nil: []
        }
        return args.map { inputValueItem($0, kind: .argument) }
    }

    private func inputFields(of inputType: String?) -> [GraphQLCompletionItem] {
        (inputType.flatMap { typeSystem.type(named: $0)?.inputFields } ?? []).map { inputValueItem($0, kind: .inputField) }
    }

    private func inputValueItem(_ value: GraphQLTypeSystem.InputValue, kind: GraphQLCompletionItem.Kind) -> GraphQLCompletionItem {
        GraphQLCompletionItem(
            label: value.name,
            kind: kind,
            detail: value.type.description + (value.defaultValue.map { " = \($0)" } ?? ""),
            documentation: value.description,
            isDeprecated: value.isDeprecated
        )
    }

    /// Enum values, `true` and `false`, `null` where it is allowed, then variables that fit.
    private func values(for expected: GraphQLTypeRef?) -> [GraphQLCompletionItem] {
        guard let expected else {
            return []
        }
        var items: [GraphQLCompletionItem] = []
        let type = typeSystem.type(named: expected.namedType)
        if type?.kind == .enumeration {
            items += type?.enumValues.map { value in
                GraphQLCompletionItem(
                    label: value.name,
                    kind: .enumValue,
                    detail: expected.namedType,
                    documentation: value.description,
                    isDeprecated: value.isDeprecated
                )
            } ?? []
        }
        if expected.namedType == "Boolean" {
            items += ["true", "false"].map { GraphQLCompletionItem(label: $0, kind: .keyword, detail: "Boolean") }
        }
        if !expected.isNonNull {
            items.append(GraphQLCompletionItem(label: "null", kind: .keyword))
        }
        return items + variables(for: expected)
    }

    /// The current operation's variables that may be passed where `expected` goes (all of them when that is unknown).
    private func variables(for expected: GraphQLTypeRef?) -> [GraphQLCompletionItem] {
        guard let operation, operation < outline.operations.count else {
            return []
        }
        return outline.operations[operation].variables.compactMap { variable in
            if let expected, let type = variable.type, !type.canBePassed(to: expected, hasDefault: variable.hasDefault) {
                return nil
            }
            return GraphQLCompletionItem(label: "$" + variable.name, kind: .variable, detail: variable.type?.description, filterText: variable.name)
        }
    }

    private func directives(at location: GraphQLTypeSystem.DirectiveLocation) -> [GraphQLCompletionItem] {
        typeSystem.directives.filter { $0.locations.contains(location) }.map { directive in
            let args = directive.args.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
            return GraphQLCompletionItem(
                label: directive.name,
                kind: .directive,
                detail: args.isEmpty ? nil : "(\(args))",
                documentation: directive.description
            )
        }
    }

    private func fragments(within parent: String?) -> [GraphQLCompletionItem] {
        outline.fragments.compactMap { fragment in
            guard let condition = fragment.typeCondition, overlaps(condition, parent) else {
                return nil
            }
            return GraphQLCompletionItem(label: fragment.name, kind: .fragment, detail: "on \(condition)")
        }
    }

    private func types(where include: (GraphQLTypeSystem.NamedType) -> Bool) -> [GraphQLCompletionItem] {
        typeSystem.types.filter { !$0.name.hasPrefix("__") && include($0) }.map { type in
            GraphQLCompletionItem(label: type.name, kind: .type, detail: type.kind.keyword, documentation: type.description)
        }
    }

    /// Whether a value of `type` can be a value of `parent` too: they share an object type. An unknown parent allows
    /// anything.
    private func overlaps(_ type: String, _ parent: String?) -> Bool {
        guard let parent else {
            return true
        }
        let parentTypes = Set(typeSystem.possibleObjectTypes(of: parent))
        return !parentTypes.isDisjoint(with: typeSystem.possibleObjectTypes(of: type))
    }
}

extension GraphQLTypeSystem.Kind {
    /// The SDL keyword that declares a type of this kind.
    public var keyword: String {
        switch self {
        case .scalar: "scalar"
        case .object: "type"
        case .interface: "interface"
        case .union: "union"
        case .enumeration: "enum"
        case .inputObject: "input"
        }
    }
}
