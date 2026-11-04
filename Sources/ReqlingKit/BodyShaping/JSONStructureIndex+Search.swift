import Foundation

/// Finding keys and values in a JSON tree, in one pass over the bytes that tracks where in the tree each one is.
extension JSONStructureIndex {
    func find(_ query: String, limit: Int) throws(CancellationError) -> BodyTreeSearchResult {
        let query = TreeQuery(query)
        var matches: [BodyTreeMatch] = []
        var cancelled = false
        withBytes { bytes in
            var scanner = SearchScanner(bytes: bytes, query: query)
            cancelled = !scanner.run(limit: limit) { matches = $0 }
        }
        if cancelled {
            throw CancellationError()
        }
        return BodyTreeSearchResult(matches: matches, isTruncated: matches.count >= limit)
    }
}

/// Walks the bytes keeping a stack of open containers and which child each is on, so a matching key or scalar knows
/// its path. A key and its own value matching count once.
private struct SearchScanner {
    let bytes: UnsafeBufferPointer<UInt8>
    let query: TreeQuery
    private var stack: [(isObject: Bool, child: Int)] = []
    private var root = -1
    private var lastMatch: [Int]?

    init(bytes: UnsafeBufferPointer<UInt8>, query: TreeQuery) {
        self.bytes = bytes
        self.query = query
    }

    /// Reports each match until `limit`; returns false when the task was cancelled.
    mutating func run(limit: Int, report: ([BodyTreeMatch]) -> Void) -> Bool {
        var found: [BodyTreeMatch] = []
        defer { report(found) }
        var index = 0
        var nextCancellationCheck = 1 << 20
        while index < bytes.count, found.count < limit {
            if index >= nextCancellationCheck {
                nextCancellationCheck = index + (1 << 20)
                if Task.isCancelled {
                    return false
                }
            }
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                if stack.isEmpty {
                    root += 1
                }
                stack.append((byte == UInt8(ascii: "{"), 0))
                index += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                stack.removeLast()
                index += 1
            case UInt8(ascii: ","):
                if !stack.isEmpty {
                    stack[stack.count - 1].child += 1
                }
                index += 1
            case 0x20, 0x0A, 0x0D, 0x09, UInt8(ascii: ":"), 0xEF, 0xBB, 0xBF:
                index += 1
            default:
                index = value(at: index, into: &found)
            }
        }
        return true
    }

    /// Checks the string or scalar at `start`, returning where it ends.
    private mutating func value(at start: Int, into found: inout [BodyTreeMatch]) -> Int {
        let isString = bytes[start] == UInt8(ascii: "\"")
        var end = start + 1
        if isString {
            end = JSONStrings.end(in: bytes, from: start)
        } else {
            while end < bytes.count, !Self.endsScalar(bytes[end]) {
                end += 1
            }
        }
        if stack.isEmpty {
            root += 1
        }
        let matches = isString ? matchesString(start..<end) : query.matches(raw: bytes, range: start..<end)
        if matches, let match = newMatch() {
            found.append(match)
        }
        return end
    }

    private func matchesString(_ range: Range<Int>) -> Bool {
        let inner = range.lowerBound + 1..<max(range.upperBound - 1, range.lowerBound + 1)
        if inner.contains(where: { bytes[$0] == UInt8(ascii: "\\") }) {
            return query.matches(JSONStrings.decode(bytes, range: range))
        }
        return query.matches(raw: bytes, range: inner)
    }

    /// The path at the current position, unless it repeats the last match (a key and its value).
    private mutating func newMatch() -> BodyTreeMatch? {
        let path = [root] + stack.map(\.child)
        guard path != lastMatch else {
            return nil
        }
        lastMatch = path
        return BodyTreeMatch(path: path)
    }

    private static func endsScalar(_ byte: UInt8) -> Bool {
        JSONFormatter.isWhitespace(byte) || byte == UInt8(ascii: ",") || byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}")
    }
}
