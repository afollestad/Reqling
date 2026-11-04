/// One row of a key/value table: query parameters, headers, URL-encoded form fields, and gRPC metadata. Responses and
/// sent-request summaries reuse it, where the ID only keeps rows distinct.
///
/// The `id` is stored with the row; `ListRow` explains why, and how a row stored without one gets a stable one.
public struct KeyValuePair: ListRow, Codable {
    public var id: KeyValuePairID
    public var key: String
    public var value: String
    public var isEnabled: Bool

    public init(id: KeyValuePairID = KeyValuePairID(), key: String, value: String, isEnabled: Bool = true) {
        self.id = id
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case key
        case value
        case isEnabled = "enabled"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(KeyValuePairID.self, forKey: .id)) ?? Self.derivedID(at: decoder.codingPath)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}
