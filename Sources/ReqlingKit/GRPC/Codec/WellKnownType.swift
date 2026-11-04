/// The `google.protobuf` messages whose proto3 JSON form is not an object of their fields. `Empty` is absent: its
/// JSON is the ordinary `{}`, and an `Any` holding one carries no `value` member.
enum WellKnownType: String, CaseIterable {
    case any = "google.protobuf.Any"
    case timestamp = "google.protobuf.Timestamp"
    case duration = "google.protobuf.Duration"
    case fieldMask = "google.protobuf.FieldMask"
    case structObject = "google.protobuf.Struct"
    case value = "google.protobuf.Value"
    case listValue = "google.protobuf.ListValue"
    case doubleValue = "google.protobuf.DoubleValue"
    case floatValue = "google.protobuf.FloatValue"
    case int64Value = "google.protobuf.Int64Value"
    case uint64Value = "google.protobuf.UInt64Value"
    case int32Value = "google.protobuf.Int32Value"
    case uint32Value = "google.protobuf.UInt32Value"
    case boolValue = "google.protobuf.BoolValue"
    case stringValue = "google.protobuf.StringValue"
    case bytesValue = "google.protobuf.BytesValue"

    static let structEntryName = "google.protobuf.Struct.FieldsEntry"

    /// The type's fields, built in so the codec needs none of `google/protobuf/*.proto` to handle it.
    var schema: MessageSchema {
        Self.schemas[self] ?? MessageSchema(fullName: rawValue, fields: [])
    }

    /// Fallbacks for the plain messages the well-known types lean on, used when the registry lacks them.
    static let supportingSchemas: [String: MessageSchema] = [
        "google.protobuf.Empty": MessageSchema(fullName: "google.protobuf.Empty", fields: []),
        structEntryName: MessageSchema(fullName: structEntryName, fields: [
            FieldSchema(index: 0, number: 1, name: "key", kind: .string),
            FieldSchema(index: 1, number: 2, name: "value", kind: .message, typeName: WellKnownType.value.rawValue)
        ])
    ]

    private static let schemas = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeSchema()) })

    private func makeSchema() -> MessageSchema {
        MessageSchema(fullName: rawValue, fields: makeFields())
    }

    private func makeFields() -> [FieldSchema] {
        switch self {
        case .any:
            return [
                FieldSchema(index: 0, number: 1, name: "type_url", kind: .string),
                FieldSchema(index: 1, number: 2, name: "value", kind: .bytes)
            ]
        case .timestamp, .duration:
            return [
                FieldSchema(index: 0, number: 1, name: "seconds", kind: .int64),
                FieldSchema(index: 1, number: 2, name: "nanos", kind: .int32)
            ]
        case .fieldMask:
            return [FieldSchema(index: 0, number: 1, name: "paths", kind: .string, isRepeated: true)]
        case .structObject:
            return [
                FieldSchema(
                    index: 0, number: 1, name: "fields", kind: .message, typeName: Self.structEntryName, isRepeated: true, isMap: true
                )
            ]
        case .value:
            return valueFields()
        case .listValue:
            return [FieldSchema(index: 0, number: 1, name: "values", kind: .message, typeName: Self.value.rawValue, isRepeated: true)]
        default:
            return [FieldSchema(index: 0, number: 1, name: "value", kind: wrappedKind)]
        }
    }

    /// `Value`'s `kind` oneof, in field-number order.
    private func valueFields() -> [FieldSchema] {
        let members: [FieldSchema.Kind] = [.enum, .double, .string, .bool, .message, .message]
        let names = ["null_value", "number_value", "string_value", "bool_value", "struct_value", "list_value"]
        let typeNames = [ProtobufJSONCodec.nullValueEnum, "", "", "", Self.structObject.rawValue, Self.listValue.rawValue]
        return members.indices.map { index in
            FieldSchema(
                index: index,
                number: Int32(index + 1),
                name: names[index],
                kind: members[index],
                typeName: typeNames[index],
                hasPresence: true,
                oneofIndex: 0
            )
        }
    }

    /// A wrapper's `value` field type; meaningless for the other types.
    private var wrappedKind: FieldSchema.Kind {
        switch self {
        case .doubleValue:
            .double
        case .floatValue:
            .float
        case .int64Value:
            .int64
        case .uint64Value:
            .uint64
        case .int32Value:
            .int32
        case .uint32Value:
            .uint32
        case .boolValue:
            .bool
        case .bytesValue:
            .bytes
        default:
            .string
        }
    }
}

/// Field mask paths: snake_case in the binary form, lowerCamelCase joined by commas in JSON. Like protobuf's own
/// implementations, a path that cannot round-trip between the two is rejected rather than silently altered.
enum FieldMaskPaths {
    static func protoPaths(fromJSON text: String) throws(GRPCCodecError) -> [String] {
        guard !text.isEmpty else {
            return []
        }
        var paths: [String] = []
        for jsonPath in text.split(separator: ",", omittingEmptySubsequences: false) {
            var path = ""
            for character in jsonPath {
                switch character {
                case "A"..."Z":
                    path += "_" + character.lowercased()
                case "a"..."z", "0"..."9", ".":
                    path.append(character)
                default:
                    throw GRPCCodecError("`\(jsonPath)` is not a lowerCamelCase field mask path")
                }
            }
            guard !path.isEmpty else {
                throw GRPCCodecError("A field mask has an empty path")
            }
            paths.append(path)
        }
        return paths
    }

    static func jsonPath(fromProto path: String) throws(GRPCCodecError) -> String {
        let failure = GRPCCodecError("Field mask path `\(path)` has no lowerCamelCase form")
        var result = ""
        var capitalizeNext = false
        for character in path {
            let isLowercase = ("a"..."z").contains(character)
            if capitalizeNext {
                // Only a lowercase letter may follow an underscore, or the camelCase form would not map back.
                guard isLowercase else {
                    throw failure
                }
                result += character.uppercased()
                capitalizeNext = false
            } else if character == "_" {
                capitalizeNext = true
            } else if isLowercase || ("0"..."9").contains(character) || character == "." {
                result.append(character)
            } else {
                throw failure
            }
        }
        guard !capitalizeNext else {
            throw failure
        }
        return result
    }
}
