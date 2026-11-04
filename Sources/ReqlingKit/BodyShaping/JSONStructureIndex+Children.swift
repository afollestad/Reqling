import Foundation

public enum JSONValueKind: Hashable, Sendable {
    case object
    case array
    case string
    case number
    case bool
    case null
}

/// One value in a JSON tree: an object's member (with its key), an array's item, or a top-level value. Scalars stay
/// byte ranges until something shows them.
public struct JSONEntry: Hashable, Sendable {
    public let kind: JSONValueKind
    /// The member's name, decoded; `nil` for array items and top-level values.
    public let key: String?
    /// The value's bytes, quotes and brackets included.
    public let valueRange: Range<Int>
    /// The container index of an object or array, for `children(of:)`.
    public let container: Int?
    public let childCount: Int
    /// An object or array a cut body left open (`JSONStructureIndex.build(_:allowsSequence:allowsTruncation:)`).
    public var isTruncated = false
}

/// Listing a container's values, a container at a time, by scanning only its own bytes and stepping over nested
/// containers through the index.
extension JSONStructureIndex {
    /// The top-level values: one for a document, one per line for newline-delimited JSON.
    public func rootEntries() -> [JSONEntry] {
        withBytes { bytes in
            var container = 0
            return roots.map { range in
                let entry = value(at: range.lowerBound, key: nil, in: bytes, nextContainer: &container)
                return entry
            }
        }
    }

    /// The values directly inside `container`, in order.
    public func children(of container: Int) -> [JSONEntry] {
        withBytes { bytes in
            var entries: [JSONEntry] = []
            entries.reserveCapacity(Int(childCounts[container]))
            let isObject = bytes[Int(starts[container])] == UInt8(ascii: "{")
            var index = Int(starts[container]) + 1
            let end = Int(ends[container])
            var nextContainer = container + 1
            while index < end {
                index = skipSeparators(in: bytes, from: index, to: end)
                guard index < end else {
                    break
                }
                var key: String?
                if isObject {
                    let keyEnd = JSONStrings.end(in: bytes, from: index)
                    key = JSONStrings.decode(bytes, range: index..<keyEnd)
                    index = skipSeparators(in: bytes, from: keyEnd, to: end)
                }
                let entry = value(at: index, key: key, in: bytes, nextContainer: &nextContainer)
                entries.append(entry)
                index = entry.valueRange.upperBound
            }
            return entries
        }
    }

    /// A string value's text, decoded, cut at `limit` bytes of source when given.
    public func string(_ range: Range<Int>, limit: Int? = nil) -> String {
        withBytes { bytes in
            let cut = limit.map { min(range.upperBound, range.lowerBound + $0) } ?? range.upperBound
            return JSONStrings.decode(bytes, range: range.lowerBound..<cut)
        }
    }

    /// A range's bytes as they are, such as a number's literal text, which keeps every digit.
    public func text(_ range: Range<Int>) -> String {
        String(bytes: data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)], encoding: .utf8) ?? ""
    }

    func withBytes<Result>(_ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        data.withUnsafeBytes { body($0.bindMemory(to: UInt8.self)) }
    }

    /// The value starting at `start`. `nextContainer` is the next container in pre-order that this scan hasn't passed;
    /// a nested value that is one advances it past that container's whole subtree.
    private func value(at start: Int, key: String?, in bytes: UnsafeBufferPointer<UInt8>, nextContainer: inout Int) -> JSONEntry {
        switch bytes[start] {
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            let container = nextContainer
            nextContainer += Int(subtreeSizes[container])
            return JSONEntry(
                kind: bytes[start] == UInt8(ascii: "{") ? .object : .array,
                key: key,
                // A cut container has no closing bracket; its range stops at the end of the bytes.
                valueRange: start..<min(Int(ends[container]) + 1, bytes.count),
                container: container,
                childCount: Int(childCounts[container]),
                isTruncated: truncated.contains(container)
            )
        case UInt8(ascii: "\""):
            return JSONEntry(kind: .string, key: key, valueRange: start..<JSONStrings.end(in: bytes, from: start), container: nil, childCount: 0)
        default:
            var end = start + 1
            while end < bytes.count, !Self.endsScalar(bytes[end]) {
                end += 1
            }
            let kind: JSONValueKind = switch bytes[start] {
            case UInt8(ascii: "t"), UInt8(ascii: "f"): .bool
            case UInt8(ascii: "n"): .null
            default: .number
            }
            return JSONEntry(kind: kind, key: key, valueRange: start..<end, container: nil, childCount: 0)
        }
    }

    /// Skips whitespace, commas, and colons, which are all that sit between a container's keys and values.
    private func skipSeparators(in bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Int {
        var index = start
        while index < end {
            let byte = bytes[index]
            guard JSONFormatter.isWhitespace(byte) || byte == UInt8(ascii: ",") || byte == UInt8(ascii: ":") else {
                break
            }
            index += 1
        }
        return index
    }

    private static func endsScalar(_ byte: UInt8) -> Bool {
        JSONFormatter.isWhitespace(byte) || byte == UInt8(ascii: ",") || byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}")
    }
}

/// JSON strings in bytes the index already validated, so decoding never fails.
enum JSONStrings {
    /// Just past the closing quote of the string whose opening quote is at `start`.
    static func end(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                return index + 1
            }
            index += byte == UInt8(ascii: "\\") ? 2 : 1
        }
        return bytes.count
    }

    /// The text of the string in `range`, which starts at its opening quote and may stop short of its end. A lone
    /// surrogate escape decodes as U+FFFD, as does an escape cut off by the range.
    static func decode(_ bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>) -> String {
        var start = range.lowerBound
        var end = range.upperBound
        if start < end, bytes[start] == UInt8(ascii: "\"") {
            start += 1
        }
        if end > start, end - 1 >= start, bytes[end - 1] == UInt8(ascii: "\""), !JSONLexer.isEscaped(bytes, at: end - 1) {
            end -= 1
        }
        guard (start..<end).contains(where: { bytes[$0] == UInt8(ascii: "\\") }) else {
            return String(bytes: UnsafeBufferPointer(rebasing: bytes[start..<end]), encoding: .utf8) ?? "\u{FFFD}"
        }
        var scalars = String.UnicodeScalarView()
        var utf8: [UInt8] = []
        var index = start
        func flush() {
            if !utf8.isEmpty {
                scalars.append(contentsOf: (String(bytes: utf8, encoding: .utf8) ?? "\u{FFFD}").unicodeScalars)
                utf8.removeAll(keepingCapacity: true)
            }
        }
        while index < end {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < end else {
                utf8.append(byte)
                index += 1
                continue
            }
            flush()
            let escape = bytes[index + 1]
            index += 2
            switch escape {
            case UInt8(ascii: "b"): scalars.append("\u{08}")
            case UInt8(ascii: "f"): scalars.append("\u{0C}")
            case UInt8(ascii: "n"): scalars.append("\n")
            case UInt8(ascii: "r"): scalars.append("\r")
            case UInt8(ascii: "t"): scalars.append("\t")
            case UInt8(ascii: "u"):
                scalars.append(unicodeEscape(bytes, at: &index, end: end))
            default:
                scalars.append(Unicode.Scalar(escape))
            }
        }
        flush()
        return String(scalars)
    }

    /// The scalar a `\uXXXX` escape whose digits start at `index` names, joining a surrogate pair; moves `index` past
    /// what it read.
    private static func unicodeEscape(_ bytes: UnsafeBufferPointer<UInt8>, at index: inout Int, end: Int) -> Unicode.Scalar {
        var value = hexQuad(bytes, at: index, end: end)
        index += value == nil ? 0 : 4
        if let high = value, (0xD800..<0xDC00).contains(high), index + 1 < end, bytes[index] == UInt8(ascii: "\\"),
           bytes[index + 1] == UInt8(ascii: "u"), let low = hexQuad(bytes, at: index + 2, end: end), (0xDC00..<0xE000).contains(low) {
            value = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
            index += 6
        }
        return value.flatMap(Unicode.Scalar.init) ?? "\u{FFFD}"
    }

    private static func hexQuad(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int, end: Int) -> UInt32? {
        guard start + 4 <= end else {
            return nil
        }
        var value: UInt32 = 0
        for index in start..<start + 4 {
            guard let digit = Character(Unicode.Scalar(bytes[index])).hexDigitValue else {
                return nil
            }
            value = value << 4 | UInt32(digit)
        }
        return value
    }
}
