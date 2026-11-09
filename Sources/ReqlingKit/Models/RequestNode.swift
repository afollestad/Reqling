/// A saved request: a template whose `{{variables}}` resolve only when it runs.
public struct RequestItem: Hashable, Sendable, Identifiable, Codable {
    public let id: RequestNodeID
    public var name: String
    public var kind: RequestKind
    /// Not coded: the reader and writer keep them in `.js` files beside the request's JSON. Here rather than on the
    /// spec, so they survive a switch of protocol.
    public var scripts: ScriptSet
    /// Whether the scripts of enclosing folders and the project run around this request's own.
    public var runsInheritedScripts: Bool

    public init(
        id: RequestNodeID = RequestNodeID(),
        name: String,
        kind: RequestKind,
        scripts: ScriptSet = ScriptSet(),
        runsInheritedScripts: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.scripts = scripts
        self.runsInheritedScripts = runsInheritedScripts
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case inheritScripts
    }

    /// The kind's keys sit beside `id` and `name` (`RequestKind`'s coding), so a request file stays one flat object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(RequestNodeID.self, forKey: .id) ?? RequestNodeID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try RequestKind(from: decoder)
        scripts = ScriptSet()
        runsInheritedScripts = try container.decodeIfPresent(Bool.self, forKey: .inheritScripts) ?? true
    }

    /// `inheritScripts` is written only when off, so request files from before scripts stay byte for byte the same.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        if !runsInheritedScripts {
            try container.encode(false, forKey: .inheritScripts)
        }
        try kind.encode(to: encoder)
    }
}

/// The protocol a request speaks, with its protocol-specific spec.
public enum RequestKind: Hashable, Sendable {
    case http(HTTPRequestSpec)
    case grpc(GRPCRequestSpec)
    case webSocket(WebSocketRequestSpec)

    public enum Name: String, Hashable, Sendable, Codable, CaseIterable {
        case http
        case grpc
        case webSocket = "websocket"

        /// The protocol's name as people write it, in menus, filters, and messages.
        public var title: String {
            switch self {
            case .http: "HTTP"
            case .grpc: "gRPC"
            case .webSocket: "WebSocket"
            }
        }
    }

    public var name: Name {
        switch self {
        case .http: .http
        case .grpc: .grpc
        case .webSocket: .webSocket
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

    public var webSocketSpec: WebSocketRequestSpec? {
        if case .webSocket(let spec) = self {
            return spec
        }
        return nil
    }
}

/// Coded as `kind` plus the spec under its protocol's key, the shape request files and a run's history share. A
/// version that predates a kind fails to read its files, and shows each as one unreadable request it leaves alone.
extension RequestKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case http
        case grpc
        case webSocket = "websocket"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindName = try container.decodeIfPresent(String.self, forKey: .kind) ?? Name.http.rawValue
        switch Name(rawValue: kindName) {
        case .http:
            self = .http(try container.decodeIfPresent(HTTPRequestSpec.self, forKey: .http) ?? HTTPRequestSpec())
        case .grpc:
            self = .grpc(try container.decodeIfPresent(GRPCRequestSpec.self, forKey: .grpc) ?? GRPCRequestSpec())
        case .webSocket:
            self = .webSocket(try container.decodeIfPresent(WebSocketRequestSpec.self, forKey: .webSocket) ?? WebSocketRequestSpec())
        case nil:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown request kind: \(kindName)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name.rawValue, forKey: .kind)
        switch self {
        case .http(let spec):
            try container.encode(spec, forKey: .http)
        case .grpc(let spec):
            try container.encode(spec, forKey: .grpc)
        case .webSocket(let spec):
            try container.encode(spec, forKey: .webSocket)
        }
    }
}

/// A folder of requests and subfolders. Its `auth` applies to descendants that inherit, and its scripts run around
/// theirs.
public struct RequestFolder: Hashable, Sendable, Identifiable {
    public let id: RequestNodeID
    public var name: String
    public var auth: HTTPAuth
    public var scripts: ScriptSet
    /// Whether the scripts of enclosing folders and the project run around this folder's and its descendants'.
    public var runsInheritedScripts: Bool
    public var children: [RequestNode]

    public init(
        id: RequestNodeID = RequestNodeID(),
        name: String,
        auth: HTTPAuth = .inherit,
        scripts: ScriptSet = ScriptSet(),
        runsInheritedScripts: Bool = true,
        children: [RequestNode] = []
    ) {
        self.id = id
        self.name = name
        self.auth = auth
        self.scripts = scripts
        self.runsInheritedScripts = runsInheritedScripts
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

    /// This node's ID followed by every descendant's.
    var subtreeIDs: [RequestNodeID] {
        guard case .folder(let folder) = self else {
            return [id]
        }
        return [id] + folder.children.flatMap(\.subtreeIDs)
    }

    /// Whether this request, or this folder or anything inside it, has a script.
    var containsScripts: Bool {
        switch self {
        case .request(let request): !request.scripts.isEmpty
        case .folder(let folder): !folder.scripts.isEmpty || folder.children.contains(where: \.containsScripts)
        }
    }

    /// The IDs of this request, or of every request inside this folder.
    var requestIDs: [RequestNodeID] {
        switch self {
        case .request(let request): [request.id]
        case .folder(let folder): folder.children.flatMap(\.requestIDs)
        }
    }
}
