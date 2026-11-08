import Foundation

/// Any JSON value, as Postman's exports are read. Their fields change shape between versions and apps (a URL is a
/// string or an object, a header list an array or text, a variable's value any JSON), so the importer reads a tree and
/// takes what each field holds rather than decoding fixed types that would reject a whole file over one field.
enum PostmanJSON: Hashable, Sendable, Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([PostmanJSON])
    case object([String: PostmanJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PostmanJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PostmanJSON].self))
        }
    }

    subscript(key: String) -> PostmanJSON? {
        if case .object(let fields) = self {
            return fields[key]
        }
        return nil
    }

    var string: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    var array: [PostmanJSON]? {
        if case .array(let values) = self {
            return values
        }
        return nil
    }

    var object: [String: PostmanJSON]? {
        if case .object(let fields) = self {
            return fields
        }
        return nil
    }

    /// The value as Reqling stores a variable's or field's text: a string as it is, a number or boolean as JSON writes
    /// it (`42`, `1.5`, `true`), `null` as empty, and an array or object as compact JSON with sorted keys.
    var text: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return ""
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }

    /// Text that Postman writes either as one string or as an array of lines, such as a script's `exec`.
    var lines: String? {
        switch self {
        case .string(let value): value
        case .array(let values): values.map(\.text).joined(separator: "\n")
        default: nil
        }
    }
}

extension PostmanJSON: Encodable {
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let values): try container.encode(values)
        case .object(let fields): try container.encode(fields)
        }
    }
}
