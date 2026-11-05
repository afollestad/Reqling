import Foundation
@_implementationOnly import GraphQL

/// Where GraphQLSwift's errors point, in terms Reqling can use.
///
/// Its lexer counts positions in UTF-8 bytes, but `getLocation` compares them with UTF-16 line breaks, so an error's
/// `locations` and the `(line:column)` its syntax messages embed are wrong after any non-ASCII text. Everything here
/// reads `positions`, which are plain UTF-8 offsets, and works out lines itself.
extension GraphQLEngine {
    /// An error as one sentence, prefixed with the line it points at.
    static func describe(_ error: any Error, in source: String) -> String {
        guard let error = error as? GraphQLError else {
            return error.localizedDescription
        }
        let message = cleanMessage(error.message)
        guard let position = error.positions.first else {
            return message
        }
        return "line \(line(atUTF8Offset: position, in: source)): \(message)"
    }

    /// The message without a syntax error's `Syntax Error <name> (line:column) ` prefix and its source excerpt.
    static func cleanMessage(_ message: String) -> String {
        guard message.hasPrefix("Syntax Error "), let close = message.range(of: ") ") else {
            return message
        }
        var rest = message[close.upperBound...]
        if let excerpt = rest.range(of: "\n\n") {
            rest = rest[..<excerpt.lowerBound]
        }
        return String(rest)
    }

    /// The 1-based line holding a UTF-8 offset, counting `\n`, `\r\n`, and a lone `\r` as GraphQL does.
    static func line(atUTF8Offset offset: Int, in text: String) -> Int {
        var line = 1
        var previous: UInt8 = 0
        for byte in text.utf8.prefix(offset) {
            if byte == UInt8(ascii: "\n") {
                line += previous == UInt8(ascii: "\r") ? 0 : 1
            } else if byte == UInt8(ascii: "\r") {
                line += 1
            }
            previous = byte
        }
        return line
    }
}

extension GraphQLEngine {
    /// The UTF-16 offset of a UTF-8 offset, clamped to the text.
    static func utf16Offset(ofUTF8Offset offset: Int, in text: String) -> Int {
        let utf8 = text.utf8
        let index = utf8.index(utf8.startIndex, offsetBy: max(0, offset), limitedBy: utf8.endIndex) ?? utf8.endIndex
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }
}
