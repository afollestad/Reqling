import Foundation

/// Single values in both directions: proto3 JSON scalars, enums, and nested messages to and from `WireValue`s.
/// Every 64-bit integer reads from a number or a string and writes as a string, since JSON numbers are doubles to
/// most consumers; floats use `"NaN"` and `"Infinity"` strings, and bytes are base64.
extension ProtobufJSONCodec {
    static let nullValueEnum = "google.protobuf.NullValue"

    /// Encodes one non-repeated value of `field`'s type.
    func wireValue(_ json: OrderedJSON, field: FieldSchema, depth: Int) throws(GRPCCodecError) -> WireValue {
        switch field.kind {
        case .bool:
            guard case .bool(let value) = json else {
                throw Self.mismatch(expected: "a boolean", got: json)
            }
            return .varint(value ? 1 : 0)
        case .string:
            guard case .string(let value) = json else {
                throw Self.mismatch(expected: "a string", got: json)
            }
            return .lengthDelimited(ArraySlice(value.utf8))
        case .bytes:
            return .lengthDelimited(ArraySlice(try Self.base64Bytes(json)))
        case .enum:
            return .varint(UInt64(bitPattern: Int64(try enumNumber(json, typeName: field.typeName))))
        case .message, .group:
            let payload = ArraySlice(try encodeMessage(json, typeName: field.typeName, depth: depth + 1))
            return field.isDelimited ? .group(payload) : .lengthDelimited(payload)
        default:
            return try Self.numericWireValue(json, kind: field.kind)
        }
    }

    private static func numericWireValue(_ json: OrderedJSON, kind: FieldSchema.Kind) throws(GRPCCodecError) -> WireValue {
        let int32Range = (min: Int64(Int32.min), max: Int64(Int32.max))
        switch kind {
        case .double:
            return .fixed64(try floatingPoint(json, as: Double.self).bitPattern)
        case .float:
            return .fixed32(try floatingPoint(json, as: Float.self).bitPattern)
        case .int64:
            return .varint(UInt64(bitPattern: try signedInteger(json, min: .min, max: .max, label: "int64")))
        case .sint64:
            return .varint(WireValue.zigzag(try signedInteger(json, min: .min, max: .max, label: "sint64")))
        case .sfixed64:
            return .fixed64(UInt64(bitPattern: try signedInteger(json, min: .min, max: .max, label: "sfixed64")))
        case .int32:
            // Negative values sign-extend to ten varint bytes, as protobuf specifies.
            return .varint(UInt64(bitPattern: try signedInteger(json, min: int32Range.min, max: int32Range.max, label: "int32")))
        case .sint32:
            // The 64-bit zigzag of an int32 equals its 32-bit zigzag.
            return .varint(WireValue.zigzag(try signedInteger(json, min: int32Range.min, max: int32Range.max, label: "sint32")))
        case .sfixed32:
            let value = try signedInteger(json, min: int32Range.min, max: int32Range.max, label: "sfixed32")
            return .fixed32(UInt32(truncatingIfNeeded: value))
        case .uint64:
            return .varint(try unsignedInteger(json, max: .max, label: "uint64"))
        case .fixed64:
            return .fixed64(try unsignedInteger(json, max: .max, label: "fixed64"))
        case .uint32:
            return .varint(try unsignedInteger(json, max: UInt64(UInt32.max), label: "uint32"))
        case .fixed32:
            return .fixed32(UInt32(truncatingIfNeeded: try unsignedInteger(json, max: UInt64(UInt32.max), label: "fixed32")))
        default:
            throw GRPCCodecError("Field type \(kind.rawValue) is not numeric")
        }
    }

    /// Decodes one value of a scalar or enum field; messages go through `decodeMessage`.
    func scalarJSON(_ value: WireValue, field: FieldSchema) throws(GRPCCodecError) -> OrderedJSON {
        let bits = value.bits
        switch field.kind {
        case .double:
            return Self.floatingPointJSON(Double(bitPattern: bits))
        case .float:
            return Self.floatingPointJSON(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case .int64, .sfixed64:
            return .string(String(Int64(bitPattern: bits)))
        case .sint64:
            return .string(String(WireValue.unzigzag(bits)))
        case .uint64, .fixed64:
            return .string(String(bits))
        case .int32, .sfixed32:
            return .number(String(Int32(truncatingIfNeeded: bits)))
        case .sint32:
            return .number(String(Int32(truncatingIfNeeded: WireValue.unzigzag(UInt64(UInt32(truncatingIfNeeded: bits))))))
        case .uint32, .fixed32:
            return .number(String(UInt32(truncatingIfNeeded: bits)))
        case .bool:
            return .bool(bits != 0)
        case .enum:
            return enumJSON(Int32(truncatingIfNeeded: bits), typeName: field.typeName)
        case .string:
            guard case .lengthDelimited(let payload) = value, let text = String(validating: payload, as: UTF8.self) else {
                throw GRPCCodecError("A string field holds invalid UTF-8")
            }
            return .string(text)
        case .bytes:
            guard case .lengthDelimited(let payload) = value else {
                return .string("")
            }
            return .string(Data(payload).base64EncodedString())
        case .message, .group:
            throw GRPCCodecError("`\(field.name)` is not a scalar field")
        }
    }

    /// Accepts an enum value's name or number. `NullValue` also accepts JSON `null`, its JSON form.
    func enumNumber(_ json: OrderedJSON, typeName: String) throws(GRPCCodecError) -> Int32 {
        if typeName == Self.nullValueEnum, json == .null || json == .string("NULL_VALUE") {
            return 0
        }
        switch json {
        case .string(let name):
            guard let enumType = registry.enumType(typeName) else {
                throw GRPCCodecError("`\(typeName)` is not defined in the loaded schema")
            }
            guard let value = enumType.value.first(where: { $0.name == name }) else {
                throw GRPCCodecError("`\(name)` is not a value of \(typeName)")
            }
            return value.number
        case .number:
            let number = try Self.signedInteger(json, min: Int64(Int32.min), max: Int64(Int32.max), label: "enum number")
            return Int32(truncatingIfNeeded: number)
        default:
            throw Self.mismatch(expected: "an enum name or number", got: json)
        }
    }

    /// The value's name, or its number when the schema predates it: proto3 enums are open.
    func enumJSON(_ number: Int32, typeName: String) -> OrderedJSON {
        if typeName == Self.nullValueEnum {
            return .null
        }
        guard let name = registry.enumType(typeName)?.value.first(where: { $0.number == number })?.name else {
            return .number(String(number))
        }
        return .string(name)
    }

    static func signedInteger(
        _ json: OrderedJSON,
        min: Int64,
        max: Int64,
        label: String
    ) throws(GRPCCodecError) -> Int64 {
        let (number, text) = try integerNumber(json, label: label)
        guard case .exact(let isNegative, let magnitude) = number.integer else {
            throw integerFailure(number, text: text, label: label)
        }
        let limit = isNegative ? min.magnitude : UInt64(max)
        guard magnitude <= limit else {
            throw GRPCCodecError("\(text) is out of range for \(label)")
        }
        // Two's-complement negation, which also reaches `Int64.min`.
        return isNegative ? Int64(bitPattern: 0 &- magnitude) : Int64(magnitude)
    }

    static func unsignedInteger(_ json: OrderedJSON, max: UInt64, label: String) throws(GRPCCodecError) -> UInt64 {
        let (number, text) = try integerNumber(json, label: label)
        guard case .exact(let isNegative, let magnitude) = number.integer else {
            throw integerFailure(number, text: text, label: label)
        }
        guard !isNegative || magnitude == 0, magnitude <= max else {
            throw GRPCCodecError("\(text) is out of range for \(label)")
        }
        return magnitude
    }

    private static func integerNumber(
        _ json: OrderedJSON,
        label: String
    ) throws(GRPCCodecError) -> (ProtoJSONNumber, String) {
        let text: String
        switch json {
        case .number(let literal), .string(let literal):
            text = literal
        default:
            throw mismatch(expected: "\(label) as a number or string", got: json)
        }
        guard let number = ProtoJSONNumber(text) else {
            throw GRPCCodecError("`\(text)` is not a number")
        }
        return (number, text)
    }

    private static func integerFailure(_ number: ProtoJSONNumber, text: String, label: String) -> GRPCCodecError {
        if case .fractional = number.integer {
            return GRPCCodecError("\(text) is not an integer")
        }
        return GRPCCodecError("\(text) is out of range for \(label)")
    }

    static func floatingPoint<Value: BinaryFloatingPoint & LosslessStringConvertible>(
        _ json: OrderedJSON,
        as type: Value.Type
    ) throws(GRPCCodecError) -> Value {
        let label = type == Float.self ? "float" : "double"
        let text: String
        switch json {
        case .string("NaN"):
            return .nan
        case .string("Infinity"):
            return .infinity
        case .string("-Infinity"):
            return -.infinity
        case .number(let literal), .string(let literal):
            text = literal
        default:
            throw mismatch(expected: "a \(label) as a number or string", got: json)
        }
        guard ProtoJSONNumber(text) != nil, let value = Value(text) else {
            throw GRPCCodecError("`\(text)` is not a number")
        }
        guard value.isFinite else {
            throw GRPCCodecError("\(text) is out of range for \(label)")
        }
        return value
    }

    /// Shortest round-trip text, without Swift's trailing `.0`.
    static func floatingPointJSON<Value: BinaryFloatingPoint & CustomStringConvertible>(_ value: Value) -> OrderedJSON {
        if value.isNaN {
            return .string("NaN")
        }
        if value.isInfinite {
            return .string(value < 0 ? "-Infinity" : "Infinity")
        }
        let text = value.description
        return .number(text.hasSuffix(".0") ? String(text.dropLast(2)) : text)
    }

    /// Standard base64, padded or not; URL-safe base64 is accepted too.
    static func base64Bytes(_ json: OrderedJSON) throws(GRPCCodecError) -> [UInt8] {
        guard case .string(let text) = json else {
            throw mismatch(expected: "base64 bytes as a string", got: json)
        }
        var standard = String(text.map { $0 == "-" ? "+" : $0 == "_" ? "/" : $0 })
        let remainder = standard.utf8.count % 4
        if remainder > 1, !standard.hasSuffix("=") {
            standard += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: standard) else {
            throw GRPCCodecError("Not valid base64")
        }
        return Array(data)
    }
}
