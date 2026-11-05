import Foundation

/// A read-only body as UTF-8 bytes with a line index: everything the response viewer needs to draw any part of it
/// without holding it as a `String` or laying all of it out, which for a large response took seconds and gigabytes.
///
/// One pass, off the main actor, validates the UTF-8, records where each line starts, and measures each line's display
/// width, so the viewer sizes its scroller and wraps by arithmetic alone (`WrapLayout`). Widths count columns: one per
/// character, two for East Asian wide characters and emoji, none for combining marks, and tabs to the next multiple of
/// four. That approximates the monospaced font closely enough to wrap by; the viewer draws each row with its real
/// glyph advances.
public struct TextDocument: Sendable, Identifiable {
    public let id = UUID()
    public let bytes: Data
    /// How much of `bytes` is text: all of it, unless it ends partway through a character (a body cut to fit the
    /// run history), which is left off.
    public let length: Int
    public let language: SyntaxLanguage
    /// Where each line's first byte is. A line ends before its `\n`, and before a `\r` ahead of that.
    let lineStarts: [UInt32]
    /// Lines wider than `wrapMinimumColumns`, in order; every other line fits one row at any width the viewer uses.
    let longLines: [LongLine]
    /// In lines wider than `columnCheckpointInterval`, where each further interval of columns starts, in byte order.
    let columnCheckpoints: [ColumnCheckpoint]
    let highlighting: Highlighting

    /// The narrowest a row wraps at; a narrower viewer scrolls the rest out of sight rather than wrapping further.
    public static let wrapMinimumColumns = 40
    static let columnCheckpointInterval = 4096

    struct LongLine: Sendable {
        let line: UInt32
        let columns: UInt32
    }

    /// The first character at or past a multiple of `columnCheckpointInterval` columns into its line.
    struct ColumnCheckpoint: Sendable {
        let byte: UInt32
        let column: UInt32
    }

    public var lineCount: Int {
        lineStarts.count
    }

    /// Indexes `bytes`, or returns `nil` when they aren't UTF-8 text. Throws once the current task is cancelled, which
    /// it checks about every megabyte.
    public static func make(_ bytes: Data, language: SyntaxLanguage) throws(CancellationError) -> TextDocument? {
        guard bytes.count < Int(UInt32.max) else {
            return nil
        }
        var index: TextIndex?
        var cancelled = false
        bytes.withUnsafeBytes { raw in
            var indexer = TextIndexer(bytes: raw.bindMemory(to: UInt8.self))
            do {
                index = try indexer.run()
            } catch {
                cancelled = true
            }
        }
        if cancelled {
            throw CancellationError()
        }
        guard let index else {
            return nil
        }
        let highlighting = try Highlighting.make(
            for: bytes,
            length: index.length,
            utf16Count: index.utf16Count,
            lineStarts: index.lineStarts,
            language: language
        )
        return TextDocument(bytes: bytes, index: index, language: language, highlighting: highlighting)
    }

    /// A document for text already in memory, such as the body a request sent.
    public init(text: String, language: SyntaxLanguage) {
        let bytes = Data(text.utf8)
        // Valid UTF-8 by construction, and small enough to index here: nothing to cancel or fail.
        let index = bytes.withUnsafeBytes { raw in
            var indexer = TextIndexer(bytes: raw.bindMemory(to: UInt8.self))
            return (try? indexer.run()) ?? nil
        }
        let resolved = index ?? TextIndex(lineStarts: [0], longLines: [], columnCheckpoints: [], length: 0, utf16Count: 0)
        let highlighting = (try? Highlighting.make(
            for: bytes,
            length: resolved.length,
            utf16Count: resolved.utf16Count,
            lineStarts: resolved.lineStarts,
            language: language
        )) ?? .none
        self.init(bytes: bytes, index: resolved, language: language, highlighting: highlighting)
    }

    private init(bytes: Data, index: TextIndex, language: SyntaxLanguage, highlighting: Highlighting) {
        self.bytes = bytes
        length = index.length
        self.language = language
        lineStarts = index.lineStarts
        longLines = index.longLines
        columnCheckpoints = index.columnCheckpoints
        self.highlighting = highlighting
    }

    /// The line holding the byte at `offset`; an offset at the end belongs to the last line.
    public func line(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if Int(lineStarts[middle]) <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// A line's bytes, without its line break.
    public func byteRange(ofLine line: Int) -> Range<Int> {
        let start = Int(lineStarts[line])
        guard line + 1 < lineStarts.count else {
            return start..<length
        }
        var end = Int(lineStarts[line + 1]) - 1
        if end > start, bytes[bytes.startIndex + end - 1] == UInt8(ascii: "\r") {
            end -= 1
        }
        return start..<end
    }

    /// The text of `range`, which must start and end on character boundaries.
    public func text(in range: Range<Int>) -> String {
        let slice = bytes[(bytes.startIndex + range.lowerBound)..<(bytes.startIndex + range.upperBound)]
        return String(bytes: slice, encoding: .utf8) ?? ""
    }

    /// Calls `body` with the bytes, which views read from without copying.
    public func withBytes<Result>(_ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        bytes.withUnsafeBytes { body($0.bindMemory(to: UInt8.self)) }
    }
}

/// What `TextIndexer` finds.
struct TextIndex {
    let lineStarts: [UInt32]
    let longLines: [TextDocument.LongLine]
    let columnCheckpoints: [TextDocument.ColumnCheckpoint]
    let length: Int
    let utf16Count: Int
}

/// `TextDocument`'s indexing pass: validates UTF-8 and records lines, wide lines, and column checkpoints.
private struct TextIndexer {
    let bytes: UnsafeBufferPointer<UInt8>
    private var lineStarts: [UInt32] = [0]
    private var longLines: [TextDocument.LongLine] = []
    private var checkpoints: [TextDocument.ColumnCheckpoint] = []
    private var column = 0
    private var nextCheckpointColumn = TextDocument.columnCheckpointInterval
    private var utf16Count = 0

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    /// The index, or `nil` when the bytes aren't UTF-8.
    mutating func run() throws(CancellationError) -> TextIndex? {
        var index = 0
        var nextCancellationCheck = 1 << 20
        while index < bytes.count {
            if index >= nextCancellationCheck {
                nextCancellationCheck = index + (1 << 20)
                if Task.isCancelled {
                    throw CancellationError()
                }
            }
            if column >= nextCheckpointColumn {
                checkpoints.append(TextDocument.ColumnCheckpoint(byte: UInt32(index), column: UInt32(column)))
                nextCheckpointColumn = (column / TextDocument.columnCheckpointInterval + 1) * TextDocument.columnCheckpointInterval
            }
            let byte = bytes[index]
            if byte < 0x80 {
                ascii(byte, at: index)
                index += 1
                continue
            }
            guard let (scalar, length) = TextColumns.decode(bytes, at: index) else {
                // A character cut off by the end of the bytes ends the text; anything else isn't UTF-8.
                if bytes.count - index < 4, TextColumns.isTruncatedSequence(bytes, at: index) {
                    break
                }
                return nil
            }
            column += TextColumns.width(of: scalar)
            utf16Count += scalar >= 0x10000 ? 2 : 1
            index += length
        }
        finishLine()
        return TextIndex(lineStarts: lineStarts, longLines: longLines, columnCheckpoints: checkpoints, length: index, utf16Count: utf16Count)
    }

    private mutating func ascii(_ byte: UInt8, at index: Int) {
        utf16Count += 1
        switch byte {
        case UInt8(ascii: "\n"):
            finishLine()
            lineStarts.append(UInt32(index + 1))
            column = 0
            nextCheckpointColumn = TextDocument.columnCheckpointInterval
        case UInt8(ascii: "\r") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "\n"):
            break
        case UInt8(ascii: "\t"):
            column += TextColumns.tabWidth - column % TextColumns.tabWidth
        default:
            column += 1
        }
    }

    private mutating func finishLine() {
        if column > TextDocument.wrapMinimumColumns {
            longLines.append(TextDocument.LongLine(line: UInt32(lineStarts.count - 1), columns: UInt32(column)))
        }
    }
}
