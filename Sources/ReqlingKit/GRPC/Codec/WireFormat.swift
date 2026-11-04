/// The protobuf binary encoding's wire types. 3 and 4 delimit groups: proto2 groups and editions `DELIMITED` messages.
enum WireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case startGroup = 3
    case endGroup = 4
    case fixed32 = 5
}

/// One field's payload as the wire carries it, before the schema says what it means.
enum WireValue {
    case varint(UInt64)
    case fixed64(UInt64)
    case lengthDelimited(ArraySlice<UInt8>)
    case fixed32(UInt32)
    /// A group's body: the fields between its start- and end-group tags.
    case group(ArraySlice<UInt8>)

    var wireType: WireType {
        switch self {
        case .varint:
            .varint
        case .fixed64:
            .fixed64
        case .lengthDelimited:
            .lengthDelimited
        case .fixed32:
            .fixed32
        case .group:
            .startGroup
        }
    }

    /// All-zero bits or an empty payload: the value a proto3 implicit-presence field omits. Comparing bits rather than
    /// numbers keeps `-0.0`, which protobuf treats as set.
    var isDefault: Bool {
        switch self {
        case .varint(let value), .fixed64(let value):
            value == 0
        case .fixed32(let value):
            value == 0
        case .lengthDelimited(let payload):
            payload.isEmpty
        case .group:
            // Only messages are groups, and a message with presence is never omitted.
            false
        }
    }

    /// The numeric payload widened to 64 bits; zero for length-delimited values.
    var bits: UInt64 {
        switch self {
        case .varint(let value), .fixed64(let value):
            value
        case .fixed32(let value):
            UInt64(value)
        case .lengthDelimited, .group:
            0
        }
    }

    /// The zero value a field of `wireType` decodes to when the wire omits it, such as a map entry with no value.
    static func zero(for wireType: WireType) -> WireValue {
        switch wireType {
        case .fixed64:
            .fixed64(0)
        case .fixed32:
            .fixed32(0)
        case .lengthDelimited:
            .lengthDelimited([])
        case .startGroup:
            .group([])
        case .varint, .endGroup:
            .varint(0)
        }
    }

    static func zigzag(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> 63))
    }

    static func unzigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
    }
}

/// Appends tagged fields to a growing buffer. Nested messages are encoded into their own writer first, since a
/// length prefix needs the payload's size.
struct WireWriter {
    private(set) var bytes: [UInt8] = []

    mutating func write(_ value: WireValue, number: Int32) {
        writeTag(number, value.wireType)
        writePayload(value)
        if case .group = value {
            writeTag(number, .endGroup)
        }
    }

    /// The value without a tag, as packed repeated fields concatenate them.
    mutating func writePayload(_ value: WireValue) {
        switch value {
        case .varint(let value):
            writeVarint(value)
        case .fixed64(let value):
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        case .fixed32(let value):
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        case .lengthDelimited(let payload):
            writeVarint(UInt64(payload.count))
            bytes.append(contentsOf: payload)
        case .group(let body):
            bytes.append(contentsOf: body)
        }
    }

    private mutating func writeTag(_ number: Int32, _ wireType: WireType) {
        writeVarint(UInt64(UInt32(bitPattern: number) << 3 | UInt32(wireType.rawValue)))
    }

    private mutating func writeVarint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
    }
}

/// Reads tagged fields from a buffer. A group arrives whole, as its body, so unknown groups skip like any other
/// unknown field.
struct WireReader {
    /// protobuf's default recursion limit, which also bounds how deeply groups may nest within one scan.
    static let maxDepth = 100

    private let bytes: ArraySlice<UInt8>
    private var offset: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        offset = bytes.startIndex
    }

    /// The next field, or `nil` at the end of the buffer.
    mutating func next() throws(GRPCCodecError) -> (number: Int32, value: WireValue)? {
        guard offset < bytes.endIndex else {
            return nil
        }
        let (number, wireType) = try readTag()
        switch wireType {
        case .startGroup:
            return (number, .group(try readGroup(number, depth: 1)))
        case .endGroup:
            throw Self.malformed("an end-group tag without a matching start")
        default:
            return (number, try readValue(wireType))
        }
    }

    /// Splits a packed repeated field's payload into its elements.
    static func unpack(_ payload: ArraySlice<UInt8>, as wireType: WireType) throws(GRPCCodecError) -> [WireValue] {
        var reader = WireReader(payload)
        var values: [WireValue] = []
        while reader.offset < payload.endIndex {
            values.append(try reader.readValue(wireType))
        }
        return values
    }

    static func malformed(_ detail: String) -> GRPCCodecError {
        GRPCCodecError("Malformed protobuf: \(detail)")
    }

    private mutating func readTag() throws(GRPCCodecError) -> (Int32, WireType) {
        let tag = try readVarint()
        guard let wireType = WireType(rawValue: UInt8(tag & 7)) else {
            throw Self.malformed("unknown wire type \(tag & 7)")
        }
        let number = tag >> 3
        guard number > 0, number <= 536_870_911 else {
            throw Self.malformed("invalid field number \(number)")
        }
        return (Int32(number), wireType)
    }

    private mutating func readValue(_ wireType: WireType) throws(GRPCCodecError) -> WireValue {
        switch wireType {
        case .varint:
            return .varint(try readVarint())
        case .fixed64:
            return .fixed64(try readLittleEndian(byteCount: 8))
        case .fixed32:
            return .fixed32(UInt32(truncatingIfNeeded: try readLittleEndian(byteCount: 4)))
        case .lengthDelimited:
            let length = try readVarint()
            guard length <= UInt64(bytes.endIndex - offset) else {
                throw Self.malformed("a length-delimited field runs past the end of the message")
            }
            let end = offset + Int(length)
            defer { offset = end }
            return .lengthDelimited(bytes[offset..<end])
        case .startGroup, .endGroup:
            throw Self.malformed("a group where a value was expected")
        }
    }

    private mutating func readVarint() throws(GRPCCodecError) -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.endIndex, shift < 64 {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 {
                return result
            }
            shift += 7
        }
        throw Self.malformed(offset < bytes.endIndex ? "a varint longer than 10 bytes" : "a truncated varint")
    }

    private mutating func readLittleEndian(byteCount: Int) throws(GRPCCodecError) -> UInt64 {
        guard bytes.endIndex - offset >= byteCount else {
            throw Self.malformed("a truncated fixed-width value")
        }
        var result: UInt64 = 0
        for index in 0..<byteCount {
            result |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
        }
        offset += byteCount
        return result
    }

    /// Consumes a group through its matching end tag and returns the body before that tag.
    private mutating func readGroup(_ number: Int32, depth: Int) throws(GRPCCodecError) -> ArraySlice<UInt8> {
        guard depth <= Self.maxDepth else {
            throw Self.malformed("groups nested more than \(Self.maxDepth) deep")
        }
        let start = offset
        while offset < bytes.endIndex {
            let tagStart = offset
            let (innerNumber, wireType) = try readTag()
            switch wireType {
            case .startGroup:
                _ = try readGroup(innerNumber, depth: depth + 1)
            case .endGroup:
                guard innerNumber == number else {
                    throw Self.malformed("group \(number) ends with the tag of group \(innerNumber)")
                }
                return bytes[start..<tagStart]
            default:
                _ = try readValue(wireType)
            }
        }
        throw Self.malformed("group \(number) is never closed")
    }
}
