/// A file a project refers to: a binary body, a form-data file part, a GraphQL schema, a certificate, or a proto root.
///
/// `relative` paths resolve against the project folder and travel with it through git. `local` paths are machine
/// specific: the project file stores only an ID, and the absolute path lives in this Mac's `WorkspaceStateStore`, so
/// another machine sees the reference as missing rather than as somebody else's home directory.
public enum ProjectPathReference: Hashable, Sendable, Codable {
    case relative(String)
    case local(LocalPathID)

    private enum CodingKeys: String, CodingKey {
        case relative
        case local
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try container.decodeIfPresent(String.self, forKey: .relative) {
            self = .relative(path)
        } else if let id = try container.decodeIfPresent(LocalPathID.self, forKey: .local) {
            self = .local(id)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected `relative` or `local`."))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .relative(let path):
            try container.encode(path, forKey: .relative)
        case .local(let id):
            try container.encode(id, forKey: .local)
        }
    }
}
