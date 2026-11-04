/// One row of a key/value table: query parameters, headers, and URL-encoded form fields.
///
/// Rows have no identity of their own, so documents compare by content alone; that equality is
/// what lets an external-change reload tell a real edit from Reqling's own write.
public struct KeyValuePair: Hashable, Codable, Sendable {
    public var key: String
    public var value: String
    public var isEnabled: Bool

    public init(key: String, value: String, isEnabled: Bool = true) {
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case value
        case isEnabled = "enabled"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
