/// A saved request: a template whose `{{variables}}` resolve only when it runs.
public struct RequestItem: Hashable, Sendable, Identifiable, Codable {
    public let id: RequestNodeID
    public var name: String
    public var kind: RequestKind

    public init(id: RequestNodeID = RequestNodeID(), name: String, kind: RequestKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case http
        case grpc
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(RequestNodeID.self, forKey: .id) ?? RequestNodeID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        let kindName = try container.decodeIfPresent(String.self, forKey: .kind) ?? RequestKind.Name.http.rawValue
        switch RequestKind.Name(rawValue: kindName) {
        case .http:
            kind = .http(try container.decodeIfPresent(HTTPRequestSpec.self, forKey: .http) ?? HTTPRequestSpec())
        case .grpc:
            kind = .grpc(try container.decodeIfPresent(GRPCRequestSpec.self, forKey: .grpc) ?? GRPCRequestSpec())
        case nil:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown request kind: \(kindName)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind.name.rawValue, forKey: .kind)
        switch kind {
        case .http(let spec):
            try container.encode(spec, forKey: .http)
        case .grpc(let spec):
            try container.encode(spec, forKey: .grpc)
        }
    }
}

/// The protocol a request speaks, with its protocol-specific spec.
public enum RequestKind: Hashable, Sendable {
    case http(HTTPRequestSpec)
    case grpc(GRPCRequestSpec)

    public enum Name: String, Hashable, Sendable, Codable, CaseIterable {
        case http
        case grpc
    }

    public var name: Name {
        switch self {
        case .http: .http
        case .grpc: .grpc
        }
    }

    public var httpSpec: HTTPRequestSpec? {
        if case .http(let spec) = self {
            return spec
        }
        return nil
    }

    public var grpcSpec: GRPCRequestSpec? {
        if case .grpc(let spec) = self {
            return spec
        }
        return nil
    }
}

/// A folder of requests and subfolders. Its `auth` applies to descendants that inherit.
public struct RequestFolder: Hashable, Sendable, Identifiable {
    public let id: RequestNodeID
    public var name: String
    public var auth: HTTPAuth
    public var children: [RequestNode]

    public init(id: RequestNodeID = RequestNodeID(), name: String, auth: HTTPAuth = .inherit, children: [RequestNode] = []) {
        self.id = id
        self.name = name
        self.auth = auth
        self.children = children
    }
}

public enum RequestNode: Hashable, Sendable, Identifiable {
    case folder(RequestFolder)
    case request(RequestItem)

    public var id: RequestNodeID {
        switch self {
        case .folder(let folder): folder.id
        case .request(let request): request.id
        }
    }

    public var name: String {
        get {
            switch self {
            case .folder(let folder): folder.name
            case .request(let request): request.name
            }
        }
        set {
            switch self {
            case .folder(var folder):
                folder.name = newValue
                self = .folder(folder)
            case .request(var request):
                request.name = newValue
                self = .request(request)
            }
        }
    }

    public var isFolder: Bool {
        if case .folder = self {
            return true
        }
        return false
    }
}
