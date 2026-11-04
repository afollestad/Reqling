import Foundation
import MCP

/// A tool's arguments, read strictly whatever the advertised schema promised: unknown keys are refused, and every
/// value is type-checked as it is read, with a path the agent can act on.
///
/// A blank string for an optional field reads as omitted: models send `""` for an optional they have nothing to say
/// for, and refusing the call would only cost a turn. A value of the wrong type is still refused.
public struct MCPArguments: Sendable {
    let values: [String: Value]
    let path: String

    public init(_ values: [String: Value], path: String = "arguments") {
        self.values = values
        self.path = path
    }

    func requireOnly(_ allowed: Set<String>) throws {
        let unknown = Set(values.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            throw MCPToolError("\(path) has unsupported field(s): \(unknown.joined(separator: ", ")).")
        }
    }

    func contains(_ key: String) -> Bool {
        values[key] != nil && values[key] != .null
    }

    // MARK: - Strings

    func string(_ key: String) throws -> String {
        guard let value = try optionalString(key) else {
            throw MCPToolError("\(path).\(key) is required.")
        }
        return value
    }

    /// Trimmed; `nil` when absent, null, or blank.
    func optionalString(_ key: String) throws -> String? {
        guard let raw = try optionalRawString(key) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Untrimmed, and blank kept: for values such as a variable's or a message body, where whitespace is content.
    func optionalRawString(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null?:
            return nil
        case .string(let text)?:
            return text
        default:
            throw MCPToolError("\(path).\(key) must be a string.")
        }
    }

    func stringArray(_ key: String) throws -> [String]? {
        guard let items = try optionalArray(key) else {
            return nil
        }
        return try items.enumerated().map { index, item in
            guard case .string(let text) = item else {
                throw MCPToolError("\(path).\(key)[\(index)] must be a string.")
            }
            return text
        }
    }

    /// An object of string values, such as one-run variable overrides.
    func stringMap(_ key: String) throws -> [String: String]? {
        guard let object = try optionalObject(key) else {
            return nil
        }
        return try object.reduce(into: [:]) { result, entry in
            guard case .string(let text) = entry.value else {
                throw MCPToolError("\(path).\(key).\(entry.key) must be a string.")
            }
            result[entry.key] = text
        }
    }

    // MARK: - Other scalars

    func optionalBool(_ key: String) throws -> Bool? {
        switch values[key] {
        case nil, .null?:
            return nil
        case .bool(let flag)?:
            return flag
        default:
            throw MCPToolError("\(path).\(key) must be a boolean.")
        }
    }

    func bool(_ key: String, default fallback: Bool) throws -> Bool {
        try optionalBool(key) ?? fallback
    }

    func optionalInteger(_ key: String, in range: ClosedRange<Int>? = nil) throws -> Int? {
        let integer: Int
        switch values[key] {
        case nil, .null?:
            return nil
        case .int(let value)?:
            integer = value
        case .double(let value)? where value.isFinite && value.rounded() == value && Int(exactly: value) != nil:
            integer = Int(value)
        default:
            throw MCPToolError("\(path).\(key) must be an integer.")
        }
        if let range, !range.contains(integer) {
            throw MCPToolError("\(path).\(key) must be from \(range.lowerBound) to \(range.upperBound).")
        }
        return integer
    }

    func optionalNumber(_ key: String, in range: ClosedRange<Double>? = nil) throws -> Double? {
        let number: Double
        switch values[key] {
        case nil, .null?:
            return nil
        case .int(let value)?:
            number = Double(value)
        case .double(let value)? where value.isFinite:
            number = value
        default:
            throw MCPToolError("\(path).\(key) must be a number.")
        }
        if let range, !range.contains(number) {
            throw MCPToolError("\(path).\(key) must be from \(range.lowerBound) to \(range.upperBound).")
        }
        return number
    }

    // MARK: - Containers

    func optionalObject(_ key: String) throws -> [String: Value]? {
        switch values[key] {
        case nil, .null?:
            return nil
        case .object(let object)?:
            return object
        default:
            throw MCPToolError("\(path).\(key) must be an object.")
        }
    }

    func optionalArray(_ key: String) throws -> [Value]? {
        switch values[key] {
        case nil, .null?:
            return nil
        case .array(let items)?:
            return items
        default:
            throw MCPToolError("\(path).\(key) must be an array.")
        }
    }

    func array(_ key: String) throws -> [Value] {
        guard let items = try optionalArray(key) else {
            throw MCPToolError("\(path).\(key) is required.")
        }
        return items
    }

    /// Each element of an array of objects, as arguments of its own with its path.
    func objects(_ key: String, allowed: Set<String>) throws -> [MCPArguments]? {
        guard let items = try optionalArray(key) else {
            return nil
        }
        return try items.enumerated().map { index, item in
            guard case .object(let object) = item else {
                throw MCPToolError("\(path).\(key)[\(index)] must be an object.")
            }
            let arguments = MCPArguments(object, path: "\(path).\(key)[\(index)]")
            try arguments.requireOnly(allowed)
            return arguments
        }
    }

    func nested(_ key: String, allowed: Set<String>) throws -> MCPArguments? {
        guard let object = try optionalObject(key) else {
            return nil
        }
        let arguments = MCPArguments(object, path: "\(path).\(key)")
        try arguments.requireOnly(allowed)
        return arguments
    }
}
