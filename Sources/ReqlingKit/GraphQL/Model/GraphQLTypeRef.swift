/// A reference to a type as GraphQL writes it: a named type, wrapped in any nesting of lists and non-null markers.
public indirect enum GraphQLTypeRef: Hashable, Sendable, CustomStringConvertible {
    case named(String)
    case list(GraphQLTypeRef)
    case nonNull(GraphQLTypeRef)

    /// The type at the core of the wrappers.
    public var namedType: String {
        switch self {
        case .named(let name): name
        case .list(let inner), .nonNull(let inner): inner.namedType
        }
    }

    public var isNonNull: Bool {
        if case .nonNull = self {
            return true
        }
        return false
    }

    /// The same type without its outermost non-null marker.
    public var nullable: GraphQLTypeRef {
        if case .nonNull(let inner) = self {
            return inner
        }
        return self
    }

    /// The element type of a list, or nil when this is not one (non-null or not).
    public var listElement: GraphQLTypeRef? {
        if case .list(let element) = nullable {
            return element
        }
        return nil
    }

    /// GraphQL's own spelling, such as `[User!]!`.
    public var description: String {
        switch self {
        case .named(let name): name
        case .list(let inner): "[\(inner)]"
        case .nonNull(let inner): "\(inner)!"
        }
    }

    /// Whether a variable of this type may be passed where `location` is expected, per the spec's "Is Variable Usage
    /// Allowed": the variable must be at least as strict, and lists must nest alike. `hasDefault` (the variable's or
    /// the location's) lets a nullable variable fill a non-null location.
    public func canBePassed(to location: GraphQLTypeRef, hasDefault: Bool = false) -> Bool {
        if case .nonNull(let required) = location, !isNonNull {
            return hasDefault && canBePassed(to: required)
        }
        switch (self, location) {
        case (.nonNull(let variable), .nonNull(let required)):
            return variable.canBePassed(to: required)
        case (.nonNull(let variable), _):
            return variable.canBePassed(to: location)
        case (.list(let variable), .list(let required)):
            return variable.canBePassed(to: required)
        case (.named(let variable), .named(let required)):
            return variable == required
        default:
            return false
        }
    }
}
