import Foundation

/// Finding text, which runs off the main actor over the bytes.
extension TextDocument {
    public struct SearchResult: Sendable, Equatable {
        /// Byte ranges, in order.
        public let matches: [Range<Int>]
        /// The search stopped at its limit; there are more.
        public let isTruncated: Bool

        public static let empty = SearchResult(matches: [], isTruncated: false)
    }

    public static let searchLimit = 10_000

    /// Every case-insensitive occurrence of `query`, up to `limit`. Throws once the current task is cancelled, which it
    /// checks about every megabyte.
    public func find(_ query: String, limit: Int = searchLimit) throws(CancellationError) -> SearchResult {
        guard !query.isEmpty else {
            return SearchResult(matches: [], isTruncated: false)
        }
        if query.utf8.allSatisfy({ $0 < 0x80 }) {
            return try findASCII(Array(query.utf8), limit: limit)
        }
        return try findByLine(query, limit: limit)
    }

    /// Compares bytes with ASCII letters folded to lower case; anything else must match exactly.
    private func findASCII(_ query: [UInt8], limit: Int) throws(CancellationError) -> SearchResult {
        let needle = query.map(Self.fold)
        var matches: [Range<Int>] = []
        var cancelled = false
        withBytes { bytes in
            var index = 0
            var nextCancellationCheck = 1 << 20
            let last = length - needle.count
            while index <= last, matches.count < limit {
                if index >= nextCancellationCheck {
                    nextCancellationCheck = index + (1 << 20)
                    if Task.isCancelled {
                        cancelled = true
                        return
                    }
                }
                var matched = 0
                while matched < needle.count, Self.fold(bytes[index + matched]) == needle[matched] {
                    matched += 1
                }
                if matched == needle.count {
                    matches.append(index..<index + matched)
                    index += matched
                } else {
                    index += 1
                }
            }
        }
        if cancelled {
            throw CancellationError()
        }
        return SearchResult(matches: matches, isTruncated: matches.count == limit)
    }

    /// Decodes a line at a time for a query outside ASCII, where folding case takes Unicode's rules.
    private func findByLine(_ query: String, limit: Int) throws(CancellationError) -> SearchResult {
        var matches: [Range<Int>] = []
        for line in 0..<lineCount {
            if line.isMultiple(of: 4096), Task.isCancelled {
                throw CancellationError()
            }
            let range = byteRange(ofLine: line)
            let text = self.text(in: range)
            var searchStart = text.startIndex
            var offset = range.lowerBound
            while let found = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
                offset += text.utf8.distance(from: searchStart, to: found.lowerBound)
                let length = text.utf8.distance(from: found.lowerBound, to: found.upperBound)
                matches.append(offset..<offset + length)
                if matches.count == limit {
                    return SearchResult(matches: matches, isTruncated: true)
                }
                offset += length
                searchStart = found.upperBound
            }
        }
        return SearchResult(matches: matches, isTruncated: false)
    }

    private static func fold(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte
    }
}
