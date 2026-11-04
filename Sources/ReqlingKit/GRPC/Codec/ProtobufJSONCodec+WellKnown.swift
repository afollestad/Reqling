/// The well-known types' JSON forms in both directions. Each works from its built-in `WellKnownType.schema`, so only
/// an `Any`'s payload type has to be in the registry.
extension ProtobufJSONCodec {
    /// Checks depth itself, since an `Any` reaches here directly for a well-known payload.
    func encodeWellKnown(_ json: ProtoJSONValue, as type: WellKnownType, depth: Int) throws(GRPCCodecError) -> [UInt8] {
        try checkDepth(depth)
        let field = type.schema.fields[0]
        var writer = WireWriter()
        switch type {
        case .any:
            return try encodeAny(json, depth: depth)
        case .timestamp, .duration:
            let instant = try Self.instant(json, as: type)
            if instant.seconds != 0 {
                writer.write(.varint(UInt64(bitPattern: instant.seconds)), number: 1)
            }
            if instant.nanos != 0 {
                writer.write(.varint(UInt64(bitPattern: Int64(instant.nanos))), number: 2)
            }
        case .fieldMask:
            guard case .string(let text) = json else {
                throw Self.mismatch(expected: "a field mask string such as \"user.displayName,photo\"", got: json)
            }
            for path in try FieldMaskPaths.protoPaths(fromJSON: text) {
                writer.write(.lengthDelimited(ArraySlice(path.utf8)), number: field.number)
            }
        case .structObject:
            try encodeMap(json, field: field, into: &writer, depth: depth)
        case .listValue:
            try encodeRepeated(json, field: field, into: &writer, depth: depth)
        case .value:
            try encodeValue(json, into: &writer, depth: depth)
        default:
            let value = try wireValue(json, field: field, depth: depth)
            if !value.isDefault {
                writer.write(value, number: field.number)
            }
        }
        return writer.bytes
    }

    /// Checks depth itself, since an `Any` reaches here directly for a well-known payload; otherwise a server could
    /// nest `Any`s until the stack overflows.
    func decodeWellKnown(
        _ bytes: ArraySlice<UInt8>,
        as type: WellKnownType,
        depth: Int,
        unknown: inout Int
    ) throws(GRPCCodecError) -> ProtoJSONValue {
        try checkDepth(depth)
        let schema = type.schema
        let collected = try collect(bytes, schema: schema, unknown: &unknown)
        switch type {
        case .any:
            return try decodeAny(collected, depth: depth, unknown: &unknown)
        case .timestamp, .duration:
            let instant = ProtoTime.Instant(
                seconds: Int64(bitPattern: collected[0].last?.bits ?? 0),
                nanos: Int32(truncatingIfNeeded: collected[1].last?.bits ?? 0)
            )
            return .string(type == .timestamp ? try ProtoTime.formatTimestamp(instant) : try ProtoTime.formatDuration(instant))
        case .fieldMask:
            var paths: [String] = []
            for case .string(let path) in try repeatedJSON(collected[0], field: schema.fields[0], depth: depth, unknown: &unknown).arrayItems {
                paths.append(try FieldMaskPaths.jsonPath(fromProto: path))
            }
            return .string(paths.joined(separator: ","))
        case .structObject, .listValue:
            return try repeatedJSON(collected[0], field: schema.fields[0], depth: depth, unknown: &unknown)
        case .value:
            // `kind` is a oneof, so `collect` has left at most one member set; none set reads as null.
            guard let member = schema.fields.first(where: { !collected[$0.index].isEmpty }) else {
                return .null
            }
            let values = collected[member.index]
            if member.kind == .double, !Double(bitPattern: values.last?.bits ?? 0).isFinite {
                throw GRPCCodecError("A google.protobuf.Value number cannot be NaN or infinite in JSON")
            }
            return try presentJSON(values, field: member, depth: depth, unknown: &unknown)
        default:
            return try presentJSON(collected[0], field: schema.fields[0], depth: depth, unknown: &unknown)
        }
    }

    private static func instant(_ json: ProtoJSONValue, as type: WellKnownType) throws(GRPCCodecError) -> ProtoTime.Instant {
        guard case .string(let text) = json else {
            let expected = type == .timestamp ? "an RFC 3339 timestamp string" : "a duration string such as \"1.5s\""
            throw mismatch(expected: expected, got: json)
        }
        return type == .timestamp ? try ProtoTime.parseTimestamp(text) : try ProtoTime.parseDuration(text)
    }

    /// `Value` is plain JSON: each JSON type sets the matching member of its `kind` oneof.
    private func encodeValue(_ json: ProtoJSONValue, into writer: inout WireWriter, depth: Int) throws(GRPCCodecError) {
        switch json {
        case .null:
            writer.write(.varint(0), number: 1)
        case .number(let text):
            guard let number = Double(text), number.isFinite else {
                throw GRPCCodecError("\(text) is out of range for a double")
            }
            writer.write(.fixed64(number.bitPattern), number: 2)
        case .string(let text):
            writer.write(.lengthDelimited(ArraySlice(text.utf8)), number: 3)
        case .bool(let flag):
            writer.write(.varint(flag ? 1 : 0), number: 4)
        case .object:
            let payload = try encodeMessage(json, typeName: WellKnownType.structObject.rawValue, depth: depth + 1)
            writer.write(.lengthDelimited(payload[...]), number: 5)
        case .array:
            let payload = try encodeMessage(json, typeName: WellKnownType.listValue.rawValue, depth: depth + 1)
            writer.write(.lengthDelimited(payload[...]), number: 6)
        }
    }

    /// `{"@type": url, ...fields}`, or `{"@type": url, "value": json}` when the payload is itself a well-known type.
    private func encodeAny(_ json: ProtoJSONValue, depth: Int) throws(GRPCCodecError) -> [UInt8] {
        guard case .object(let members) = json else {
            throw Self.mismatch(expected: "an object with an `@type`", got: json)
        }
        guard let typeMember = members.first(where: { $0.key == "@type" }) else {
            guard members.isEmpty else {
                throw GRPCCodecError("An Any needs an `@type` naming its message type")
            }
            return []
        }
        let (typeURL, typeName) = try within("@type") { () throws(GRPCCodecError) -> (String, String) in
            guard case .string(let typeURL) = typeMember.value else {
                throw Self.mismatch(expected: "a type URL string", got: typeMember.value)
            }
            return (typeURL, try anyPayloadType(typeURL))
        }
        let fields = members.filter { $0.key != "@type" }
        let payload: [UInt8]
        if typeName == Self.emptyType, fields.count == 1, fields.first?.key == "value", fields.first?.value == .object([]) {
            // Go's protojson writes an Empty payload in the well-known `value` form; accept it alongside the plain one.
            payload = []
        } else if let wellKnown = WellKnownType(rawValue: typeName) {
            guard fields.count == 1, let value = fields.first, value.key == "value" else {
                throw GRPCCodecError("An Any holding \(typeName) takes its JSON form in `value`, and no other fields")
            }
            payload = try within("value") { () throws(GRPCCodecError) -> [UInt8] in
                try encodeWellKnown(value.value, as: wellKnown, depth: depth + 1)
            }
        } else {
            try checkDepth(depth + 1)
            payload = try encodeFields(fields, schema: try schema(for: typeName), depth: depth + 1)
        }
        var writer = WireWriter()
        writer.write(.lengthDelimited(ArraySlice(typeURL.utf8)), number: 1)
        if !payload.isEmpty {
            writer.write(.lengthDelimited(payload[...]), number: 2)
        }
        return writer.bytes
    }

    private func decodeAny(_ collected: [[WireValue]], depth: Int, unknown: inout Int) throws(GRPCCodecError) -> ProtoJSONValue {
        let schema = WellKnownType.any.schema
        let typeURL = try presentJSON(collected[0], field: schema.fields[0], depth: depth, unknown: &unknown)
        guard case .string(let typeURL) = typeURL, !typeURL.isEmpty else {
            guard collected[1].isEmpty else {
                throw GRPCCodecError("An Any has a payload but no type URL")
            }
            return .object([])
        }
        let typeName = try within("@type") { () throws(GRPCCodecError) -> String in try anyPayloadType(typeURL) }
        var payload: ArraySlice<UInt8> = []
        if case .lengthDelimited(let bytes) = collected[1].last {
            payload = bytes
        }
        let typeMember = ProtoJSONMember(key: "@type", value: .string(typeURL))
        if let wellKnown = WellKnownType(rawValue: typeName) {
            let value = try within("value") { () throws(GRPCCodecError) -> ProtoJSONValue in
                try decodeWellKnown(payload, as: wellKnown, depth: depth + 1, unknown: &unknown)
            }
            return .object([typeMember, ProtoJSONMember(key: "value", value: value)])
        }
        guard case .object(let members) = try decodeMessage(payload, typeName: typeName, depth: depth + 1, unknown: &unknown) else {
            return .object([typeMember])
        }
        return .object([typeMember] + members)
    }

    private static let emptyType = "google.protobuf.Empty"

    /// The message an Any's type URL names: the text after its last `/`, which the registry must define.
    private func anyPayloadType(_ typeURL: String) throws(GRPCCodecError) -> String {
        guard let slash = typeURL.lastIndex(of: "/"), typeURL.index(after: slash) < typeURL.endIndex else {
            throw GRPCCodecError("`\(typeURL)` is not a type URL such as type.googleapis.com/package.Message")
        }
        let name = String(typeURL[typeURL.index(after: slash)...])
        guard WellKnownType(rawValue: name) != nil || (try? schema(for: name)) != nil else {
            throw GRPCCodecError("The Any's type `\(name)` is not defined in the loaded schema; load its .proto to use it")
        }
        return name
    }
}

extension ProtoJSONValue {
    /// An array's elements; empty for any other value.
    var arrayItems: [ProtoJSONValue] {
        guard case .array(let items) = self else {
            return []
        }
        return items
    }
}
