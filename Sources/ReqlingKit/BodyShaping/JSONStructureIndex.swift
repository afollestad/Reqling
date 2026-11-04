import Foundation

/// The objects and arrays of a JSON document, found in one validating pass over its UTF-8 bytes.
///
/// Only containers are recorded, in pre-order, as flat arrays of byte offsets: a scalar is found again by scanning its
/// parent's few bytes when it is needed. That keeps the index to a few bytes per container however large the body is,
/// where a parsed tree (`JSONSerialization`, or `ProtoJSONValue`) costs many times the body and reorders or recurses.
/// The pass is iterative, so nesting depth is limited by memory, not the stack.
public struct JSONStructureIndex: Sendable {
    public let id = UUID()
    public let data: Data
    /// Every top-level value's byte range: one for a document, one per value for newline-delimited JSON.
    public let roots: [Range<Int>]

    /// Per container, in pre-order: the offset of its opening and closing bracket, how many values it holds, how many
    /// containers its subtree holds (itself included, so the next container outside it is `index + subtreeSize`), and
    /// its parent container, or -1 at the top level.
    var starts: [UInt32] = []
    var ends: [UInt32] = []
    var childCounts: [UInt32] = []
    var subtreeSizes: [UInt32] = []
    var parents: [Int32] = []

    public var containerCount: Int {
        starts.count
    }

    /// Indexes `data`, which must hold exactly one JSON value, or, with `allowsSequence`, any number of them separated
    /// by whitespace (newline-delimited JSON). Throws `.cancelled` once the current task is cancelled, which it checks
    /// about every megabyte.
    public static func build(_ data: Data, allowsSequence: Bool = false) throws(JSONIndexError) -> JSONStructureIndex {
        guard data.count < Int(UInt32.max) else {
            throw .syntax(message: "The body is too large to index.", line: 1, column: 1)
        }
        var result: Result<JSONStructureIndex, JSONIndexError> = .failure(.cancelled)
        data.withUnsafeBytes { raw in
            var scanner = Scanner(bytes: raw.bindMemory(to: UInt8.self), allowsSequence: allowsSequence)
            result = Result { () throws(JSONIndexError) in
                try scanner.scan()
                return JSONStructureIndex(data: data, scanner: scanner)
            }
        }
        return try result.get()
    }

    private init(data: Data, scanner: Scanner) {
        self.data = data
        roots = scanner.roots
        starts = scanner.starts
        ends = scanner.ends
        childCounts = scanner.childCounts
        subtreeSizes = scanner.subtreeSizes
        parents = scanner.parents
    }
}

public enum JSONIndexError: Error, Hashable, Sendable {
    /// Where the text stops being JSON. `line` and `column` count from 1; the column counts characters.
    case syntax(message: String, line: Int, column: Int)
    case cancelled
}

/// The validating pass: a state machine over bytes with an explicit stack of open containers.
private struct Scanner {
    let bytes: UnsafeBufferPointer<UInt8>
    let allowsSequence: Bool

    var roots: [Range<Int>] = []
    var starts: [UInt32] = []
    var ends: [UInt32] = []
    var childCounts: [UInt32] = []
    var subtreeSizes: [UInt32] = []
    var parents: [Int32] = []

    private enum Expectation {
        case value
        /// Just after `[`: a value, or `]` for an empty array.
        case valueOrEnd
        /// Just after `{`: a key, or `}` for an empty object.
        case keyOrEnd
        case key
        case colon
        case commaOrEnd
        /// After a top-level value: only whitespace, or another value in a sequence.
        case done
    }

    private var expectation = Expectation.value
    /// The open containers, innermost last, as indexes into the arrays above.
    private var open: [Int] = []
    private var rootStart = 0
    private var index = 0

    init(bytes: UnsafeBufferPointer<UInt8>, allowsSequence: Bool) {
        self.bytes = bytes
        self.allowsSequence = allowsSequence
    }

    mutating func scan() throws(JSONIndexError) {
        var nextCancellationCheck = 1 << 20
        // A leading byte-order mark is not JSON, but servers send one.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            index = 3
        }
        while true {
            skipWhitespace()
            if index >= nextCancellationCheck {
                nextCancellationCheck = index + (1 << 20)
                if Task.isCancelled {
                    throw .cancelled
                }
            }
            guard index < bytes.count else {
                break
            }
            try step(bytes[index])
        }
        guard open.isEmpty else {
            throw failure("The text ends before every object and array is closed.")
        }
        guard !roots.isEmpty else {
            throw failure("Expected a JSON value.")
        }
    }

    private mutating func step(_ byte: UInt8) throws(JSONIndexError) {
        switch expectation {
        case .value, .valueOrEnd:
            if expectation == .valueOrEnd, byte == UInt8(ascii: "]") {
                close()
            } else {
                try value(byte)
            }
        case .keyOrEnd, .key:
            if expectation == .keyOrEnd, byte == UInt8(ascii: "}") {
                close()
            } else if byte == UInt8(ascii: "\"") {
                try string()
                expectation = .colon
            } else {
                throw failure("Expected a property name in double quotes.")
            }
        case .colon:
            guard byte == UInt8(ascii: ":") else {
                throw failure("Expected “:” after a property name.")
            }
            index += 1
            expectation = .value
        case .commaOrEnd:
            let isArray = bytes[Int(starts[open[open.count - 1]])] == UInt8(ascii: "[")
            if byte == UInt8(ascii: ",") {
                index += 1
                expectation = isArray ? .value : .key
            } else if byte == UInt8(ascii: isArray ? "]" : "}") {
                close()
            } else {
                throw failure(isArray ? "Expected “,” or “]”." : "Expected “,” or “}”.")
            }
        case .done:
            guard allowsSequence else {
                throw failure("Unexpected text after the JSON value.")
            }
            try value(byte)
        }
    }

    private mutating func value(_ byte: UInt8) throws(JSONIndexError) {
        if open.isEmpty {
            rootStart = index
        }
        switch byte {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            starts.append(UInt32(index))
            ends.append(0)
            childCounts.append(0)
            subtreeSizes.append(0)
            parents.append(Int32(open.last ?? -1))
            open.append(starts.count - 1)
            index += 1
            expectation = byte == UInt8(ascii: "{") ? .keyOrEnd : .valueOrEnd
        case UInt8(ascii: "\""):
            try string()
            valueEnded()
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            try number()
            valueEnded()
        case UInt8(ascii: "t"):
            try literal("true")
        case UInt8(ascii: "f"):
            try literal("false")
        case UInt8(ascii: "n"):
            try literal("null")
        default:
            throw failure("Expected a JSON value.")
        }
    }

    private mutating func close() {
        let container = open.removeLast()
        ends[container] = UInt32(index)
        subtreeSizes[container] = UInt32(starts.count - container)
        index += 1
        valueEnded()
    }

    /// Counts the value just scanned toward its container, or records it as a top-level value.
    private mutating func valueEnded() {
        if let container = open.last {
            childCounts[container] += 1
            expectation = .commaOrEnd
        } else {
            roots.append(rootStart..<index)
            expectation = .done
        }
    }

    private mutating func literal(_ word: StaticString) throws(JSONIndexError) {
        let length = word.utf8CodeUnitCount
        guard index + length <= bytes.count else {
            throw failure("Expected a JSON value.")
        }
        for offset in 0..<length where bytes[index + offset] != word.utf8Start[offset] {
            throw failure("Expected a JSON value.")
        }
        index += length
        valueEnded()
    }

    private mutating func string() throws(JSONIndexError) {
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard index < bytes.count else {
                    break
                }
                switch bytes[index] {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"), UInt8(ascii: "f"),
                     UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                    index += 1
                case UInt8(ascii: "u"):
                    guard index + 4 < bytes.count, (1...4).allSatisfy({ Self.isHexDigit(bytes[index + $0]) }) else {
                        throw failure("Expected four hex digits after “\\u”.")
                    }
                    index += 5
                default:
                    throw failure("Unknown escape in a string.")
                }
                continue
            }
            if byte < 0x20 {
                throw failure("A string can't contain a raw control character or line break.")
            }
            index += 1
        }
        index = start
        throw failure("A string is never closed.")
    }

    private mutating func number() throws(JSONIndexError) {
        if bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        guard index < bytes.count, Self.isDigit(bytes[index]) else {
            throw failure("Expected a digit.")
        }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            skipDigits()
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard index < bytes.count, Self.isDigit(bytes[index]) else {
                throw failure("Expected a digit after the decimal point.")
            }
            skipDigits()
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count, Self.isDigit(bytes[index]) else {
                throw failure("Expected a digit in the exponent.")
            }
            skipDigits()
        }
    }

    private mutating func skipDigits() {
        while index < bytes.count, Self.isDigit(bytes[index]) {
            index += 1
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, JSONFormatter.isWhitespace(bytes[index]) {
            index += 1
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
    }

    /// A syntax error at the current offset, with its line and column counted from 1.
    private func failure(_ message: String) -> JSONIndexError {
        let offset = min(index, bytes.count)
        var line = 1
        var lineStart = 0
        for position in 0..<offset where bytes[position] == UInt8(ascii: "\n") {
            line += 1
            lineStart = position + 1
        }
        // Characters, not bytes: UTF-8 continuation bytes (10xxxxxx) don't start one.
        let column = (lineStart..<offset).reduce(1) { count, position in bytes[position] & 0xC0 == 0x80 ? count : count + 1 }
        return .syntax(message: message, line: line, column: column)
    }
}
