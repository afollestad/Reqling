import Foundation
internal import ReqlingYAML

/// A request example made from a JSON Schema: a value the schema gives (`const`, `examples`, `example`, `default`, its
/// first `enum`), else one by type and format, objects with every property but `readOnly` ones and lists with one item.
/// `allOf` merges, and `oneOf` and `anyOf` take their first non-null choice, its discriminator set. A schema that
/// refers back to one it's inside stops there, and depth and size are capped, so a recursive or huge schema still makes
/// an example, noted as cut short.
struct OpenAPISchemaExample {
    static let maximumDepth = 10
    static let maximumNodes = 5_000

    let resolver: OpenAPIResolver
    /// 3.1+: a `$ref`'s sibling keywords combine with its target (`OpenAPIDocument.refSiblingsCombine`).
    let siblingsCombine: Bool
    private(set) var isCutShort = false
    private(set) var failures: [OpenAPIReferenceFailure] = []
    private var nodes = 0

    init(resolver: OpenAPIResolver, siblingsCombine: Bool) {
        self.resolver = resolver
        self.siblingsCombine = siblingsCombine
    }

    mutating func example(_ schema: OpenAPINode, depth: Int = 0, references: Set<String> = []) -> YAMLValue? {
        nodes += 1
        guard nodes <= Self.maximumNodes else {
            isCutShort = true
            return nil
        }
        guard depth <= Self.maximumDepth else {
            return nil
        }
        var references = references
        guard let schema = target(of: schema, depth: depth, references: &references) else {
            return nil
        }
        if case .combined(let parts) = schema {
            return merged(parts, depth: depth, references: references)
        }
        guard case .schema(let node) = schema else {
            return nil
        }
        if let given = Self.givenValue(node) {
            return given
        }
        if let parts = node["allOf"]?.elements, !parts.isEmpty {
            let own = node.value.members?.filter { $0.key != "allOf" } ?? []
            return merged(parts + [OpenAPINode(value: .object(own), document: node.document)], depth: depth, references: references)
        }
        if let choices = (node["oneOf"] ?? node["anyOf"])?.elements, !choices.isEmpty {
            return choice(choices, of: node, depth: depth, references: references)
        }
        return typed(node, depth: depth, references: references)
    }

    private enum Target {
        case schema(OpenAPINode)
        case combined([OpenAPINode])
    }

    /// The schema a `$ref` leads to, combined with its siblings where they combine; `nil` for a reference the
    /// example is already inside, or one that can't be followed.
    private mutating func target(of schema: OpenAPINode, depth: Int, references: inout Set<String>) -> Target? {
        guard let reference = schema.value["$ref"]?.string else {
            return .schema(schema)
        }
        // By target, so a schema reached again through a reference written another way still stops.
        let key = resolver.targetKey(of: reference, from: schema.document) ?? "\(schema.document.absoluteString)\u{0}\(reference)"
        guard references.insert(key).inserted else {
            return nil
        }
        switch resolver.resolve(schema) {
        case .success(let resolved):
            let siblings = schema.value.members?.filter { !["$ref", "description", "summary"].contains($0.key) } ?? []
            guard siblingsCombine, !siblings.isEmpty else {
                return .schema(resolved)
            }
            return .combined([resolved, OpenAPINode(value: .object(siblings), document: schema.document)])
        case .failure(let failure):
            failures.append(failure)
            return nil
        }
    }

    static func givenValue(_ schema: OpenAPINode) -> YAMLValue? {
        if let value = schema["const"]?.value ?? schema["examples"]?.value.array?.first ?? schema["example"]?.value ?? schema["default"]?.value {
            return value
        }
        return schema["enum"]?.value.array?.first
    }

    /// `allOf`'s parts as one object, members in order, a later part's value winning; the first part's example when
    /// they aren't objects.
    private mutating func merged(_ parts: [OpenAPINode], depth: Int, references: Set<String>) -> YAMLValue? {
        var members: [YAMLMember] = []
        var first: YAMLValue?
        for part in parts {
            guard let value = example(part, depth: depth + 1, references: references) else {
                continue
            }
            first = first ?? value
            for member in value.members ?? [] {
                if let index = members.firstIndex(where: { $0.key == member.key }) {
                    members[index] = member
                } else {
                    members.append(member)
                }
            }
        }
        return members.isEmpty ? first : .object(members)
    }

    /// The first choice that isn't just `null`, with the discriminating property set to name it.
    private mutating func choice(_ choices: [OpenAPINode], of schema: OpenAPINode, depth: Int, references: Set<String>) -> YAMLValue? {
        let chosen = choices.first { $0["type"]?.value.string != "null" } ?? choices[0]
        guard let value = example(chosen, depth: depth + 1, references: references) else {
            return nil
        }
        guard let property = schema["discriminator"]?["propertyName"]?.value.string, case .object(var members) = value,
              let reference = chosen.value["$ref"]?.string else {
            return value
        }
        let mapped = schema["discriminator"]?["mapping"]?.members.first { $0.node.value.string == reference }?.key
        let name = mapped ?? String(reference.split(separator: "/").last ?? "")
        if let index = members.firstIndex(where: { $0.key == property }) {
            members[index] = YAMLMember(key: property, value: .string(name))
        } else {
            members.insert(YAMLMember(key: property, value: .string(name)), at: 0)
        }
        return .object(members)
    }

    private mutating func typed(_ schema: OpenAPINode, depth: Int, references: Set<String>) -> YAMLValue? {
        switch Self.type(of: schema) {
        case "object": object(schema, depth: depth, references: references)
        case "array": array(schema, depth: depth, references: references)
        case "string": .string(Self.string(format: schema["format"]?.value.string))
        case "integer", "number": .number(Self.number(schema))
        case "boolean": .bool(true)
        case "null": .null
        default: nil
        }
    }

    /// Its `type`, the first that isn't `null` of a list of them, or what its keywords imply.
    static func type(of schema: OpenAPINode) -> String? {
        switch schema["type"]?.value {
        case .string(let type)?: return type
        case .array(let types)?: return types.compactMap(\.string).first { $0 != "null" } ?? "null"
        default: break
        }
        if schema["properties"] != nil || schema["additionalProperties"] != nil {
            return "object"
        }
        return schema["items"] != nil || schema["prefixItems"] != nil ? "array" : nil
    }

    private mutating func object(_ schema: OpenAPINode, depth: Int, references: Set<String>) -> YAMLValue {
        var members: [YAMLMember] = []
        for (name, property) in schema["properties"]?.members ?? [] {
            let resolved = resolver.resolveOrNil(property) ?? property
            guard property["readOnly"]?.value.bool != true, resolved["readOnly"]?.value.bool != true,
                  let value = example(property, depth: depth + 1, references: references) else {
                continue
            }
            members.append(YAMLMember(key: name, value: value))
        }
        if members.isEmpty, let additional = schema["additionalProperties"], additional.value != .bool(false) {
            let value = additional.value == .bool(true) ? nil : example(additional, depth: depth + 1, references: references)
            members.append(YAMLMember(key: "additionalProp1", value: value ?? .object([])))
        }
        return .object(members)
    }

    private mutating func array(_ schema: OpenAPINode, depth: Int, references: Set<String>) -> YAMLValue {
        if let prefix = schema["prefixItems"]?.elements {
            return .array(prefix.compactMap { example($0, depth: depth + 1, references: references) })
        }
        guard let items = schema["items"], let item = example(items, depth: depth + 1, references: references) else {
            return .array([])
        }
        return .array([item])
    }

    static func string(format: String?) -> String {
        switch format {
        case "date": "2026-01-01"
        case "date-time": "2026-01-01T00:00:00Z"
        case "time": "12:00:00"
        case "email", "idn-email": "user@example.com"
        case "uri", "url", "uri-reference", "iri", "iri-reference": "https://example.com"
        case "uuid": "3fa85f64-5717-4562-b3fc-2c963f66afa6"
        case "ipv4": "192.0.2.1"
        case "ipv6": "2001:db8::1"
        case "hostname", "idn-hostname": "example.com"
        case "byte": "c3RyaW5n"
        case "binary": ""
        case "password": "password"
        default: "string"
        }
    }

    /// Its `minimum`, one past an integer's 3.1 `exclusiveMinimum`, or 0.
    static func number(_ schema: OpenAPINode) -> String {
        if let minimum = schema["minimum"]?.value, case .number(let text) = minimum {
            return text
        }
        if case .number(let text)? = schema["exclusiveMinimum"]?.value, let bound = Int(text), schema["type"]?.value.string == "integer" {
            return String(bound + 1)
        }
        return "0"
    }
}

/// Schema examples, and what forms read from a schema, with any reference that couldn't be followed noted on `owner`.
extension OpenAPIPlanner {
    mutating func schemaExample(_ schema: OpenAPINode?, owner: ImportNote.Owner) -> YAMLValue? {
        guard let schema else {
            return nil
        }
        var generator = OpenAPISchemaExample(resolver: resolver, siblingsCombine: source.document.refSiblingsCombine)
        let value = generator.example(schema)
        for failure in generator.failures {
            note(owner, .reference, failure.message)
        }
        if generator.isCutShort {
            note(owner, .body, "Its example was cut short: its schema is larger than Reqling writes out.")
        }
        return value
    }

    /// The properties an object schema requires, its `allOf` parts' included.
    mutating func requiredProperties(_ schema: OpenAPINode?, owner: ImportNote.Owner) -> Set<String> {
        guard let schema = resolved(schema, owner: owner) else {
            return []
        }
        var required = Set((schema["required"]?.value.array ?? []).compactMap(\.string))
        for part in schema["allOf"]?.elements ?? [] {
            required.formUnion(requiredProperties(part, owner: owner))
        }
        return required
    }

    /// An object schema's properties in order, its `allOf` parts' included.
    mutating func objectProperties(_ schema: OpenAPINode?, owner: ImportNote.Owner) -> [(name: String, schema: OpenAPINode)] {
        guard let schema = resolved(schema, owner: owner) else {
            return []
        }
        var properties = (schema["properties"]?.members ?? []).map { (name: $0.key, schema: $0.node) }
        for part in schema["allOf"]?.elements ?? [] {
            properties += objectProperties(part, owner: owner).filter { part in !properties.contains { $0.name == part.name } }
        }
        return properties
    }
}
