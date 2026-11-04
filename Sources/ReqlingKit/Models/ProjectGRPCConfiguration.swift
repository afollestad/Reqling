/// A project's proto definitions, shared by every gRPC request in it that uses project protos.
///
/// Paths are `ProjectPathReference`s, so roots inside the project's folder or repository travel with it relative, and
/// anything else stays on this Mac.
public struct ProjectGRPCConfiguration: Hashable, Sendable, Codable {
    /// Directories passed to protoc as import paths (`-I`).
    public var protoRoots: [ProjectPathReference]
    /// Entry files relative to a root; empty compiles every `.proto` under the roots.
    public var protoFiles: [String]
    /// `.protoset`/`.binpb`/`.pb` files merged into the same schema; they never need protoc.
    public var descriptorSets: [ProjectPathReference]

    public init(protoRoots: [ProjectPathReference] = [], protoFiles: [String] = [], descriptorSets: [ProjectPathReference] = []) {
        self.protoRoots = protoRoots
        self.protoFiles = protoFiles
        self.descriptorSets = descriptorSets
    }

    public var isEmpty: Bool {
        protoRoots.isEmpty && descriptorSets.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case protoRoots, protoFiles, descriptorSets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protoRoots = try container.decodeIfPresent([ProjectPathReference].self, forKey: .protoRoots) ?? []
        protoFiles = try container.decodeIfPresent([String].self, forKey: .protoFiles) ?? []
        descriptorSets = try container.decodeIfPresent([ProjectPathReference].self, forKey: .descriptorSets) ?? []
    }
}
