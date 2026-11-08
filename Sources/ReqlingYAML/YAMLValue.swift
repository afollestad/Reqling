import Foundation

/// A YAML document's data, in JSON's model: what a YAML response's tree shows and what an OpenAPI document is read as.
/// Mappings keep their keys in document order, and a number keeps its text in JSON number grammar, so a 20-digit ID
/// and `1.10` come out as written. Values only JSON can't hold (`.inf`, a timestamp) read as strings.
public enum YAMLValue: Hashable, Sendable {
    case null
    case bool(Bool)
    /// The number's text, always valid JSON number grammar (`+1` reads as `1`, `0x1F` as `31`, `.5` as `0.5`).
    case number(String)
    case string(String)
    case array([YAMLValue])
    /// The mapping's members in document order, each key once.
    case object([YAMLMember])

    /// The member's value for `key`; `nil` when this isn't a mapping or has no such key.
    public subscript(key: String) -> YAMLValue? {
        guard case .object(let members) = self else {
            return nil
        }
        return members.first { $0.key == key }?.value
    }
}

/// One key of a mapping and its value. A key that wasn't a scalar (a mapping or a sequence) reads as its compact JSON.
public struct YAMLMember: Hashable, Sendable {
    public let key: String
    public let value: YAMLValue

    public init(key: String, value: YAMLValue) {
        self.key = key
        self.value = value
    }
}

/// Why text couldn't be read as YAML, with where, when libyaml knows (1-based).
public struct YAMLError: Error, Hashable, Sendable, LocalizedError {
    public let message: String
    public let line: Int?
    public let column: Int?

    public init(message: String, line: Int? = nil, column: Int? = nil) {
        self.message = message
        self.line = line
        self.column = column
    }

    /// Aliases that would expand past the node budget (`YAML.parse`'s `maximumNodes`), as an alias bomb does.
    public static let tooLarge = YAMLError(message: "Its aliases expand to too much data.")

    public var errorDescription: String? {
        guard let line else {
            return message
        }
        return "Line \(line)\(column.map { ", column \($0)" } ?? ""): \(message)"
    }
}
