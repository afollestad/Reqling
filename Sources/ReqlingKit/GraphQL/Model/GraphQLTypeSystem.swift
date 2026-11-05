/// A GraphQL schema as introspection describes it: the types, their fields and arguments, the directives, and which
/// types are the operation roots. It is what completion, hover, the schema browser, and the MCP tools read; validation
/// prints it back to SDL for GraphQLSwift (`GraphQLDocumentValidator`).
///
/// Values keep the server's order. Built-in scalars and the `__*` introspection types are included when the server
/// reported them, as introspection always does.
public struct GraphQLTypeSystem: Hashable, Sendable {
    public enum OperationType: String, Hashable, Sendable, CaseIterable {
        case query
        case mutation
        case subscription
    }

    public enum Kind: String, Hashable, Sendable {
        case scalar = "SCALAR"
        case object = "OBJECT"
        case interface = "INTERFACE"
        case union = "UNION"
        case enumeration = "ENUM"
        case inputObject = "INPUT_OBJECT"

        /// Types a selection set can be written on.
        public var isComposite: Bool {
            self == .object || self == .interface || self == .union
        }

        /// Types an argument, variable, or input field can be.
        public var isInput: Bool {
            self == .scalar || self == .enumeration || self == .inputObject
        }
    }

    public struct NamedType: Hashable, Sendable {
        public var name: String
        public var kind: Kind
        public var description: String?
        /// Objects and interfaces.
        public var fields: [Field]
        /// Objects and interfaces: the interfaces they implement.
        public var interfaces: [String]
        /// Interfaces and unions: the object types that may appear where they do.
        public var possibleTypes: [String]
        public var enumValues: [EnumValue]
        public var inputFields: [InputValue]
        public var specifiedByURL: String?
        /// An input object that takes exactly one of its fields.
        public var isOneOf: Bool

        public init(
            name: String,
            kind: Kind,
            description: String? = nil,
            fields: [Field] = [],
            interfaces: [String] = [],
            possibleTypes: [String] = [],
            enumValues: [EnumValue] = [],
            inputFields: [InputValue] = [],
            specifiedByURL: String? = nil,
            isOneOf: Bool = false
        ) {
            self.name = name
            self.kind = kind
            self.description = description
            self.fields = fields
            self.interfaces = interfaces
            self.possibleTypes = possibleTypes
            self.enumValues = enumValues
            self.inputFields = inputFields
            self.specifiedByURL = specifiedByURL
            self.isOneOf = isOneOf
        }

        public func field(_ name: String) -> Field? {
            fields.first { $0.name == name }
        }

        public func inputField(_ name: String) -> InputValue? {
            inputFields.first { $0.name == name }
        }
    }

    public struct Field: Hashable, Sendable {
        public var name: String
        public var description: String?
        public var args: [InputValue]
        public var type: GraphQLTypeRef
        public var deprecationReason: String?

        public var isDeprecated: Bool {
            deprecationReason != nil
        }

        public init(name: String, description: String? = nil, args: [InputValue] = [], type: GraphQLTypeRef, deprecationReason: String? = nil) {
            self.name = name
            self.description = description
            self.args = args
            self.type = type
            self.deprecationReason = deprecationReason
        }

        public func arg(_ name: String) -> InputValue? {
            args.first { $0.name == name }
        }
    }

    /// An argument or an input object's field.
    public struct InputValue: Hashable, Sendable {
        public var name: String
        public var description: String?
        public var type: GraphQLTypeRef
        /// A GraphQL literal, as introspection reports it (`10`, `"a"`, `{field: TITLE}`).
        public var defaultValue: String?
        public var deprecationReason: String?

        public var isDeprecated: Bool {
            deprecationReason != nil
        }

        /// Must be given: non-null with no default.
        public var isRequired: Bool {
            type.isNonNull && defaultValue == nil
        }

        public init(name: String, description: String? = nil, type: GraphQLTypeRef, defaultValue: String? = nil, deprecationReason: String? = nil) {
            self.name = name
            self.description = description
            self.type = type
            self.defaultValue = defaultValue
            self.deprecationReason = deprecationReason
        }
    }

    public struct EnumValue: Hashable, Sendable {
        public var name: String
        public var description: String?
        public var deprecationReason: String?

        public var isDeprecated: Bool {
            deprecationReason != nil
        }

        public init(name: String, description: String? = nil, deprecationReason: String? = nil) {
            self.name = name
            self.description = description
            self.deprecationReason = deprecationReason
        }
    }

    public struct Directive: Hashable, Sendable {
        public var name: String
        public var description: String?
        public var locations: [DirectiveLocation]
        public var args: [InputValue]
        /// `nil` when the server could not say (introspection before `isRepeatable`).
        public var isRepeatable: Bool?

        public init(name: String, description: String? = nil, locations: [DirectiveLocation], args: [InputValue] = [], isRepeatable: Bool? = false) {
            self.name = name
            self.description = description
            self.locations = locations
            self.args = args
            self.isRepeatable = isRepeatable
        }
    }

    public enum DirectiveLocation: String, Hashable, Sendable, CaseIterable {
        case query = "QUERY"
        case mutation = "MUTATION"
        case subscription = "SUBSCRIPTION"
        case field = "FIELD"
        case fragmentDefinition = "FRAGMENT_DEFINITION"
        case fragmentSpread = "FRAGMENT_SPREAD"
        case inlineFragment = "INLINE_FRAGMENT"
        case variableDefinition = "VARIABLE_DEFINITION"
        case schema = "SCHEMA"
        case scalar = "SCALAR"
        case object = "OBJECT"
        case fieldDefinition = "FIELD_DEFINITION"
        case argumentDefinition = "ARGUMENT_DEFINITION"
        case interface = "INTERFACE"
        case union = "UNION"
        case enumeration = "ENUM"
        case enumValue = "ENUM_VALUE"
        case inputObject = "INPUT_OBJECT"
        case inputFieldDefinition = "INPUT_FIELD_DEFINITION"
    }

    public var description: String?
    public var rootTypes: [OperationType: String]
    public private(set) var types: [NamedType]
    public var directives: [Directive]
    private var indexByName: [String: Int]

    public init(description: String? = nil, rootTypes: [OperationType: String], types: [NamedType], directives: [Directive] = []) {
        self.description = description
        self.rootTypes = rootTypes
        // A server that repeats a name keeps its first; GraphQL forbids repeats, so a later one is noise.
        var unique: [NamedType] = []
        var index: [String: Int] = [:]
        for type in types where index[type.name] == nil {
            index[type.name] = unique.count
            unique.append(type)
        }
        self.types = unique
        indexByName = index
        self.directives = directives
    }

    public func type(named name: String) -> NamedType? {
        indexByName[name].map { types[$0] }
    }

    public func rootType(_ operation: OperationType) -> NamedType? {
        rootTypes[operation].flatMap(type(named:))
    }

    public func directive(named name: String) -> Directive? {
        directives.first { $0.name == name }
    }

    /// A field selectable on `typeName`, including the meta-fields every query may ask for: `__typename` on any
    /// composite type, and `__schema` and `__type(name:)` on the query root.
    public func field(_ name: String, on typeName: String) -> Field? {
        guard let type = type(named: typeName), type.kind.isComposite else {
            return nil
        }
        if name == "__typename" {
            return Self.typenameField
        }
        if typeName == rootTypes[.query] {
            if name == "__schema" {
                return Self.schemaField
            }
            if name == "__type" {
                return Self.typeField
            }
        }
        return type.field(name)
    }

    /// Every field selectable on `typeName`: its own, then the meta-fields `field(_:on:)` also answers.
    public func selectableFields(on typeName: String) -> [Field] {
        guard let type = type(named: typeName), type.kind.isComposite else {
            return []
        }
        var fields = type.fields
        if typeName == rootTypes[.query] {
            fields += [Self.schemaField, Self.typeField]
        }
        fields.append(Self.typenameField)
        return fields
    }

    /// The object types a value of `typeName` can be at runtime: itself for an object, its possible types otherwise.
    public func possibleObjectTypes(of typeName: String) -> [String] {
        guard let type = type(named: typeName) else {
            return []
        }
        return type.kind == .object ? [type.name] : type.possibleTypes
    }

    static let typenameField = Field(name: "__typename", description: "The name of the current object type.", type: .nonNull(.named("String")))
    static let schemaField = Field(name: "__schema", description: "The schema's own description.", type: .nonNull(.named("__Schema")))
    static let typeField = Field(
        name: "__type",
        description: "One type of the schema, by name.",
        args: [InputValue(name: "name", type: .nonNull(.named("String")))],
        type: .named("__Type")
    )
}
