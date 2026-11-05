/// A project's client certificates (mTLS) and extra trusted CAs, shared by HTTP and gRPC requests.
public struct ProjectTLSConfiguration: Hashable, Sendable, Codable {
    public var clientCertificates: [ClientCertificateEntry]
    /// PEM or DER certificates trusted in addition to the system roots.
    public var caCertificates: [ProjectPathReference]

    public init(clientCertificates: [ClientCertificateEntry] = [], caCertificates: [ProjectPathReference] = []) {
        self.clientCertificates = clientCertificates
        self.caCertificates = caCertificates
    }

    public var isEmpty: Bool {
        clientCertificates.isEmpty && caCertificates.isEmpty
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientCertificates = try container.decodeIfPresent([ClientCertificateEntry].self, forKey: .clientCertificates) ?? []
        caCertificates = try container.decodeIfPresent([ProjectPathReference].self, forKey: .caCertificates) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case clientCertificates
        case caCertificates
    }
}

/// A client identity presented to hosts matching `hostPattern` (`api.example.com`, `*.internal`, optional `:port`).
///
/// A passphrase (a PKCS#12 file's, or an encrypted PEM key's) lives in the Keychain through `SecretStore`, keyed by
/// this entry's ID. A Keychain identity is machine specific, so the project file records only that one is expected and
/// `WorkspaceStateStore` holds this Mac's reference to it.
public struct ClientCertificateEntry: Hashable, Sendable, Codable, Identifiable {
    public let id: CertificateEntryID
    public var hostPattern: String
    public var source: ClientCertificateSource

    public init(id: CertificateEntryID = CertificateEntryID(), hostPattern: String, source: ClientCertificateSource) {
        self.id = id
        self.hostPattern = hostPattern
        self.source = source
    }
}

public enum ClientCertificateSource: Hashable, Sendable, Codable {
    case pkcs12(ProjectPathReference)
    /// A PEM (or DER) certificate and its PEM private key; the same reference twice when one file holds both.
    case pem(certificate: ProjectPathReference, key: ProjectPathReference)
    case keychainIdentity

    /// The files the identity is read from.
    public var files: [ProjectPathReference] {
        switch self {
        case .pkcs12(let file):
            [file]
        case .pem(let certificate, let key):
            certificate == key ? [certificate] : [certificate, key]
        case .keychainIdentity:
            []
        }
    }

    /// Whether opening it can take a passphrase.
    public var usesPassphrase: Bool {
        switch self {
        case .pkcs12, .pem:
            true
        case .keychainIdentity:
            false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case file
        case certificate
        case key
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "pkcs12":
            self = .pkcs12(try container.decode(ProjectPathReference.self, forKey: .file))
        case "pem":
            self = .pem(
                certificate: try container.decode(ProjectPathReference.self, forKey: .certificate),
                key: try container.decode(ProjectPathReference.self, forKey: .key)
            )
        case "keychain":
            self = .keychainIdentity
        case let type:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown certificate source: \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pkcs12(let file):
            try container.encode("pkcs12", forKey: .type)
            try container.encode(file, forKey: .file)
        case .pem(let certificate, let key):
            try container.encode("pem", forKey: .type)
            try container.encode(certificate, forKey: .certificate)
            try container.encode(key, forKey: .key)
        case .keychainIdentity:
            try container.encode("keychain", forKey: .type)
        }
    }
}
