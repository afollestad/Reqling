import Foundation

/// Re-indents JSON text without parsing it into dictionaries, so key order, number spelling, and escapes are kept
/// exactly as the server sent them. `JSONSerialization` would reorder object keys, which is wrong for an API client.
///
/// It works on UTF-8 bytes: JSON's structure is all ASCII, and every byte of a multi-byte character is copied through
/// untouched. Walking `Character`s instead spent most of its time on grapheme breaking, seconds for a large response.
public enum JSONFormatter {
    /// The text pretty-printed with `indent`, or `nil` when it does not start like JSON (an object or array).
    public static func pretty(_ text: String, indent: String = "  ") -> String? {
        var text = text
        let bytes = text.withUTF8 { buffer in
            // Never cancelled: `format` checks only when asked to.
            try? format(buffer, indent: indent, checksCancellation: false)
        }
        return bytes.flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// `data` pretty-printed with `indent`, or `nil` when it does not start like JSON. Throws once the current task is
    /// cancelled, which it checks about every megabyte.
    ///
    /// Each top-level value starts a line of its own, so newline-delimited JSON keeps one value per line.
    public static func pretty(_ data: Data, indent: String = "  ") throws(CancellationError) -> [UInt8]? {
        var result: Result<[UInt8]?, CancellationError> = .success(nil)
        data.withUnsafeBytes { raw in
            result = Result { () throws(CancellationError) in
                try format(raw.bindMemory(to: UInt8.self), indent: indent, checksCancellation: true)
            }
        }
        return try result.get()
    }

    private static func format(
        _ bytes: UnsafeBufferPointer<UInt8>,
        indent: String,
        checksCancellation: Bool
    ) throws(CancellationError) -> [UInt8]? {
        guard let base = bytes.baseAddress else {
            return nil
        }
        var start = 0
        if bytes.count >= 3, base[0] == 0xEF, base[1] == 0xBB, base[2] == 0xBF {
            start = 3
        }
        while start < bytes.count, isWhitespace(base[start]) {
            start += 1
        }
        guard start < bytes.count, base[start] == UInt8(ascii: "{") || base[start] == UInt8(ascii: "[") else {
            return nil
        }
        var printer = Printer(base: base, count: bytes.count, indent: Array(indent.utf8))
        try printer.print(from: start, checksCancellation: checksCancellation)
        return printer.output
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }

    /// One pass that copies each string, number, and literal as a single run and handles only the structure byte by
    /// byte, so most of a payload never passes through per-byte bookkeeping.
    private struct Printer {
        let base: UnsafePointer<UInt8>
        let count: Int
        let indent: [UInt8]
        private(set) var output: [UInt8] = []
        /// A newline plus each depth's indentation, so a line costs one append however deep it is.
        private var lineStarts: [[UInt8]] = [[UInt8(ascii: "\n")]]
        private var depth = 0
        /// Set after `{` or `[`, so an empty container can close on the same line.
        private var pendingNewline = false
        /// A value at the top level has ended, so the next one starts a new line.
        private var topLevelValueEnded = false
        /// Inside a bare number or literal at the top level, which only whitespace ends.
        private var inTopLevelScalar = false

        init(base: UnsafePointer<UInt8>, count: Int, indent: [UInt8]) {
            self.base = base
            self.count = count
            self.indent = indent
            output.reserveCapacity(count + count / 4)
        }

        mutating func print(from start: Int, checksCancellation: Bool) throws(CancellationError) {
            var index = start
            var nextCancellationCheck = start
            while index < count {
                if checksCancellation, index >= nextCancellationCheck {
                    nextCancellationCheck = index + (1 << 20)
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                }
                let byte = base[index]
                if JSONFormatter.isWhitespace(byte) {
                    if inTopLevelScalar {
                        inTopLevelScalar = false
                        topLevelValueEnded = true
                    }
                    index += 1
                } else if startToken(byte) {
                    index += 1
                } else {
                    index = token(byte, at: index)
                }
            }
        }

        /// Breaks the line a token needs before it; returns true when that alone consumed `byte`, the end of an empty
        /// container, which stays on its opening line: `{}` and `[]`.
        private mutating func startToken(_ byte: UInt8) -> Bool {
            if depth == 0, topLevelValueEnded {
                topLevelValueEnded = false
                output.append(UInt8(ascii: "\n"))
            }
            guard pendingNewline else {
                return false
            }
            pendingNewline = false
            if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
                output.append(byte)
                topLevelValueEnded = depth == 0
                return true
            }
            newline()
            return false
        }

        /// Prints the token starting with `byte` at `index`, returning where the next one starts.
        private mutating func token(_ byte: UInt8, at index: Int) -> Int {
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                output.append(byte)
                depth += 1
                pendingNewline = true
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                newline()
                output.append(byte)
                topLevelValueEnded = depth == 0
            case UInt8(ascii: ","):
                output.append(byte)
                newline()
            case UInt8(ascii: ":"):
                output.append(UInt8(ascii: ":"))
                output.append(UInt8(ascii: " "))
            case UInt8(ascii: "\""):
                return string(at: index)
            default:
                return scalar(at: index)
            }
            return index + 1
        }

        /// Copies a string through its closing quote, escapes and all; an unclosed one runs to the end.
        private mutating func string(at start: Int) -> Int {
            var end = start + 1
            var isClosed = false
            while end < count {
                let byte = base[end]
                if byte == UInt8(ascii: "\"") {
                    end += 1
                    isClosed = true
                    break
                }
                end += byte == UInt8(ascii: "\\") ? 2 : 1
            }
            end = min(end, count)
            output.append(contentsOf: UnsafeBufferPointer(start: base + start, count: end - start))
            if isClosed, depth == 0 {
                topLevelValueEnded = true
            }
            return end
        }

        /// Copies a number or literal, or stray text, up to the next whitespace or structure.
        private mutating func scalar(at start: Int) -> Int {
            var end = start + 1
            while end < count, !Self.isDelimiter(base[end]) {
                end += 1
            }
            output.append(contentsOf: UnsafeBufferPointer(start: base + start, count: end - start))
            inTopLevelScalar = depth == 0
            return end
        }

        private mutating func newline() {
            let level = max(depth, 0)
            while lineStarts.count <= level {
                lineStarts.append(lineStarts[lineStarts.count - 1] + indent)
            }
            output.append(contentsOf: lineStarts[level])
        }

        private static func isDelimiter(_ byte: UInt8) -> Bool {
            switch byte {
            case 0x20, 0x0A, 0x0D, 0x09, UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: "\""),
                 UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "["), UInt8(ascii: "]"):
                true
            default:
                false
            }
        }
    }
}
