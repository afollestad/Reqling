import Foundation

/// Decoding an introspection result into a `GraphQLTypeSystem`.
///
/// Servers vary in what they report, so decoding is tolerant: it accepts a whole response (`{"data": {"__schema"}}`),
/// a bare `{"__schema"}`, or the schema object itself; both `specifiedByURL` and the older `specifiedByUrl`; and missing
/// or `null` optional fields. A type of a kind it does not know, or a type reference nested deeper than the query
/// asked, is left out and reported as an issue instead of failing the whole schema.
extension GraphQLTypeSystem {
    public struct Decoded: Sendable {
        public var typeSystem: GraphQLTypeSystem
        /// What was left out or guessed, one sentence each.
        public var issues: [String]
    }

    /// The reason graphql-js gives a deprecation that names none; servers that report `isDeprecated` without a reason
    /// get it too, so a deprecated element is never shown as current.
    static let defaultDeprecationReason = "No longer supported"

    public static func decoding(introspection data: Data) throws(GraphQLSchemaDecodingError) -> Decoded {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw .notJSON
        }
        guard let schema = schemaObject(in: root) else {
            throw .noSchema
        }
        var decoder = IntrospectionDecoder()
        let typeSystem = decoder.typeSystem(from: schema)
        guard typeSystem.rootTypes[.query] != nil else {
            throw .noQueryType
        }
        return Decoded(typeSystem: typeSystem, issues: decoder.issues)
    }

    private static func schemaObject(in root: Any) -> [String: Any]? {
        guard let object = root as? [String: Any] else {
            return nil
        }
        if let data = object["data"] as? [String: Any], let schema = data["__schema"] as? [String: Any] {
            return schema
        }
        if let schema = object["__schema"] as? [String: Any] {
            return schema
        }
        return object["types"] is [Any] ? object : nil
    }
}

/// Why introspection data could not become a schema.
public enum GraphQLSchemaDecodingError: Error, Hashable, Sendable, LocalizedError {
    case notJSON
    case noSchema
    case noQueryType

    public var errorDescription: String? {
        switch self {
        case .notJSON: "The schema is not JSON."
        case .noSchema: "The JSON holds no introspection result (no \"__schema\" with \"types\")."
        case .noQueryType: "The schema names no query type."
        }
    }
}

/// Walks the untyped JSON, collecting issues as it goes; `JSONSerialization` tolerates missing keys where `Codable`
/// would fail the whole document.
private struct IntrospectionDecoder {
    var issues: [String] = []

    mutating func typeSystem(from schema: [String: Any]) -> GraphQLTypeSystem {
        var rootTypes: [GraphQLTypeSystem.OperationType: String] = [:]
        let rootKeys: [(GraphQLTypeSystem.OperationType, String)] = [
            (.query, "queryType"),
            (.mutation, "mutationType"),
            (.subscription, "subscriptionType")
        ]
        for (operation, key) in rootKeys {
            if let name = (schema[key] as? [String: Any])?["name"] as? String {
                rootTypes[operation] = name
            }
        }
        let types = (schema["types"] as? [[String: Any]] ?? []).compactMap { namedType(from: $0) }
        let directives = (schema["directives"] as? [[String: Any]] ?? []).compactMap { directive(from: $0) }
        return GraphQLTypeSystem(description: string(schema["description"]), rootTypes: rootTypes, types: types, directives: directives)
    }

    private mutating func namedType(from object: [String: Any]) -> GraphQLTypeSystem.NamedType? {
        guard let name = object["name"] as? String else {
            issues.append("A type without a name was left out.")
            return nil
        }
        guard let kindName = object["kind"] as? String else {
            issues.append("“\(name)” was left out: it has no kind.")
            return nil
        }
        guard let kind = GraphQLTypeSystem.Kind(rawValue: kindName) else {
            issues.append("“\(name)” was left out: its kind \(kindName) is unknown.")
            return nil
        }
        return GraphQLTypeSystem.NamedType(
            name: name,
            kind: kind,
            description: string(object["description"]),
            fields: (object["fields"] as? [[String: Any]] ?? []).compactMap { field(from: $0, in: name) },
            interfaces: typeNames(object["interfaces"]),
            possibleTypes: typeNames(object["possibleTypes"]),
            enumValues: (object["enumValues"] as? [[String: Any]] ?? []).compactMap { enumValue(from: $0) },
            inputFields: (object["inputFields"] as? [[String: Any]] ?? []).compactMap { inputValue(from: $0, in: name) },
            specifiedByURL: string(object["specifiedByURL"]) ?? string(object["specifiedByUrl"]),
            isOneOf: object["isOneOf"] as? Bool ?? false
        )
    }

    private mutating func field(from object: [String: Any], in typeName: String) -> GraphQLTypeSystem.Field? {
        guard let name = object["name"] as? String else {
            return nil
        }
        guard let type = typeRef(from: object["type"], at: "\(typeName).\(name)") else {
            return nil
        }
        return GraphQLTypeSystem.Field(
            name: name,
            description: string(object["description"]),
            args: (object["args"] as? [[String: Any]] ?? []).compactMap { inputValue(from: $0, in: "\(typeName).\(name)") },
            type: type,
            deprecationReason: deprecation(object)
        )
    }

    private mutating func inputValue(from object: [String: Any], in owner: String) -> GraphQLTypeSystem.InputValue? {
        guard let name = object["name"] as? String, let type = typeRef(from: object["type"], at: "\(owner)(\(name):)") else {
            return nil
        }
        return GraphQLTypeSystem.InputValue(
            name: name,
            description: string(object["description"]),
            type: type,
            defaultValue: string(object["defaultValue"]),
            deprecationReason: deprecation(object)
        )
    }

    private func enumValue(from object: [String: Any]) -> GraphQLTypeSystem.EnumValue? {
        guard let name = object["name"] as? String else {
            return nil
        }
        return GraphQLTypeSystem.EnumValue(name: name, description: string(object["description"]), deprecationReason: deprecation(object))
    }

    private mutating func directive(from object: [String: Any]) -> GraphQLTypeSystem.Directive? {
        guard let name = object["name"] as? String else {
            return nil
        }
        let locations = (object["locations"] as? [String] ?? []).compactMap { location in
            let known = GraphQLTypeSystem.DirectiveLocation(rawValue: location)
            if known == nil {
                issues.append("@\(name)'s location \(location) is unknown and was left out.")
            }
            return known
        }
        return GraphQLTypeSystem.Directive(
            name: name,
            description: string(object["description"]),
            locations: locations,
            args: (object["args"] as? [[String: Any]] ?? []).compactMap { inputValue(from: $0, in: "@\(name)") },
            isRepeatable: object["isRepeatable"] as? Bool
        )
    }

    /// A reference whose wrappers end before a named type (the server nested deeper than the query asked) cannot be
    /// read; its field or argument is left out.
    private mutating func typeRef(from value: Any?, at path: String) -> GraphQLTypeRef? {
        guard let object = value as? [String: Any], let kind = object["kind"] as? String else {
            issues.append("\(path) was left out: its type is missing.")
            return nil
        }
        switch kind {
        case "NON_NULL", "LIST":
            guard let inner = object["ofType"] as? [String: Any] else {
                issues.append("\(path) was left out: its type is wrapped deeper than the schema query reads.")
                return nil
            }
            guard let wrapped = typeRef(from: inner, at: path) else {
                return nil
            }
            return kind == "LIST" ? .list(wrapped) : .nonNull(wrapped)
        default:
            guard let name = object["name"] as? String else {
                issues.append("\(path) was left out: its type has no name.")
                return nil
            }
            return .named(name)
        }
    }

    private func typeNames(_ value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    private func deprecation(_ object: [String: Any]) -> String? {
        if let reason = string(object["deprecationReason"]) {
            return reason
        }
        return object["isDeprecated"] as? Bool == true ? GraphQLTypeSystem.defaultDeprecationReason : nil
    }

    /// JSON `null` arrives as `NSNull`, which a plain `as? String` already rejects; empty text counts as none.
    private func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else {
            return nil
        }
        return text
    }
}
