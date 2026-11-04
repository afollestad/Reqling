import Foundation

/// Display columns within a line, which wrapping and the viewer's chunking count in.
extension TextDocument {
    /// The byte where the first character at or past `column` starts in `line`, or the line's end when it is
    /// narrower. Walks from the nearest column checkpoint, so a column deep in an enormous line costs at most one
    /// checkpoint interval.
    public func byteOffset(line: Int, column: Int) -> Int {
        let range = byteRange(ofLine: line)
        guard column > 0 else {
            return range.lowerBound
        }
        var start = (byte: range.lowerBound, column: 0)
        if column >= Self.columnCheckpointInterval, let checkpoint = checkpoint(atOrBefore: column, in: range) {
            start = (Int(checkpoint.byte), Int(checkpoint.column))
        }
        return withBytes { bytes in
            var offset = start.byte
            var current = start.column
            while offset < range.upperBound, current < column {
                let step = TextColumns.step(bytes, at: offset, column: current)
                current += step.width
                offset += step.length
            }
            return offset
        }
    }

    /// The column at which the character at `offset` starts in its line.
    public func column(ofByte offset: Int, line: Int) -> Int {
        let range = byteRange(ofLine: line)
        let target = min(max(offset, range.lowerBound), range.upperBound)
        var start = (byte: range.lowerBound, column: 0)
        if let checkpoint = checkpoint(atOrBeforeByte: target, in: range) {
            start = (Int(checkpoint.byte), Int(checkpoint.column))
        }
        return withBytes { bytes in
            var offset = start.byte
            var current = start.column
            while offset < target {
                let step = TextColumns.step(bytes, at: offset, column: current)
                current += step.width
                offset += step.length
            }
            return current
        }
    }

    /// The display width of `line` in columns.
    public func columns(ofLine line: Int) -> Int {
        if let long = longLine(line) {
            return Int(long.columns)
        }
        let range = byteRange(ofLine: line)
        return column(ofByte: range.upperBound, line: line)
    }

    func longLine(_ line: Int) -> LongLine? {
        var low = 0
        var high = longLines.count
        while low < high {
            let middle = (low + high) / 2
            if Int(longLines[middle].line) < line {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < longLines.count && Int(longLines[low].line) == line ? longLines[low] : nil
    }

    private func checkpoint(atOrBefore column: Int, in range: Range<Int>) -> ColumnCheckpoint? {
        let slice = checkpoints(in: range)
        let after = partition(slice) { Int(columnCheckpoints[$0].column) <= column }
        return after > slice.lowerBound ? columnCheckpoints[after - 1] : nil
    }

    private func checkpoint(atOrBeforeByte offset: Int, in range: Range<Int>) -> ColumnCheckpoint? {
        let slice = checkpoints(in: range)
        let after = partition(slice) { Int(columnCheckpoints[$0].byte) <= offset }
        return after > slice.lowerBound ? columnCheckpoints[after - 1] : nil
    }

    /// The indexes of the checkpoints inside a line's byte range, which rise in both byte and column.
    private func checkpoints(in range: Range<Int>) -> Range<Int> {
        let all = 0..<columnCheckpoints.count
        let first = partition(all) { Int(columnCheckpoints[$0].byte) < range.lowerBound }
        let end = partition(first..<columnCheckpoints.count) { Int(columnCheckpoints[$0].byte) < range.upperBound }
        return first..<end
    }

    /// The first index in `indexes` for which `isBefore` is false, given that it is true for a prefix of them.
    private func partition(_ indexes: Range<Int>, _ isBefore: (Int) -> Bool) -> Int {
        var low = indexes.lowerBound
        var high = indexes.upperBound
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

/// How characters measure in columns, shared by the index and everything that walks a line.
enum TextColumns {
    static let tabWidth = 4

    /// One character at `offset` (a byte in a line): how many bytes it takes and how many columns it adds after
    /// `column`. Bytes that aren't valid UTF-8 never reach here; the index rejects them.
    static func step(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int, column: Int) -> (length: Int, width: Int) {
        let byte = bytes[offset]
        if byte < 0x80 {
            // A `\r` before a line's `\n` is outside the line's range; one anywhere else takes a column, as in the index.
            return (1, byte == UInt8(ascii: "\t") ? tabWidth - column % tabWidth : 1)
        }
        guard let (scalar, length) = decode(bytes, at: offset) else {
            return (1, 1)
        }
        return (length, width(of: scalar))
    }

    /// The scalar starting at `offset` and its length in bytes, or `nil` for anything that isn't well-formed UTF-8.
    static func decode(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> (UInt32, Int)? {
        let lead = bytes[offset]
        let length: Int
        let lowest: UInt8
        let highest: UInt8
        switch lead {
        case 0xC2...0xDF: (length, lowest, highest) = (2, 0x80, 0xBF)
        case 0xE0: (length, lowest, highest) = (3, 0xA0, 0xBF)
        case 0xED: (length, lowest, highest) = (3, 0x80, 0x9F)
        case 0xE1...0xEF: (length, lowest, highest) = (3, 0x80, 0xBF)
        case 0xF0: (length, lowest, highest) = (4, 0x90, 0xBF)
        case 0xF4: (length, lowest, highest) = (4, 0x80, 0x8F)
        case 0xF1...0xF3: (length, lowest, highest) = (4, 0x80, 0xBF)
        default: return nil
        }
        guard offset + length <= bytes.count, (lowest...highest).contains(bytes[offset + 1]) else {
            return nil
        }
        var scalar = UInt32(lead) & (length == 2 ? 0x1F : length == 3 ? 0x0F : 0x07)
        for position in 1..<length {
            let continuation = bytes[offset + position]
            guard continuation & 0xC0 == 0x80 else {
                return nil
            }
            scalar = scalar << 6 | UInt32(continuation & 0x3F)
        }
        return (scalar, length)
    }

    /// True when the bytes from `offset` to the end begin a valid multi-byte character that the end cuts short.
    static func isTruncatedSequence(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Bool {
        let lead = bytes[offset]
        let expected = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC2 ? 2 : 0
        guard expected > bytes.count - offset else {
            return false
        }
        return (offset + 1..<bytes.count).allSatisfy { bytes[$0] & 0xC0 == 0x80 }
    }

    static func width(of scalar: UInt32) -> Int {
        if scalar < 0x0300 {
            return 1
        }
        if contains(zeroWidth, scalar) {
            return 0
        }
        return contains(wide, scalar) ? 2 : 1
    }

    private static func contains(_ ranges: [ClosedRange<UInt32>], _ scalar: UInt32) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].upperBound < scalar {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < ranges.count && ranges[low].contains(scalar)
    }

    /// Combining marks, zero-width and format characters, variation selectors, and emoji modifiers, in order.
    private static let zeroWidth: [ClosedRange<UInt32>] = [
        0x0300...0x036F, 0x0483...0x0489, 0x0591...0x05BD, 0x0610...0x061A, 0x064B...0x065F, 0x1AB0...0x1AFF,
        0x1DC0...0x1DFF, 0x200B...0x200F, 0x2060...0x2064, 0x20D0...0x20FF, 0xFE00...0xFE0F, 0xFE20...0xFE2F,
        0xFEFF...0xFEFF, 0x1F3FB...0x1F3FF, 0xE0020...0xE007F, 0xE0100...0xE01EF
    ]

    /// East Asian wide and fullwidth characters and emoji shown as pictures, in order.
    private static let wide: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0...0x23F0, 0x23F3...0x23F3,
        0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F, 0x2693...0x2693, 0x26A1...0x26A1,
        0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE...0x26CE, 0x26D4...0x26D4, 0x26EA...0x26EA,
        0x26F2...0x26F3, 0x26F5...0x26F5, 0x26FA...0x26FA, 0x26FD...0x26FD, 0x2705...0x2705, 0x270A...0x270B,
        0x2728...0x2728, 0x274C...0x274C, 0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797,
        0x27B0...0x27B0, 0x27BF...0x27BF, 0x2B1B...0x2B1C, 0x2B50...0x2B50, 0x2B55...0x2B55, 0x2E80...0x303E,
        0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3,
        0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1B000...0x1B2FF,
        0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F18E...0x1F18E, 0x1F191...0x1F19A, 0x1F200...0x1F251,
        0x1F300...0x1F3FA, 0x1F400...0x1F64F, 0x1F680...0x1F6FF, 0x1F7E0...0x1F7EB, 0x1F90C...0x1F9FF,
        0x1FA70...0x1FAFF, 0x20000...0x3FFFD
    ]
}
