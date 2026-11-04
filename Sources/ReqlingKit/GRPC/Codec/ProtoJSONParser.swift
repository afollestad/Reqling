/// A strict RFC 8259 parser into `ProtoJSONValue`, reporting the line and column of the first syntax error.
struct ProtoJSONParser {
    /// Matches protobuf's recursion limit, and keeps hostile nesting from exhausting the stack.
    static let maxDepth = 100

    private let bytes: [UInt8]
    private var offset = 0
    private var depth = 0

    private init(_ text: String) {
        bytes = Array(text.utf8)
    }

    static func parse(_ text: String) throws(GRPCCodecError) -> ProtoJSONValue {
        var parser = ProtoJSONParser(text)
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.offset == parser.bytes.count else {
            throw parser.failure("unexpected text after the JSON value")
        }
        return value
    }

    private mutating func parseValue() throws(GRPCCodecError) -> ProtoJSONValue {
        guard let byte = peek() else {
            throw failure("unexpected end of input")
        }
        switch byte {
        case UInt8(ascii: "{"):
            return try nested { parser throws(GRPCCodecError) in try parser.parseObject() }
        case UInt8(ascii: "["):
            return try nested { parser throws(GRPCCodecError) in try parser.parseArray() }
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expectLiteral("null")
            return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .number(try parseNumber())
        default:
            throw failure("unexpected character")
        }
    }

    private mutating func nested(
        _ parse: (inout ProtoJSONParser) throws(GRPCCodecError) -> ProtoJSONValue
    ) throws(GRPCCodecError) -> ProtoJSONValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else {
            throw failure("nesting deeper than \(Self.maxDepth) levels")
        }
        return try parse(&self)
    }

    private mutating func parseObject() throws(GRPCCodecError) -> ProtoJSONValue {
        offset += 1
        var members: [ProtoJSONMember] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            offset += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else {
                throw failure("expected a quoted key")
            }
            let key = try parseString()
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            members.append(ProtoJSONMember(key: key, value: try parseValue()))
            skipWhitespace()
            if try endOfContainer("}") {
                return .object(members)
            }
        }
    }

    private mutating func parseArray() throws(GRPCCodecError) -> ProtoJSONValue {
        offset += 1
        var items: [ProtoJSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            offset += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            if try endOfContainer("]") {
                return .array(items)
            }
        }
    }

    /// Consumes `,` (more elements follow) or `close` (the container ended).
    private mutating func endOfContainer(_ close: Unicode.Scalar) throws(GRPCCodecError) -> Bool {
        if peek() == UInt8(ascii: close) {
            offset += 1
            return true
        }
        try expect(",")
        return false
    }

    private mutating func parseString() throws(GRPCCodecError) -> String {
        offset += 1
        var utf8: [UInt8] = []
        while let byte = peek() {
            offset += 1
            switch byte {
            case UInt8(ascii: "\""):
                // The input came from a `String` and escapes append whole scalars, so this cannot fail.
                return String(validating: utf8, as: UTF8.self) ?? ""
            case UInt8(ascii: "\\"):
                try appendEscape(to: &utf8)
            case 0..<0x20:
                offset -= 1
                throw failure("unescaped control character in a string")
            default:
                utf8.append(byte)
            }
        }
        throw failure("unterminated string")
    }

    private mutating func appendEscape(to utf8: inout [UInt8]) throws(GRPCCodecError) {
        guard let byte = peek() else {
            throw failure("unterminated string")
        }
        offset += 1
        if let replacement = Self.simpleEscapes[byte] {
            utf8.append(replacement)
            return
        }
        guard byte == UInt8(ascii: "u") else {
            offset -= 1
            throw failure("invalid escape sequence")
        }
        var scalarValue = try readHexQuad()
        if (0xD800..<0xDC00).contains(scalarValue) {
            guard peek() == UInt8(ascii: "\\"), offset + 1 < bytes.count, bytes[offset + 1] == UInt8(ascii: "u") else {
                throw failure("unpaired UTF-16 surrogate")
            }
            offset += 2
            let low = try readHexQuad()
            guard (0xDC00..<0xE000).contains(low) else {
                throw failure("unpaired UTF-16 surrogate")
            }
            scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
        }
        guard let scalar = Unicode.Scalar(scalarValue) else {
            throw failure("unpaired UTF-16 surrogate")
        }
        utf8.append(contentsOf: Array(String(Character(scalar)).utf8))
    }

    private static let simpleEscapes: [UInt8: UInt8] = [
        UInt8(ascii: "\""): UInt8(ascii: "\""), UInt8(ascii: "\\"): UInt8(ascii: "\\"),
        UInt8(ascii: "/"): UInt8(ascii: "/"), UInt8(ascii: "b"): 0x08, UInt8(ascii: "f"): 0x0C,
        UInt8(ascii: "n"): 0x0A, UInt8(ascii: "r"): 0x0D, UInt8(ascii: "t"): 0x09
    ]

    private mutating func readHexQuad() throws(GRPCCodecError) -> UInt32 {
        guard offset + 4 <= bytes.count else {
            throw failure("invalid \\u escape")
        }
        var value: UInt32 = 0
        for byte in bytes[offset..<offset + 4] {
            guard let digit = Character(Unicode.Scalar(byte)).hexDigitValue else {
                throw failure("invalid \\u escape")
            }
            value = value << 4 | UInt32(digit)
        }
        offset += 4
        return value
    }

    private mutating func parseNumber() throws(GRPCCodecError) -> String {
        let start = offset
        while let byte = peek(), Self.numberBytes.contains(byte) {
            offset += 1
        }
        guard let text = String(validating: bytes[start..<offset], as: UTF8.self), ProtoJSONNumber(text) != nil else {
            offset = start
            throw failure("invalid number")
        }
        return text
    }

    private static let numberBytes = Set("+-.0123456789eE".utf8)

    private mutating func expectLiteral(_ literal: String) throws(GRPCCodecError) {
        let utf8 = Array(literal.utf8)
        guard offset + utf8.count <= bytes.count, Array(bytes[offset..<offset + utf8.count]) == utf8 else {
            throw failure("unexpected character")
        }
        offset += utf8.count
    }

    private mutating func expect(_ character: Unicode.Scalar) throws(GRPCCodecError) {
        guard peek() == UInt8(ascii: character) else {
            throw failure("expected `\(character)`")
        }
        offset += 1
    }

    private func peek() -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
            offset += 1
        }
    }

    private func failure(_ detail: String) -> GRPCCodecError {
        let consumed = bytes[..<min(offset, bytes.count)]
        let line = consumed.count { $0 == 0x0A } + 1
        let lineStart = consumed.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        // Count UTF-8 lead bytes, so a column is a character position rather than a byte offset.
        let column = consumed[lineStart...].count { $0 & 0xC0 != 0x80 } + 1
        return GRPCCodecError("Invalid JSON at line \(line), column \(column): \(detail)")
    }
}
