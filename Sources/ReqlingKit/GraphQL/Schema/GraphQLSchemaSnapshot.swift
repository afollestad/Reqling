import Foundation

/// A GraphQL schema as one request sees it, with where it came from and a validator built for it.
///
/// Equality is identity and issues: two loads of the same schema are different snapshots, which is what views and
/// caches keyed on a snapshot want, and comparing type systems of thousands of types on every render would not be
/// cheap. A refresh that failed keeps the identity and adds an issue, which still reads as a change.
public struct GraphQLSchemaSnapshot: Identifiable, Equatable, Sendable {
    public enum Source: Hashable, Sendable {
        /// Asked of the server at `url` (masked), at `fetchedAt`.
        case introspection(url: String, fetchedAt: Date)
        /// Read from a schema file, by name.
        case file(name: String)
    }

    public let id: UUID
    public let typeSystem: GraphQLTypeSystem
    public let source: Source
    /// What the server's introspection supports; nil for a file.
    public let capabilities: GraphQLIntrospection.Capabilities?
    /// What was left out or went wrong, one sentence each, such as a refresh that failed and left this older copy.
    public let issues: [String]
    public let validator: GraphQLDocumentValidator

    init(typeSystem: GraphQLTypeSystem, source: Source, capabilities: GraphQLIntrospection.Capabilities?, issues: [String]) {
        id = UUID()
        self.typeSystem = typeSystem
        self.source = source
        self.capabilities = capabilities
        self.issues = issues
        validator = GraphQLDocumentValidator(typeSystem: typeSystem)
    }

    /// The same schema, with `issue` first.
    func adding(issue: String) -> GraphQLSchemaSnapshot {
        GraphQLSchemaSnapshot(
            id: id,
            typeSystem: typeSystem,
            source: source,
            capabilities: capabilities,
            issues: [issue] + issues,
            validator: validator
        )
    }

    private init(
        id: UUID,
        typeSystem: GraphQLTypeSystem,
        source: Source,
        capabilities: GraphQLIntrospection.Capabilities?,
        issues: [String],
        validator: GraphQLDocumentValidator
    ) {
        self.id = id
        self.typeSystem = typeSystem
        self.source = source
        self.capabilities = capabilities
        self.issues = issues
        self.validator = validator
    }

    public static func == (lhs: GraphQLSchemaSnapshot, rhs: GraphQLSchemaSnapshot) -> Bool {
        lhs.id == rhs.id && lhs.issues == rhs.issues
    }
}

/// Why a request has no schema.
public enum GraphQLSchemaLookupError: Error, Hashable, Sendable, LocalizedError {
    /// The server answered, but with errors and no schema: introspection is off, or the query was not allowed.
    case refused([String])
    case introspection(GraphQLIntrospectionFailure)
    /// The response or file held no schema Reqling could read.
    case unreadable(String)
    /// The request could not be sent, or its schema file read.
    case request(RunFailure)

    public var errorDescription: String? {
        switch self {
        case .refused(let messages):
            "The server would not describe its schema: \(messages.first ?? "no reason given")"
                + (messages.count > 1 ? " (and \(messages.count - 1) more)" : "")
                + ". If it turns introspection off, use a schema file."
        case .introspection(let failure): failure.errorDescription
        case .unreadable(let message): message
        case .request(let failure): failure.message
        }
    }
}
