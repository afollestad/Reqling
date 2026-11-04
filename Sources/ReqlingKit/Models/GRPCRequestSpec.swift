/// Everything needed to make one gRPC call, with `{{variables}}` still unresolved in the target, metadata, and
/// messages.
public struct GRPCRequestSpec: Hashable, Sendable, Codable {
    /// `host:port`, or `unix:/path/to.sock` for a Unix domain socket.
    public var target: String
    public var security: GRPCSecurity
    /// Fully qualified, such as `helloworld.Greeter`.
    public var service: String
    /// The method's simple name, such as `SayHello`.
    public var method: String
    /// Sent as request metadata (gRPC's headers), disabled rows included.
    public var metadata: [KeyValuePair]
    /// Messages as proto3 JSON, in send order. Unary and server-streaming calls send the first; client-streaming and
    /// bidirectional calls send them all, and a bidirectional call can send more while it is open.
    public var messages: [String]
    public var schema: GRPCSchemaSource
    /// `nil` uses the default from Settings.
    public var deadlineSeconds: Double?
    /// `nil` uses the default from Settings; only consulted for `.tls`.
    public var verifyTLS: Bool?
    /// Sent as metadata: `authorization` for Basic and Bearer, the named key for an API key in a header.
    public var auth: HTTPAuth

    public init(
        target: String = "",
        security: GRPCSecurity = .plaintext,
        service: String = "",
        method: String = "",
        metadata: [KeyValuePair] = [],
        messages: [String] = ["{}"],
        schema: GRPCSchemaSource = .automatic,
        deadlineSeconds: Double? = nil,
        verifyTLS: Bool? = nil,
        auth: HTTPAuth = .inherit
    ) {
        self.target = target
        self.security = security
        self.service = service
        self.method = method
        self.metadata = metadata
        self.messages = messages
        self.schema = schema
        self.deadlineSeconds = deadlineSeconds
        self.verifyTLS = verifyTLS
        self.auth = auth
    }

    /// `service/method`, the form gRPC paths and `DescriptorRegistry.method(_:)` use.
    public var methodPath: String {
        "\(service)/\(method)"
    }

    private enum CodingKeys: String, CodingKey {
        case target, security, service, method, metadata, messages, schema, deadlineSeconds, verifyTLS, auth
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? ""
        security = (try? container.decodeIfPresent(GRPCSecurity.self, forKey: .security)) ?? .plaintext
        service = try container.decodeIfPresent(String.self, forKey: .service) ?? ""
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? ""
        metadata = try container.decodeRowsIfPresent([KeyValuePair].self, forKey: .metadata) ?? []
        messages = try container.decodeIfPresent([String].self, forKey: .messages) ?? ["{}"]
        schema = (try? container.decodeIfPresent(GRPCSchemaSource.self, forKey: .schema)) ?? .automatic
        deadlineSeconds = try container.decodeIfPresent(Double.self, forKey: .deadlineSeconds)
        verifyTLS = try container.decodeIfPresent(Bool.self, forKey: .verifyTLS)
        auth = try container.decodeIfPresent(HTTPAuth.self, forKey: .auth) ?? .inherit
    }
}

public enum GRPCSecurity: String, Hashable, Sendable, Codable, CaseIterable {
    case plaintext
    case tls
}

/// Where a call's schema (its services and message types) comes from.
public enum GRPCSchemaSource: Hashable, Sendable, Codable {
    /// The project's proto definitions when it has any, otherwise server reflection.
    case automatic
    case projectProtos
    case reflection
    /// One `.protoset`/`.binpb` descriptor set.
    case descriptorSet(ProjectPathReference)

    private enum CodingKeys: String, CodingKey {
        case type
        case file
    }

    private enum Kind: String, Codable {
        case automatic, projectProtos, reflection, descriptorSet
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .automatic: self = .automatic
        case .projectProtos: self = .projectProtos
        case .reflection: self = .reflection
        case .descriptorSet: self = .descriptorSet(try container.decode(ProjectPathReference.self, forKey: .file))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic: try container.encode(Kind.automatic, forKey: .type)
        case .projectProtos: try container.encode(Kind.projectProtos, forKey: .type)
        case .reflection: try container.encode(Kind.reflection, forKey: .type)
        case .descriptorSet(let file):
            try container.encode(Kind.descriptorSet, forKey: .type)
            try container.encode(file, forKey: .file)
        }
    }
}

/// Whether each side of a call streams.
public enum GRPCMethodKind: String, Hashable, Sendable, Codable, CaseIterable {
    case unary
    case clientStreaming
    case serverStreaming
    case bidirectionalStreaming

    public init(clientStreams: Bool, serverStreams: Bool) {
        switch (clientStreams, serverStreams) {
        case (false, false): self = .unary
        case (true, false): self = .clientStreaming
        case (false, true): self = .serverStreaming
        case (true, true): self = .bidirectionalStreaming
        }
    }

    public var clientStreams: Bool {
        self == .clientStreaming || self == .bidirectionalStreaming
    }

    public var serverStreams: Bool {
        self == .serverStreaming || self == .bidirectionalStreaming
    }
}
