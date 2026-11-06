import CryptoKit
import Foundation

/// A UUID-backed identifier that cannot be mixed up with another entity's: `ProjectID` and
/// `RequestNodeID` are different types even though both encode as a bare UUID string.
///
/// Encodes lowercase, the form people and tools usually write, and decodes either case.
public struct TypedID<Tag>: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else {
            return nil
        }
        rawValue = uuid
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let uuid = UUID(uuidString: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a UUID: \(string)")
        }
        rawValue = uuid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.description < rhs.description
    }

    /// A name-based (RFC 4122 version 5) ID: the same `name` always yields the same ID.
    ///
    /// The project reader uses it for items whose file carries no usable ID (missing, or a duplicate of another
    /// file's), keyed by the project and the file's path, and list rows (`ListRow`) for rows stored without one, keyed
    /// by where they sit in their file. A random fallback would change on every reload, so an open editor would lose
    /// its item and selection, expansion, and secrets keyed by the ID would be orphaned, and every reload would look
    /// like a change.
    static func derived(from name: String) -> Self {
        var hasher = Insecure.SHA1()
        hasher.update(data: typedIDDerivationNamespace)
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return Self(uuid)
    }
}

/// The version-5 namespace for `TypedID.derived(from:)`. Changing it changes every derived ID, which orphans state
/// keyed by IDs of files that have not been re-saved yet.
private let typedIDDerivationNamespace: [UInt8] = [
    0x3B, 0x0F, 0x6A, 0x52, 0x8C, 0x1E, 0x4F, 0x7B, 0x9D, 0x2A, 0x6E, 0x5C, 0x4B, 0x3A, 0x2F, 0x10
]

public enum ProjectTag {}
public enum EnvironmentTag {}
public enum RequestNodeTag {}
public enum VariableTag {}
public enum CertificateEntryTag {}
public enum LocalPathTag {}
public enum KeyValuePairTag {}
public enum MultipartFieldTag {}
public enum WebSocketMessageTag {}
public enum RunTag {}

public typealias ProjectID = TypedID<ProjectTag>
public typealias EnvironmentID = TypedID<EnvironmentTag>
/// Shared by folders and requests, since both are nodes of one tree and siblings order by it.
public typealias RequestNodeID = TypedID<RequestNodeTag>
public typealias VariableID = TypedID<VariableTag>
public typealias CertificateEntryID = TypedID<CertificateEntryTag>
public typealias LocalPathID = TypedID<LocalPathTag>
/// Unique only within one list, such as one request's headers: a duplicated request keeps its rows' IDs.
public typealias KeyValuePairID = TypedID<KeyValuePairTag>
/// Unique only within one request's form-data fields.
public typealias MultipartFieldID = TypedID<MultipartFieldTag>
/// Unique only within one WebSocket request's saved messages.
public typealias WebSocketMessageID = TypedID<WebSocketMessageTag>
/// One run of a request, as its history lists it.
public typealias RunID = TypedID<RunTag>
