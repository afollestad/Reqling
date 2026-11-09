/// Wire bytes to proto3 JSON, following protobuf's parsing rules: unknown fields are skipped, a singular scalar keeps
/// its last value, a singular message merges every occurrence, and repeated scalars may arrive packed or not.
///
/// Every function here adds the fields it skipped to `unknown`, so a caller can say the JSON is missing data a newer
/// schema would show.
extension ProtobufJSONCodec {
    func decodeMessage(
        _ bytes: ArraySlice<UInt8>,
        typeName: String,
        depth: Int,
        unknown: inout Int
    ) throws(GRPCCodecError) -> OrderedJSON {
        try checkDepth(depth)
        if let wellKnown = WellKnownType(rawValue: typeName) {
            return try decodeWellKnown(bytes, as: wellKnown, depth: depth, unknown: &unknown)
        }
        let schema = try schema(for: typeName)
        let collected = try collect(bytes, schema: schema, unknown: &unknown)
        var members: [OrderedJSONMember] = []
        for field in schema.fields where !collected[field.index].isEmpty {
            let json = try within(field.jsonName) { () throws(GRPCCodecError) -> OrderedJSON? in
                try fieldJSON(collected[field.index], field: field, depth: depth, unknown: &unknown)
            }
            if let json {
                members.append(OrderedJSONMember(key: field.jsonName, value: json))
            }
        }
        return .object(members)
    }

    /// Each field's wire values in arrival order, indexed like `schema.fields`. Setting one oneof member clears the
    /// others, and a known field with an incompatible wire type is skipped like an unknown one, as protobuf does.
    ///
    /// Adds the distinct field numbers it skipped to `unknown`, so a repeated unknown field counts once per message.
    func collect(_ bytes: ArraySlice<UInt8>, schema: MessageSchema, unknown: inout Int) throws(GRPCCodecError) -> [[WireValue]] {
        var collected = [[WireValue]](repeating: [], count: schema.fields.count)
        var oneofMembers: [Int: Int] = [:]
        var skipped = Set<Int32>()
        defer { unknown += skipped.count }
        var reader = WireReader(bytes)
        while let wire = try reader.next() {
            guard let field = schema.field(number: wire.number), let values = try Self.values(wire.value, for: field) else {
                skipped.insert(wire.number)
                continue
            }
            if field.isRepeated || field.kind == .message {
                collected[field.index] += values
            } else {
                collected[field.index] = values
            }
            if let oneof = field.oneofIndex {
                if let previous = oneofMembers[oneof], previous != field.index {
                    collected[previous] = []
                }
                oneofMembers[oneof] = field.index
            }
        }
        return collected
    }

    /// A non-repeated field's value whether or not it is the default, as map entries and well-known types need.
    func presentJSON(_ values: [WireValue], field: FieldSchema, depth: Int, unknown: inout Int) throws(GRPCCodecError) -> OrderedJSON {
        if field.kind == .message {
            return try decodeMessage(Self.merged(values), typeName: field.typeName, depth: depth + 1, unknown: &unknown)
        }
        return try scalarJSON(values.last ?? .zero(for: field.wireType ?? .varint), field: field)
    }

    /// A repeated field's elements, or a map's entries as an object in wire order with later duplicates winning.
    func repeatedJSON(_ values: [WireValue], field: FieldSchema, depth: Int, unknown: inout Int) throws(GRPCCodecError) -> OrderedJSON {
        if field.isMap {
            return try mapJSON(values, field: field, depth: depth, unknown: &unknown)
        }
        var items: [OrderedJSON] = []
        items.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            items.append(try within("[\(index)]") { () throws(GRPCCodecError) -> OrderedJSON in
                try presentJSON([value], field: field, depth: depth, unknown: &unknown)
            })
        }
        return .array(items)
    }

    /// `nil` for a proto3 implicit field at its default, which the JSON mapping omits.
    private func fieldJSON(_ values: [WireValue], field: FieldSchema, depth: Int, unknown: inout Int) throws(GRPCCodecError) -> OrderedJSON? {
        if field.isRepeated {
            return try repeatedJSON(values, field: field, depth: depth, unknown: &unknown)
        }
        if field.kind != .message, !field.hasPresence, values.last?.isDefault ?? true {
            return nil
        }
        return try presentJSON(values, field: field, depth: depth, unknown: &unknown)
    }

    private func mapJSON(_ values: [WireValue], field: FieldSchema, depth: Int, unknown: inout Int) throws(GRPCCodecError) -> OrderedJSON {
        let entry = try schema(for: field.typeName)
        guard let keyField = entry.field(number: 1), let valueField = entry.field(number: 2) else {
            throw GRPCCodecError("`\(field.typeName)` is not a map entry")
        }
        var keys: [String] = []
        var entries: [String: OrderedJSON] = [:]
        for case .lengthDelimited(let payload) in values {
            let collected = try collect(payload, schema: entry, unknown: &unknown)
            let key = Self.mapKeyText(try presentJSON(collected[keyField.index], field: keyField, depth: depth, unknown: &unknown))
            let value = try within(Self.keySegment(key)) { () throws(GRPCCodecError) -> OrderedJSON in
                try presentJSON(collected[valueField.index], field: valueField, depth: depth, unknown: &unknown)
            }
            if entries.updateValue(value, forKey: key) == nil {
                keys.append(key)
            }
        }
        return .object(keys.compactMap { key in entries[key].map { OrderedJSONMember(key: key, value: $0) } })
    }

    private static func mapKeyText(_ json: OrderedJSON) -> String {
        switch json {
        case .string(let text), .number(let text):
            text
        case .bool(let flag):
            flag ? "true" : "false"
        default:
            ""
        }
    }

    /// `value` as `field`'s elements: itself when the wire type matches, a packed run's elements for a repeated
    /// scalar, or `nil` for a wire type the field cannot hold.
    private static func values(_ value: WireValue, for field: FieldSchema) throws(GRPCCodecError) -> [WireValue]? {
        guard let expected = field.wireType else {
            return nil
        }
        if value.wireType == expected {
            return [value]
        }
        if field.isRepeated, field.isPackable, case .lengthDelimited(let payload) = value {
            return try WireReader.unpack(payload, as: expected)
        }
        return nil
    }

    /// Concatenated payloads parse as their merge, protobuf's rule for a singular message seen more than once. A
    /// group's body is a message payload too.
    private static func merged(_ values: [WireValue]) -> ArraySlice<UInt8> {
        let payloads = values.compactMap { value -> ArraySlice<UInt8>? in
            switch value {
            case .lengthDelimited(let payload), .group(let payload):
                payload
            default:
                nil
            }
        }
        guard payloads.count > 1 else {
            return payloads.first ?? []
        }
        return ArraySlice(payloads.joined())
    }
}

extension FieldSchema {
    /// The wire type this field's values use unpacked.
    var wireType: WireType? {
        switch kind {
        case .double, .fixed64, .sfixed64:
            .fixed64
        case .float, .fixed32, .sfixed32:
            .fixed32
        case .string, .bytes:
            .lengthDelimited
        case .message, .group:
            isDelimited ? .startGroup : .lengthDelimited
        default:
            .varint
        }
    }
}
