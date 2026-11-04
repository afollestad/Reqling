/// How a request authenticates. `inherit` walks up the folder chain to the project; a project's own
/// `inherit` means none.
///
/// Credentials are stored as typed; reference a secret variable (`{{token}}`) to keep them out of the project files.
public enum HTTPAuth: Hashable, Sendable, Codable {
    case inherit
    case none
    case basic(username: String, password: String)
    case bearer(token: String)
    case apiKey(name: String, value: String, location: APIKeyLocation)

    public enum APIKeyLocation: String, Hashable, Sendable, Codable, CaseIterable {
        case header
        case query
    }

    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case inherit
        case none
        case basic
        case bearer
        case apiKey
    }

    public var kind: Kind {
        switch self {
        case .inherit: .inherit
        case .none: .none
        case .basic: .basic
        case .bearer: .bearer
        case .apiKey: .apiKey
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case username
        case password
        case token
        case name
        case value
        case location
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? Kind.inherit.rawValue
        func string(_ key: CodingKeys) throws -> String {
            try container.decodeIfPresent(String.self, forKey: key) ?? ""
        }
        // An unknown type falls back to inheriting rather than failing the whole request file.
        switch Kind(rawValue: type) ?? .inherit {
        case .inherit:
            self = .inherit
        case .none:
            self = .none
        case .basic:
            self = .basic(username: try string(.username), password: try string(.password))
        case .bearer:
            self = .bearer(token: try string(.token))
        case .apiKey:
            let location = try container.decodeIfPresent(APIKeyLocation.self, forKey: .location) ?? .header
            self = .apiKey(name: try string(.name), value: try string(.value), location: location)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .type)
        switch self {
        case .inherit, .none:
            break
        case .basic(let username, let password):
            try container.encode(username, forKey: .username)
            try container.encode(password, forKey: .password)
        case .bearer(let token):
            try container.encode(token, forKey: .token)
        case .apiKey(let name, let value, let location):
            try container.encode(name, forKey: .name)
            try container.encode(value, forKey: .value)
            try container.encode(location, forKey: .location)
        }
    }
}
