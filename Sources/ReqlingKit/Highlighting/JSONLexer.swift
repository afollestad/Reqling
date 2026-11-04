import Foundation

/// A syntax token over UTF-8 bytes.
public struct ByteToken: Hashable, Sendable {
    public let range: Range<Int>
    public let role: SyntaxRole

    public init(range: Range<Int>, role: SyntaxRole) {
        self.range = range
        self.role = role
    }
}

/// Where JSON lexing stands between two bytes. Inside a string it also remembers whether that string is an object key;
/// whether the byte before is an escaping backslash is recovered from the bytes themselves (`JSONLexer.isEscaped`).
public struct JSONLexState: Hashable, Sendable {
    public internal(set) var inString = false
    public internal(set) var isProperty = false

    /// Outside any string, as at the start of a document and of every line of valid JSON, whose strings can't hold a
    /// raw line break.
    public static let start = JSONLexState()
}

/// A single-pass JSON lexer over UTF-8 bytes, coloring as the regex rules in `SyntaxTokenizer+Languages` did: keys,
/// strings, `true`/`false`/`null`, numbers, and structure.
///
/// Unlike those rules it has no size limit, and it can start anywhere given the state there, which is how the response
/// viewer colors only the rows on screen, including chunks deep inside one enormous minified line.
enum JSONLexer {
    /// The tokens in `range`, clipped to it, lexing from `state` at its start. Deciding whether a string is a key looks
    /// past the range to the string's end and the `:` after it.
    static func tokens(in bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>, from state: JSONLexState) -> [ByteToken] {
        lex(bytes, range: range, from: state).tokens
    }

    /// Tokens over a whole string, with ranges in UTF-16 units as `SyntaxTokenizer` reports them.
    static func tokens(in source: String) -> [SyntaxToken] {
        let utf8 = Array(source.utf8)
        let byteTokens = utf8.withUnsafeBufferPointer { tokens(in: $0, range: 0..<$0.count, from: .start) }
        var result: [SyntaxToken] = []
        result.reserveCapacity(byteTokens.count)
        // JSON's syntax is ASCII, so offsets only drift across multi-byte characters inside strings; one forward walk
        // converts every token boundary, which arrive in order.
        var byte = 0
        var utf16 = 0
        func advance(to target: Int) {
            while byte < target {
                let lead = utf8[byte]
                if lead & 0xC0 != 0x80 {
                    utf16 += lead >= 0xF0 ? 2 : 1
                }
                byte += 1
            }
        }
        for token in byteTokens {
            advance(to: token.range.lowerBound)
            let start = utf16
            advance(to: token.range.upperBound)
            result.append(SyntaxToken(range: NSRange(location: start, length: utf16 - start), role: token.role))
        }
        return result
    }

    /// The tokens in `range`, as `tokens(in:range:from:)` finds them, and the state at its end.
    static func lex(_ bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>, from state: JSONLexState) -> (tokens: [ByteToken], end: JSONLexState) {
        var tokens: [ByteToken] = []
        let end = lex(bytes, range: range, from: state) { token in
            if !token.range.isEmpty {
                tokens.append(token)
            }
        }
        return (tokens, end)
    }

    /// The state at `range.upperBound`, lexing from `state` at its start.
    static func state(after range: Range<Int>, in bytes: UnsafeBufferPointer<UInt8>, from state: JSONLexState) -> JSONLexState {
        lex(bytes, range: range, from: state, emit: nil)
    }

    private static func lex(
        _ bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>,
        from state: JSONLexState,
        emit: ((ByteToken) -> Void)?
    ) -> JSONLexState {
        var index = range.lowerBound
        let end = range.upperBound
        if state.inString {
            let string = stringEnd(in: bytes, from: index, escaped: isEscaped(bytes, at: index))
            emit?(ByteToken(range: index..<min(string.end, end), role: state.isProperty ? .property : .string))
            if string.end > end || !string.isClosed {
                return state
            }
            index = string.end
        }
        while index < end {
            switch bytes[index] {
            case UInt8(ascii: "\""):
                let string = stringEnd(in: bytes, from: index + 1, escaped: false)
                let role = string.isClosed && isFollowedByColon(bytes, at: string.end) ? SyntaxRole.property : .string
                emit?(ByteToken(range: index..<min(string.end, end), role: role))
                if string.end > end || !string.isClosed {
                    return JSONLexState(inString: true, isProperty: role == .property)
                }
                index = string.end
            case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: ":"), UInt8(ascii: ","):
                emit?(ByteToken(range: index..<index + 1, role: .symbol))
                index += 1
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                let numberEnd = self.numberEnd(in: bytes, from: index)
                if numberEnd > index {
                    emit?(ByteToken(range: index..<min(numberEnd, end), role: .number))
                    index = numberEnd
                } else {
                    index += 1
                }
            case UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "T"), UInt8(ascii: "F"), UInt8(ascii: "N"):
                let wordEnd = keywordEnd(in: bytes, from: index)
                if wordEnd > index {
                    emit?(ByteToken(range: index..<min(wordEnd, end), role: .keyword))
                    index = wordEnd
                } else {
                    index = skipWord(in: bytes, from: index)
                }
            default:
                index += 1
            }
        }
        return .start
    }

    /// Where a string whose content starts at `start` ends: just past its closing quote, or at the end of the bytes for
    /// one never closed. `escaped` says the byte at `start` follows an escaping backslash.
    private static func stringEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, escaped: Bool) -> (end: Int, isClosed: Bool) {
        var index = escaped ? start + 1 : start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                return (index + 1, true)
            }
            index += byte == UInt8(ascii: "\\") ? 2 : 1
        }
        return (bytes.count, false)
    }

    /// True when the byte at `index` follows an odd run of backslashes, which escapes it. Only meaningful inside a
    /// string, where every backslash is part of an escape.
    static func isEscaped(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Bool {
        var count = 0
        var position = index - 1
        while position >= 0, bytes[position] == UInt8(ascii: "\\") {
            count += 1
            position -= 1
        }
        return !count.isMultiple(of: 2)
    }

    private static func isFollowedByColon(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> Bool {
        var index = start
        while index < bytes.count, JSONFormatter.isWhitespace(bytes[index]) {
            index += 1
        }
        return index < bytes.count && bytes[index] == UInt8(ascii: ":")
    }

    /// `-?\d+(\.\d+)?([eE][+-]?\d+)?`, or `start` when there is no number there.
    private static func numberEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        if bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        let digitsStart = index
        index = digitsEnd(in: bytes, from: index)
        guard index > digitsStart else {
            return start
        }
        if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "."), isDigit(bytes[index + 1]) {
            index = digitsEnd(in: bytes, from: index + 1)
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            var exponent = index + 1
            if exponent < bytes.count, bytes[exponent] == UInt8(ascii: "+") || bytes[exponent] == UInt8(ascii: "-") {
                exponent += 1
            }
            let exponentEnd = digitsEnd(in: bytes, from: exponent)
            if exponentEnd > exponent {
                index = exponentEnd
            }
        }
        return index
    }

    /// `true`, `false`, or `null` in any case, as a whole word, or `start` when there is none.
    private static func keywordEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        if start > 0, isWordByte(bytes[start - 1]) {
            return start
        }
        for word in ["true", "false", "null"] {
            let length = word.utf8.count
            guard start + length <= bytes.count, zip(word.utf8, bytes[start..<start + length]).allSatisfy({ $0 == $1 | 0x20 }) else {
                continue
            }
            if start + length < bytes.count, isWordByte(bytes[start + length]) {
                continue
            }
            return start + length
        }
        return start
    }

    private static func skipWord(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start + 1
        while index < bytes.count, isWordByte(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func digitsEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        while index < bytes.count, isDigit(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    /// `\w` and `$`, which the regex keyword rule treats as part of a word.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte | 0x20 >= UInt8(ascii: "a") && byte | 0x20 <= UInt8(ascii: "z")) || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "$") || byte >= 0x80
    }
}
