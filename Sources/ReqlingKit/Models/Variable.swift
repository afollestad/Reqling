/// A named value referenced as `{{key}}` from any request field.
///
/// A secret variable's `value` lives only in memory and the Keychain (`SecretStore`); its JSON
/// carries the key and `"secret": true` but never the value, so project folders stay safe to commit.
public struct Variable: Hashable, Sendable, Identifiable, Codable {
    public let id: VariableID
    public var key: String
    public var value: String
    public var isEnabled: Bool
    public var isSecret: Bool

    public init(id: VariableID = VariableID(), key: String, value: String, isEnabled: Bool = true, isSecret: Bool = false) {
        self.id = id
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
        self.isSecret = isSecret
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case key
        case value
        case isEnabled = "enabled"
        case isSecret = "secret"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(VariableID.self, forKey: .id) ?? VariableID()
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isSecret = try container.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
        // A hand-edited file may still carry a secret's value; drop it rather than keep plaintext in memory as if
        // it had come from the Keychain.
        value = isSecret ? "" : try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(key, forKey: .key)
        try container.encode(isEnabled, forKey: .isEnabled)
        if isSecret {
            try container.encode(true, forKey: .isSecret)
        } else {
            try container.encode(value, forKey: .value)
        }
    }
}

/// A named set of variables. Every project has an undeletable Default environment, and the active
/// environment's variables override Default's, which override the Global environment every project shares
/// (`ProjectLibrary.globalEnvironment`).
public struct RequestEnvironment: Hashable, Sendable, Identifiable, Codable {
    public static let defaultName = "Default"
    public static let globalName = "Global"
    /// Fixed rather than stored, so Global's secret keys and an agent's reference to it hold even before its file exists.
    public static let globalID = EnvironmentID.derived(from: "reqling.global-environment")

    public static func global(variables: [Variable] = []) -> RequestEnvironment {
        RequestEnvironment(id: globalID, name: globalName, variables: variables)
    }

    /// Whether `name` is Global's, ignoring case and surrounding space. A project's own environment can't take it: agents
    /// address environments by name, and this one names the shared environment.
    public static func isGlobalName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(globalName) == .orderedSame
    }

    public let id: EnvironmentID
    public var name: String
    public var variables: [Variable]

    public init(id: EnvironmentID = EnvironmentID(), name: String, variables: [Variable] = []) {
        self.id = id
        self.name = name
        self.variables = variables
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(EnvironmentID.self, forKey: .id) ?? EnvironmentID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        variables = try container.decodeIfPresent([Variable].self, forKey: .variables) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case variables
    }
}
