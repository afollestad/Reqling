/// Where a project holds a file reference: which field, of which item.
///
/// A file the person chose on this Mac, by a this-Mac-only reference or a shared path outside the project's folder and
/// repository, resolves only in the slots it was chosen for (`ProjectPathResolver.choices`). Whoever else edits the
/// project, another Mac through iCloud or a repository's history, sees only the reference, and could otherwise move a
/// body file chosen for one request into another, or a schema into a body, to have it read and sent.
public enum ProjectPathSlot: Hashable, Sendable {
    /// A request's binary body.
    case binaryBody(RequestNodeID)
    /// One form-data file part. A copied request keeps its rows' IDs, so the request is what tells copies apart.
    case formField(RequestNodeID, MultipartFieldID)
    /// A GraphQL request's schema file.
    case graphQLSchema(RequestNodeID)
    /// A gRPC request's own descriptor set.
    case descriptorSet(RequestNodeID)
    /// Any file of one client certificate entry: its PKCS#12 file, or its PEM certificate and key.
    case clientCertificate(CertificateEntryID)
    case caCertificates
    case protoRoots
    /// The project's descriptor sets, beside its proto roots.
    case projectDescriptorSets

    /// The request the slot belongs to, if it belongs to one.
    public var request: RequestNodeID? {
        switch self {
        case .binaryBody(let request), .formField(let request, _), .graphQLSchema(let request), .descriptorSet(let request):
            request
        case .clientCertificate, .caCertificates, .protoRoots, .projectDescriptorSets:
            nil
        }
    }

    /// The same field of `request`, as in a copy of the request it belongs to; a project-level slot stays as it is.
    public func moved(to request: RequestNodeID) -> ProjectPathSlot {
        switch self {
        case .binaryBody: .binaryBody(request)
        case .formField(_, let field): .formField(request, field)
        case .graphQLSchema: .graphQLSchema(request)
        case .descriptorSet: .descriptorSet(request)
        case .clientCertificate, .caCertificates, .protoRoots, .projectDescriptorSets: self
        }
    }

    /// How `WorkspaceStateStore` writes it.
    var key: String {
        switch self {
        case .binaryBody(let request): "binaryBody/\(request)"
        case .formField(let request, let field): "formField/\(request)/\(field)"
        case .graphQLSchema(let request): "graphQLSchema/\(request)"
        case .descriptorSet(let request): "descriptorSet/\(request)"
        case .clientCertificate(let entry): "clientCertificate/\(entry)"
        case .caCertificates: "caCertificates"
        case .protoRoots: "protoRoots"
        case .projectDescriptorSets: "projectDescriptorSets"
        }
    }

    /// The slot `key` names, or `nil` for one this version doesn't know.
    init?(key: String) {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch (parts.first, parts.count) {
        case ("caCertificates", 1): self = .caCertificates
        case ("protoRoots", 1): self = .protoRoots
        case ("projectDescriptorSets", 1): self = .projectDescriptorSets
        case ("formField", 3):
            guard let request = RequestNodeID(string: parts[1]), let field = MultipartFieldID(string: parts[2]) else {
                return nil
            }
            self = .formField(request, field)
        case (let kind?, 2):
            self.init(kind: kind, id: parts[1])
        default:
            return nil
        }
    }

    private init?(kind: String, id: String) {
        if kind == "clientCertificate" {
            guard let entry = CertificateEntryID(string: id) else {
                return nil
            }
            self = .clientCertificate(entry)
            return
        }
        guard let request = RequestNodeID(string: id) else {
            return nil
        }
        switch kind {
        case "binaryBody": self = .binaryBody(request)
        case "graphQLSchema": self = .graphQLSchema(request)
        case "descriptorSet": self = .descriptorSet(request)
        default: return nil
        }
    }
}

extension ProjectPathSlot: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        guard let slot = ProjectPathSlot(key: key) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown file slot: \(key)")
        }
        self = slot
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}

/// A file reference and the slot that holds it.
public struct PlacedPathReference: Hashable, Sendable {
    public let reference: ProjectPathReference
    public let slot: ProjectPathSlot

    public init(_ reference: ProjectPathReference, in slot: ProjectPathSlot) {
        self.reference = reference
        self.slot = slot
    }
}
