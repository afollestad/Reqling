/// A whole project in memory: metadata, environments, and the folder/request tree.
///
/// Equality is by content, which is how an external-change reload tells another tool's edit (a `git pull`) from
/// Reqling's own write of the same bytes.
public struct ProjectDocument: Hashable, Sendable, Identifiable {
    public static let currentFormatVersion = 1

    public let id: ProjectID
    public var name: String
    public var formatVersion: Int
    /// The auth inherited by top-level items; `.inherit` here means none.
    public var auth: HTTPAuth
    public var tls: ProjectTLSConfiguration
    public var grpc: ProjectGRPCConfiguration
    /// Scripts every request in the project runs around its own, unless something between turns inheriting off.
    public var scripts: ScriptSet
    public var defaultEnvironment: RequestEnvironment
    public var environments: [RequestEnvironment]
    public var items: [RequestNode]

    public init(
        id: ProjectID = ProjectID(),
        name: String,
        formatVersion: Int = ProjectDocument.currentFormatVersion,
        auth: HTTPAuth = .none,
        tls: ProjectTLSConfiguration = ProjectTLSConfiguration(),
        grpc: ProjectGRPCConfiguration = ProjectGRPCConfiguration(),
        scripts: ScriptSet = ScriptSet(),
        defaultEnvironment: RequestEnvironment = RequestEnvironment(name: RequestEnvironment.defaultName),
        environments: [RequestEnvironment] = [],
        items: [RequestNode] = []
    ) {
        self.id = id
        self.name = name
        self.formatVersion = formatVersion
        self.auth = auth
        self.tls = tls
        self.grpc = grpc
        self.scripts = scripts
        self.defaultEnvironment = defaultEnvironment
        self.environments = environments
        self.items = items
    }

    /// Default first, then the others in display order.
    public var allEnvironments: [RequestEnvironment] {
        [defaultEnvironment] + environments
    }

    public func environment(_ id: EnvironmentID) -> RequestEnvironment? {
        allEnvironments.first { $0.id == id }
    }

    public func isDefaultEnvironment(_ id: EnvironmentID) -> Bool {
        defaultEnvironment.id == id
    }

    /// Applies `transform` to the Default environment or another one; returns false when `id` is unknown.
    @discardableResult
    public mutating func updateEnvironment(_ id: EnvironmentID, _ transform: (inout RequestEnvironment) -> Void) -> Bool {
        if defaultEnvironment.id == id {
            transform(&defaultEnvironment)
            return true
        }
        guard let index = environments.firstIndex(where: { $0.id == id }) else {
            return false
        }
        transform(&environments[index])
        return true
    }
}
