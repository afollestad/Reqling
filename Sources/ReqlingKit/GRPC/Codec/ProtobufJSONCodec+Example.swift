/// Placeholder messages for the editor's Example fill: each field at its default (enums at their first value,
/// well-known types in their JSON form), so the result always encodes and shows every field's shape.
extension ProtobufJSONCodec {
    /// Caps on one example. Expanding each type once per path still leaves mutually referencing messages
    /// factorially many paths (nine such types made 24 MB), and the editor builds examples on the main actor.
    struct ExampleBudget {
        static let maxDepth = 32
        var remainingFields = 1000
    }

    /// `ancestors` holds the messages enclosing this one, so a message that contains itself, directly or through
    /// others, stops at `{}` instead of recursing forever.
    func exampleMessage(_ typeName: String, ancestors: Set<String>, budget: inout ExampleBudget) -> OrderedJSON {
        if let wellKnown = WellKnownType(rawValue: typeName) {
            return exampleWellKnown(wellKnown)
        }
        guard !ancestors.contains(typeName),
              ancestors.count < ExampleBudget.maxDepth,
              budget.remainingFields > 0,
              let schema = try? schema(for: typeName)
        else {
            return .object([])
        }
        let nestedAncestors = ancestors.union([typeName])
        var setOneofs = Set<Int>()
        var members: [OrderedJSONMember] = []
        for field in schema.fields {
            // A oneof accepts one member, so only its first appears.
            if let oneof = field.oneofIndex, !setOneofs.insert(oneof).inserted {
                continue
            }
            budget.remainingFields -= 1
            let value = exampleField(field, ancestors: nestedAncestors, budget: &budget)
            members.append(OrderedJSONMember(key: field.jsonName, value: value))
        }
        return .object(members)
    }

    /// One element for a repeated field, and one entry for a map.
    private func exampleField(_ field: FieldSchema, ancestors: Set<String>, budget: inout ExampleBudget) -> OrderedJSON {
        if field.isMap {
            guard let entry = try? schema(for: field.typeName),
                  let keyField = entry.field(number: 1),
                  let valueField = entry.field(number: 2)
            else {
                return .object([])
            }
            let key = keyField.kind == .string ? "key" : Self.exampleKeyText(exampleScalar(keyField))
            return .object([OrderedJSONMember(key: key, value: exampleValue(valueField, ancestors: ancestors, budget: &budget))])
        }
        let value = exampleValue(field, ancestors: ancestors, budget: &budget)
        return field.isRepeated ? .array([value]) : value
    }

    private func exampleValue(_ field: FieldSchema, ancestors: Set<String>, budget: inout ExampleBudget) -> OrderedJSON {
        switch field.kind {
        case .message, .group:
            exampleMessage(field.typeName, ancestors: ancestors, budget: &budget)
        default:
            exampleScalar(field)
        }
    }

    private func exampleScalar(_ field: FieldSchema) -> OrderedJSON {
        guard field.kind == .enum else {
            return (try? scalarJSON(.zero(for: field.wireType ?? .varint), field: field)) ?? .null
        }
        if field.typeName == Self.nullValueEnum {
            return .null
        }
        guard let first = registry.enumType(field.typeName)?.value.first else {
            return .number("0")
        }
        return .string(first.name)
    }

    private func exampleWellKnown(_ type: WellKnownType) -> OrderedJSON {
        switch type {
        case .any, .structObject:
            .object([])
        case .timestamp:
            .string("1970-01-01T00:00:00Z")
        case .duration:
            .string("0s")
        case .fieldMask:
            .string("")
        case .value:
            .null
        case .listValue:
            .array([])
        default:
            type.schema.fields.first.map(exampleScalar) ?? .null
        }
    }

    private static func exampleKeyText(_ json: OrderedJSON) -> String {
        switch json {
        case .number(let text), .string(let text):
            text
        case .bool(let flag):
            flag ? "true" : "false"
        default:
            ""
        }
    }
}
