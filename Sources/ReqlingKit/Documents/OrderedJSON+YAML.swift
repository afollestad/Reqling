import Foundation
internal import ReqlingYAML

/// Documents read as JSON join those read as YAML in one model: imports work on `YAMLValue`s, which write back out as
/// either, whichever their source was.
extension YAMLValue {
    init(_ json: OrderedJSON) {
        switch json {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .number(let text): self = .number(text)
        case .string(let text): self = .string(text)
        case .array(let values): self = .array(values.map(YAMLValue.init))
        case .object(let members): self = .object(members.map { YAMLMember(key: $0.key, value: YAMLValue($0.value)) })
        }
    }

    /// The text a scalar would be typed as in a field: a string as is, a number or boolean as JSON writes it, `null`
    /// as nothing; a list or mapping as compact JSON.
    var fieldText: String {
        switch self {
        case .null: ""
        case .bool(let value): value ? "true" : "false"
        case .number(let text): text
        case .string(let text): text
        case .array, .object: jsonText()
        }
    }

    var string: String? {
        if case .string(let text) = self {
            return text
        }
        return nil
    }

    var array: [YAMLValue]? {
        if case .array(let values) = self {
            return values
        }
        return nil
    }

    var members: [YAMLMember]? {
        if case .object(let members) = self {
            return members
        }
        return nil
    }

    var bool: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }
}

/// Reads a document's text as JSON or YAML, whichever it is, into one `YAMLValue`.
enum StructuredText {
    /// JSON goes through `OrderedJSONParser`, never libyaml, which rejects the escaped surrogate pairs (`"😀"`)
    /// many JSON writers emit; text that starts like JSON but isn't is tried as flow-style YAML (`{openapi: 3.1.0}`)
    /// before its JSON error is reported.
    static func parse(_ data: Data) throws(StructuredTextError) -> YAMLValue {
        guard var text = String(data: data, encoding: .utf8) else {
            throw StructuredTextError(message: "It isn't UTF-8 text.")
        }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        let first = text.first { !$0.isWhitespace }
        if first == "{" || first == "[" {
            do {
                return YAMLValue(try OrderedJSONParser.parse(text))
            } catch {
                if let yaml = try? YAML.parse(text) {
                    return yaml
                }
                throw StructuredTextError(message: error.description)
            }
        }
        do {
            return try YAML.parse(text)
        } catch {
            throw StructuredTextError(message: error.localizedDescription)
        }
    }
}

struct StructuredTextError: Error, Hashable, Sendable {
    let message: String
}
