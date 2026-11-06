import Foundation
import ReqlingTemplating

/// One token of a GraphQL document. Ranges are UTF-16, as AppKit text views count.
struct GraphQLToken: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case name
        /// One of `! $ & ( ) : = @ [ ] { } |`.
        case punctuator
        case spread
        case number
        case string(terminated: Bool)
        case blockString(terminated: Bool)
        case comment
        /// A `{{variable}}`, from `TemplateParser`; it stands for whatever it resolves to.
        case template
        case unknown
    }

    let kind: Kind
    let range: NSRange
    /// The token's own text for names, punctuators, spreads, and numbers; empty for the rest, which nothing reads.
    let text: String

    var end: Int {
        NSMaxRange(range)
    }

    func isPunctuator(_ character: String) -> Bool {
        kind == .punctuator && text == character
    }

    /// Whether `offset` falls within the token for completion and hover. A string or comment that runs on (an
    /// unterminated string, a comment to the end of its line) also holds its end, where typing would extend it.
    func holds(_ offset: Int) -> Bool {
        if offset > range.location, offset < end {
            return true
        }
        switch kind {
        case .comment, .string(terminated: false), .blockString(terminated: false):
            return offset == end
        default:
            return false
        }
    }
}

/// Splits a GraphQL document into tokens without ever failing: an unterminated string runs to its line's end, an
/// unknown character becomes an `.unknown` token, and `{{variable}}` templates are single tokens wherever they appear
/// outside strings, so a half-written query still tokenizes the way it reads.
enum GraphQLLexer {
    private static let punctuators: Set<UInt16> = Set("!$&():=@[]{}|".utf16)

    private static let quote = code("\"")
    private static let backslash = code("\\")
    private static let newline = code("\n")
    private static let carriageReturn = code("\r")

    /// An ASCII character's UTF-16 code unit.
    private static func code(_ scalar: Unicode.Scalar) -> UInt16 {
        UInt16(scalar.value)
    }

    static func tokens(in text: String) -> [GraphQLToken] {
        let units = Array(text.utf16)
        var templates: [Int: Int] = [:]
        for token in TemplateParser.tokens(in: text) {
            templates[token.utf16Range.location] = token.utf16Range.length
        }
        var tokens: [GraphQLToken] = []
        var index = 0
        while index < units.count {
            let start = index
            let unit = units[index]
            let kind: GraphQLToken.Kind
            if isIgnored(unit) {
                index += 1
                continue
            } else if let length = templates[start] {
                index += length
                kind = .template
            } else if unit == code("#") {
                index = lineEnd(after: index, in: units)
                kind = .comment
            } else if punctuators.contains(unit) {
                index += 1
                kind = .punctuator
            } else if isSpread(at: index, in: units) {
                index += 3
                kind = .spread
            } else if isNameStart(unit) {
                index = scan(from: index + 1, in: units, while: isNameContinue)
                kind = .name
            } else if isDigit(unit) || unit == code("-") {
                index = scan(from: index + 1, in: units, while: isNumberContinue)
                kind = .number
            } else if unit == quote {
                (index, kind) = string(at: index, in: units)
            } else {
                index += 1
                kind = .unknown
            }
            let range = NSRange(location: start, length: index - start)
            tokens.append(GraphQLToken(kind: kind, range: range, text: tokenText(kind, range: range, in: units)))
        }
        return tokens
    }

    private static func tokenText(_ kind: GraphQLToken.Kind, range: NSRange, in units: [UInt16]) -> String {
        switch kind {
        case .name, .punctuator, .spread, .number:
            String(decoding: units[range.location..<NSMaxRange(range)], as: UTF16.self)
        default:
            ""
        }
    }

    /// Whitespace, line breaks, commas (insignificant in GraphQL), and a byte order mark.
    private static func isIgnored(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == newline || unit == carriageReturn || unit == code(",") || unit == 0xFEFF
    }

    private static func isSpread(at index: Int, in units: [UInt16]) -> Bool {
        let dot = code(".")
        return index + 2 < units.count && units[index] == dot && units[index + 1] == dot && units[index + 2] == dot
    }

    private static func isNameStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == code("_")
    }

    private static func isNameContinue(_ unit: UInt16) -> Bool {
        isNameStart(unit) || isDigit(unit)
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    private static func isNumberContinue(_ unit: UInt16) -> Bool {
        isDigit(unit) || unit == code(".") || unit == code("e") || unit == code("E")
            || unit == code("+") || unit == code("-")
    }

    private static func scan(from index: Int, in units: [UInt16], while matches: (UInt16) -> Bool) -> Int {
        var index = index
        while index < units.count, matches(units[index]) {
            index += 1
        }
        return index
    }

    private static func lineEnd(after index: Int, in units: [UInt16]) -> Int {
        scan(from: index, in: units) { $0 != newline && $0 != carriageReturn }
    }

    /// A `"…"` string, which ends at its line, or a `"""…"""` block string, which may span lines; `\"` and `\"""`
    /// escape their quotes.
    private static func string(at start: Int, in units: [UInt16]) -> (end: Int, kind: GraphQLToken.Kind) {
        let isBlock = start + 2 < units.count && units[start + 1] == quote && units[start + 2] == quote
        var index = start + (isBlock ? 3 : 1)
        while index < units.count {
            let unit = units[index]
            if isBlock {
                if unit == backslash, index + 3 < units.count, units[index + 1] == quote, units[index + 2] == quote, units[index + 3] == quote {
                    index += 4
                    continue
                }
                if unit == quote, index + 2 < units.count, units[index + 1] == quote, units[index + 2] == quote {
                    return (index + 3, .blockString(terminated: true))
                }
            } else {
                if unit == newline || unit == carriageReturn {
                    return (index, .string(terminated: false))
                }
                if unit == backslash {
                    index += 2
                    continue
                }
                if unit == quote {
                    return (index + 1, .string(terminated: true))
                }
            }
            index += 1
        }
        return (units.count, isBlock ? .blockString(terminated: false) : .string(terminated: false))
    }
}
