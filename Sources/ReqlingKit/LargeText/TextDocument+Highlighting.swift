import Foundation

/// Syntax colors for the rows the viewer draws, worked out as it draws them rather than for the whole text up front.
extension TextDocument {
    enum Highlighting: Sendable {
        case none
        /// Lexed row by row; `checkpoints` hold the lexer's state every `jsonCheckpointInterval` bytes inside longer
        /// lines, so a row deep in one huge minified line starts lexing close by.
        case json(checkpoints: [JSONCheckpoint])
        /// Another language's regex tokens for the whole text, in byte order.
        case tokens([ByteToken])
        /// Text past `SyntaxTokenizer.maximumLength`, tokenized a line at a time. A comment or string spanning lines
        /// then colors only from where it starts on each line.
        case perLine

        static func make(
            for bytes: Data,
            length: Int,
            utf16Count: Int,
            lineStarts: [UInt32],
            language: SyntaxLanguage
        ) throws(CancellationError) -> Highlighting {
            switch language {
            case .plainText:
                return .none
            case .json:
                return .json(checkpoints: try jsonCheckpoints(in: bytes, length: length, lineStarts: lineStarts))
            default:
                guard utf16Count <= SyntaxTokenizer.maximumLength,
                      let text = String(bytes: bytes[bytes.startIndex..<(bytes.startIndex + length)], encoding: .utf8) else {
                    return .perLine
                }
                let tokens = SyntaxTokenizer.tokens(in: text, language: language)
                if Task.isCancelled {
                    throw CancellationError()
                }
                return .tokens(bytes.withUnsafeBytes { ByteToken.converting(tokens, in: $0.bindMemory(to: UInt8.self), from: 0) })
            }
        }

        private static func jsonCheckpoints(in bytes: Data, length: Int, lineStarts: [UInt32]) throws(CancellationError) -> [JSONCheckpoint] {
            var checkpoints: [JSONCheckpoint] = []
            var cancelled = false
            bytes.withUnsafeBytes { raw in
                let buffer = raw.bindMemory(to: UInt8.self)
                for line in lineStarts.indices {
                    let start = Int(lineStarts[line])
                    let end = line + 1 < lineStarts.count ? Int(lineStarts[line + 1]) : length
                    guard end - start > TextDocument.jsonCheckpointInterval else {
                        continue
                    }
                    var state = JSONLexState.start
                    var previous = start
                    for offset in stride(from: start + TextDocument.jsonCheckpointInterval, to: end, by: TextDocument.jsonCheckpointInterval) {
                        if Task.isCancelled {
                            cancelled = true
                            return
                        }
                        state = JSONLexer.state(after: previous..<offset, in: buffer, from: state)
                        checkpoints.append(JSONCheckpoint(byte: UInt32(offset), state: state))
                        previous = offset
                    }
                }
            }
            if cancelled {
                throw CancellationError()
            }
            return checkpoints
        }
    }

    struct JSONCheckpoint: Sendable {
        let byte: UInt32
        let state: JSONLexState
    }

    static let jsonCheckpointInterval = 64 * 1024
}

/// Colors a document's rows for the viewer. Not `Sendable`: one viewer uses it from the main actor, keeping the last
/// line it tokenized whole for text tokenized a line at a time, whose rows otherwise each tokenize that line again.
public final class TextHighlighter {
    public let document: TextDocument
    private var lastLine: (line: Int, tokens: [ByteToken])?
    /// JSON lexer states where recently lexed ranges ended, by byte: the viewer draws rows top to bottom, so each row
    /// usually starts where the last one ended, and resumes there instead of re-lexing from a checkpoint up to
    /// `jsonCheckpointInterval` back.
    private var jsonEndStates: [Int: JSONLexState] = [:]

    public init(document: TextDocument) {
        self.document = document
    }

    /// The tokens in `range`, which lies within `line`, clipped to it.
    public func tokens(in range: Range<Int>, line: Int) -> [ByteToken] {
        switch document.highlighting {
        case .none:
            return []
        case .json(let checkpoints):
            return jsonTokens(in: range, line: line, checkpoints: checkpoints)
        case .tokens(let tokens):
            return ByteToken.clip(tokens, to: range)
        case .perLine:
            return ByteToken.clip(lineTokens(line), to: range)
        }
    }

    private func jsonTokens(in range: Range<Int>, line: Int, checkpoints: [TextDocument.JSONCheckpoint]) -> [ByteToken] {
        if jsonEndStates.count > 4_096 {
            jsonEndStates = [:]
        }
        let lineStart = Int(document.lineStarts[line])
        if range.lowerBound > lineStart, let state = jsonEndStates[range.lowerBound] {
            return document.withBytes { bytes in
                let lexed = JSONLexer.lex(bytes, range: range, from: state)
                jsonEndStates[range.upperBound] = lexed.end
                return lexed.tokens
            }
        }
        var start = lineStart
        var state = JSONLexState.start
        // The last checkpoint at or before the range, if it is inside this line.
        var low = 0
        var high = checkpoints.count
        while low < high {
            let middle = (low + high) / 2
            if Int(checkpoints[middle].byte) <= range.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }
        if low > 0, Int(checkpoints[low - 1].byte) >= lineStart {
            start = Int(checkpoints[low - 1].byte)
            state = checkpoints[low - 1].state
        }
        return document.withBytes { bytes in
            let entry = JSONLexer.state(after: start..<range.lowerBound, in: bytes, from: state)
            let lexed = JSONLexer.lex(bytes, range: range, from: entry)
            jsonEndStates[range.upperBound] = lexed.end
            return lexed.tokens
        }
    }

    private func lineTokens(_ line: Int) -> [ByteToken] {
        if let lastLine, lastLine.line == line {
            return lastLine.tokens
        }
        let range = document.byteRange(ofLine: line)
        var tokens: [ByteToken] = []
        // Past the regex limit a line gets no colors, as the whole text would; decoding it alone is not worth it.
        if range.count <= SyntaxTokenizer.maximumLength {
            let text = document.text(in: range)
            let found = SyntaxTokenizer.tokens(in: text, language: document.language)
            tokens = document.withBytes { ByteToken.converting(found, in: $0, from: range.lowerBound) }
        }
        lastLine = (line, tokens)
        return tokens
    }
}

extension ByteToken {
    /// `tokens` (UTF-16 ranges into text whose UTF-8 starts at byte `base`) as byte ranges, in one forward walk; they
    /// must be sorted and not overlap, as `SyntaxTokenizer` returns them.
    static func converting(_ tokens: [SyntaxToken], in bytes: UnsafeBufferPointer<UInt8>, from base: Int) -> [ByteToken] {
        var result: [ByteToken] = []
        result.reserveCapacity(tokens.count)
        var byte = base
        var utf16 = 0
        func advance(toUTF16 target: Int) {
            while utf16 < target, byte < bytes.count {
                let lead = bytes[byte]
                let length = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2
                utf16 += length == 4 ? 2 : 1
                byte += length
            }
        }
        for token in tokens {
            advance(toUTF16: token.range.location)
            let start = byte
            advance(toUTF16: token.range.location + token.range.length)
            result.append(ByteToken(range: start..<byte, role: token.role))
        }
        return result
    }

    /// The tokens overlapping `range`, clipped to it; `tokens` must be in byte order.
    static func clip(_ tokens: [ByteToken], to range: Range<Int>) -> [ByteToken] {
        var low = 0
        var high = tokens.count
        while low < high {
            let middle = (low + high) / 2
            if tokens[middle].range.upperBound <= range.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var result: [ByteToken] = []
        var index = low
        while index < tokens.count, tokens[index].range.lowerBound < range.upperBound {
            let token = tokens[index]
            let clipped = max(token.range.lowerBound, range.lowerBound)..<min(token.range.upperBound, range.upperBound)
            result.append(ByteToken(range: clipped, role: token.role))
            index += 1
        }
        return result
    }
}
