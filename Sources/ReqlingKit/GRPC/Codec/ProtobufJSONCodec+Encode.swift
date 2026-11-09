/// proto3 JSON to wire bytes. Fields are written in declaration order, repeated scalars packed, and proto3 implicit
/// fields omitted at their default; fields with presence (`optional`, oneof members, messages) are always written.
extension ProtobufJSONCodec {
    func encodeMessage(_ json: OrderedJSON, typeName: String, depth: Int) throws(GRPCCodecError) -> [UInt8] {
        try checkDepth(depth)
        if let wellKnown = WellKnownType(rawValue: typeName) {
            return try encodeWellKnown(json, as: wellKnown, depth: depth)
        }
        guard case .object(let members) = json else {
            throw Self.mismatch(expected: "an object for \(typeName)", got: json)
        }
        return try encodeFields(members, schema: try schema(for: typeName), depth: depth)
    }

    /// Checks that every key names a field, none is given twice under either of its names, and at most one member of
    /// each oneof is set, before writing anything.
    func encodeFields(
        _ members: [OrderedJSONMember],
        schema: MessageSchema,
        depth: Int
    ) throws(GRPCCodecError) -> [UInt8] {
        var assigned: [Int: OrderedJSONMember] = [:]
        var oneofKeys: [Int: String] = [:]
        for member in members {
            guard let field = schema.field(named: member.key) else {
                throw GRPCCodecError("Unknown field of \(schema.fullName)", path: member.key)
            }
            guard assigned[field.index] == nil else {
                throw GRPCCodecError("Field is set more than once", path: member.key)
            }
            assigned[field.index] = member
            guard let oneof = field.oneofIndex, !Self.isUnset(member.value, field: field) else {
                continue
            }
            if let other = oneofKeys[oneof] {
                throw GRPCCodecError("Only one field of a oneof may be set, and `\(other)` already is", path: member.key)
            }
            oneofKeys[oneof] = member.key
        }
        var writer = WireWriter()
        for field in schema.fields {
            guard let member = assigned[field.index] else {
                continue
            }
            try within(member.key) { () throws(GRPCCodecError) in
                try encodeField(member.value, field: field, into: &writer, depth: depth)
            }
        }
        return writer.bytes
    }

    /// Writes each element of a JSON array as one element of `field`, packing scalars into a single record.
    func encodeRepeated(
        _ json: OrderedJSON,
        field: FieldSchema,
        into writer: inout WireWriter,
        depth: Int
    ) throws(GRPCCodecError) {
        guard case .array(let items) = json else {
            throw Self.mismatch(expected: "an array", got: json)
        }
        var packed = WireWriter()
        for (index, item) in items.enumerated() {
            let value = try within("[\(index)]") { () throws(GRPCCodecError) -> WireValue in
                try elementValue(item, field: field, depth: depth)
            }
            if field.isPackable {
                packed.writePayload(value)
            } else {
                writer.write(value, number: field.number)
            }
        }
        if !packed.bytes.isEmpty {
            writer.write(.lengthDelimited(packed.bytes[...]), number: field.number)
        }
    }

    /// Writes each member of a JSON object as one `key`/`value` entry message. Both are always written, so an entry
    /// never depends on a reader filling in defaults.
    func encodeMap(
        _ json: OrderedJSON,
        field: FieldSchema,
        into writer: inout WireWriter,
        depth: Int
    ) throws(GRPCCodecError) {
        guard case .object(let members) = json else {
            throw Self.mismatch(expected: "an object", got: json)
        }
        let entry = try schema(for: field.typeName)
        guard let keyField = entry.field(number: 1), let valueField = entry.field(number: 2) else {
            throw GRPCCodecError("`\(field.typeName)` is not a map entry")
        }
        for member in members {
            try within(Self.keySegment(member.key)) { () throws(GRPCCodecError) in
                var entryWriter = WireWriter()
                entryWriter.write(try mapKey(member.key, field: keyField), number: keyField.number)
                entryWriter.write(try elementValue(member.value, field: valueField, depth: depth), number: valueField.number)
                writer.write(.lengthDelimited(entryWriter.bytes[...]), number: field.number)
            }
        }
    }

    /// JSON `null` stands for a field's default, so it writes nothing, except where it is itself a value:
    /// `google.protobuf.Value` (`NullValue`) and a `NullValue` enum.
    static func isUnset(_ json: OrderedJSON, field: FieldSchema) -> Bool {
        json == .null && (field.isRepeated || !carriesNull(field.typeName))
    }

    static func carriesNull(_ typeName: String) -> Bool {
        typeName == WellKnownType.value.rawValue || typeName == nullValueEnum
    }

    private func encodeField(
        _ json: OrderedJSON,
        field: FieldSchema,
        into writer: inout WireWriter,
        depth: Int
    ) throws(GRPCCodecError) {
        if Self.isUnset(json, field: field) {
            return
        }
        if field.isMap {
            try encodeMap(json, field: field, into: &writer, depth: depth)
        } else if field.isRepeated {
            try encodeRepeated(json, field: field, into: &writer, depth: depth)
        } else {
            let value = try wireValue(json, field: field, depth: depth)
            if field.hasPresence || !value.isDefault {
                writer.write(value, number: field.number)
            }
        }
    }

    /// A repeated element or map value, which, unlike a field, cannot be `null` unless `null` is its value.
    private func elementValue(_ json: OrderedJSON, field: FieldSchema, depth: Int) throws(GRPCCodecError) -> WireValue {
        if json == .null, !Self.carriesNull(field.typeName) {
            throw GRPCCodecError("Expected a value, got null")
        }
        return try wireValue(json, field: field, depth: depth)
    }

    /// JSON map keys are always strings: integer keys spell their number, and bool keys `true` or `false`.
    private func mapKey(_ key: String, field: FieldSchema) throws(GRPCCodecError) -> WireValue {
        switch field.kind {
        case .bool:
            guard key == "true" || key == "false" else {
                throw GRPCCodecError("A bool map key must be `true` or `false`")
            }
            return .varint(key == "true" ? 1 : 0)
        case .string:
            return .lengthDelimited(ArraySlice(key.utf8))
        default:
            return try wireValue(.string(key), field: field, depth: 0)
        }
    }
}
