import Foundation

/// A document's rows wrapped at a column count: which line, and which part of it, each row shows.
///
/// Rows break at exact column counts, not word boundaries, so a line's row count is arithmetic on its width. Every
/// line but the document's long ones takes one row, so building a layout walks only those, once per width.
public struct WrapLayout: Sendable {
    public let columns: Int
    public let rowCount: Int
    private let document: TextDocument
    /// Each long line's first row, in `document.longLines` order.
    private let firstRows: [Int]

    /// `columns` below `TextDocument.wrapMinimumColumns` wraps at that minimum instead.
    public init(document: TextDocument, columns: Int) {
        let columns = max(columns, TextDocument.wrapMinimumColumns)
        self.columns = columns
        self.document = document
        // A live resize builds one of these per width; a tight loop over raw buffers keeps that cheap even unoptimized.
        var extra = 0
        firstRows = document.longLines.withUnsafeBufferPointer { longLines in
            [Int](unsafeUninitializedCapacity: longLines.count) { firstRows, initialized in
                for index in 0..<longLines.count {
                    let long = longLines[index]
                    firstRows[index] = Int(long.line) + extra
                    extra += max(0, (Int(long.columns) - 1) / columns)
                }
                initialized = longLines.count
            }
        }
        rowCount = document.lineCount + extra
    }

    /// The line a row shows, and which of that line's rows it is.
    public func position(ofRow row: Int) -> (line: Int, chunk: Int) {
        let after = partition(firstRows.count) { firstRows[$0] <= row }
        guard after > 0 else {
            return (row, 0)
        }
        let index = after - 1
        let long = document.longLines[index]
        let rows = Self.rows(forColumns: Int(long.columns), wrappingAt: columns)
        if row < firstRows[index] + rows {
            return (Int(long.line), row - firstRows[index])
        }
        return (row - extraRows(through: index), 0)
    }

    public func firstRow(ofLine line: Int) -> Int {
        let before = partition(document.longLines.count) { Int(document.longLines[$0].line) < line }
        return before > 0 ? line + extraRows(through: before - 1) : line
    }

    public func rows(ofLine line: Int) -> Int {
        document.longLine(line).map { Self.rows(forColumns: Int($0.columns), wrappingAt: columns) } ?? 1
    }

    /// The bytes a row shows.
    public func byteRange(ofRow row: Int) -> Range<Int> {
        let (line, chunk) = position(ofRow: row)
        guard rows(ofLine: line) > 1 else {
            return document.byteRange(ofLine: line)
        }
        let start = document.byteOffset(line: line, column: chunk * columns)
        return start..<document.byteOffset(line: line, column: (chunk + 1) * columns)
    }

    /// The row showing the character at `offset`.
    public func row(ofByte offset: Int) -> Int {
        let line = document.line(containing: offset)
        let rows = rows(ofLine: line)
        guard rows > 1 else {
            return firstRow(ofLine: line)
        }
        let chunk = document.column(ofByte: offset, line: line) / columns
        return firstRow(ofLine: line) + min(chunk, rows - 1)
    }

    /// How many more rows than lines the long lines up to and including `index` add.
    private func extraRows(through index: Int) -> Int {
        let long = document.longLines[index]
        return firstRows[index] - Int(long.line) + Self.rows(forColumns: Int(long.columns), wrappingAt: columns) - 1
    }

    private static func rows(forColumns width: Int, wrappingAt columns: Int) -> Int {
        max(1, (width + columns - 1) / columns)
    }

    /// The first index below `count` for which `isBefore` is false, given that it is true for a prefix.
    private func partition(_ count: Int, _ isBefore: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if isBefore(middle) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
