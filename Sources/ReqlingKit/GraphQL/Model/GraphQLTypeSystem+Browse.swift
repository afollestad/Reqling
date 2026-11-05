/// Finding one's way around a schema: what the schema browser and `graphql_describe_type` show beside a type.
extension GraphQLTypeSystem {
    /// How a `Reference` uses its type.
    public enum ReferenceKind: Hashable, Sendable {
        /// A field of `owner` returns it.
        case field
        /// An argument of `owner.field` takes it.
        case argument(String)
        /// An input field of `owner` takes it.
        case inputField
    }

    /// A place a type is used.
    public struct Reference: Hashable, Sendable {
        public let owner: String
        public let field: String
        public let kind: ReferenceKind

        /// `Root.books`, `Root.books(filter:)`, or `BookFilter.genre`.
        public var path: String {
            switch kind {
            case .field, .inputField: "\(owner).\(field)"
            case .argument(let argument): "\(owner).\(field)(\(argument):)"
            }
        }
    }

    /// A schema search hit: a type, or one of its fields (input fields included).
    public enum SearchHit: Hashable, Sendable {
        case type(String)
        case field(type: String, name: String)
    }

    /// The types a browser lists: all but the `__` introspection types.
    public var browsableTypes: [NamedType] {
        types.filter { !$0.name.hasPrefix("__") }
    }

    /// The object and interface types that implement `interface`.
    public func implementations(of interface: String) -> [NamedType] {
        types.filter { $0.interfaces.contains(interface) }
    }

    /// Every field, argument, and input field whose type is `typeName`, in schema order.
    public func references(to typeName: String) -> [Reference] {
        var references: [Reference] = []
        for type in browsableTypes {
            for field in type.fields {
                if field.type.namedType == typeName {
                    references.append(Reference(owner: type.name, field: field.name, kind: .field))
                }
                for arg in field.args where arg.type.namedType == typeName {
                    references.append(Reference(owner: type.name, field: field.name, kind: .argument(arg.name)))
                }
            }
            for field in type.inputFields where field.type.namedType == typeName {
                references.append(Reference(owner: type.name, field: field.name, kind: .inputField))
            }
        }
        return references
    }

    /// Types and then fields whose names match `text`, each ranked as completion ranks names
    /// (`GraphQLCompletionRanking`), at most `limit` in all.
    public func search(_ text: String, limit: Int = 200) -> [SearchHit] {
        let types = GraphQLCompletionRanking.rank(browsableTypes, by: text, name: \.name, isDeprecated: { _ in false })
            .map { SearchHit.type($0.name) }
        guard !text.isEmpty else {
            return Array(types.prefix(limit))
        }
        let fields = browsableTypes.flatMap { type in
            type.fields.map { FieldName(type: type.name, name: $0.name, isDeprecated: $0.isDeprecated) }
                + type.inputFields.map { FieldName(type: type.name, name: $0.name, isDeprecated: $0.isDeprecated) }
        }
        let fieldHits = GraphQLCompletionRanking.rank(fields, by: text, name: \.name, isDeprecated: \.isDeprecated)
            .map { SearchHit.field(type: $0.type, name: $0.name) }
        return Array((types + fieldHits).prefix(limit))
    }

    private struct FieldName {
        let type: String
        let name: String
        let isDeprecated: Bool
    }
}
