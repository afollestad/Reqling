import Foundation

/// A request URL's path variables: whole path segments written `:name`, whose values live in the request's own Path
/// Variables table rather than in an environment, as Postman's do.
///
/// The only reader of that syntax, and the only encoder of a value. `HTTPRequestBuilder` substitutes through it, the URL
/// bar highlights through it, spec normalization keeps the table in step through it, and the script runner scopes
/// cookies through it, so none of them ever disagrees about what is a variable or what its segment sends.
///
/// The authority is never searched, so `host:8080` and a `{{baseUrl}}` that stands for one are not variables; nor is a
/// colon inside a segment (`things:batchGet`), which Google-style APIs use for custom methods.
public enum RequestPathVariables {
    /// One `:name` segment of a URL.
    public struct Segment: Hashable, Sendable {
        /// The name, without its colon.
        public let name: String
        /// The segment, colon included.
        public let range: Range<String.Index>
        /// `range` in UTF-16 units, for text views.
        public let utf16Range: NSRange
    }

    /// The `:name` segments in the URL's path, in order, repeats included.
    public static func segments(in url: String) -> [Segment] {
        guard let path = pathRange(in: url) else {
            return []
        }
        var segments: [Segment] = []
        var start = path.lowerBound
        while start < path.upperBound {
            // `start` is at a `/`; the segment runs to the next one or the end of the path.
            let segmentStart = url.index(after: start)
            let segmentEnd = url[segmentStart..<path.upperBound].firstIndex(of: "/") ?? path.upperBound
            let segment = url[segmentStart..<segmentEnd]
            if segment.first == ":", isValidName(segment.dropFirst()) {
                let range = segmentStart..<segmentEnd
                segments.append(Segment(name: String(segment.dropFirst()), range: range, utf16Range: NSRange(range, in: url)))
            }
            start = segmentEnd
        }
        return segments
    }

    /// Each variable's name once, in the order the URL first uses it: the rows the Path Variables table shows.
    public static func names(in url: String) -> [String] {
        var seen: Set<String> = []
        return segments(in: url).map(\.name).filter { seen.insert($0).inserted }
    }

    /// The URL with each `:name` segment replaced by `replacement(name)`, or kept as written where that is `nil`.
    public static func substituting(in url: String, _ replacement: (String) -> String?) -> String {
        var result = ""
        var cursor = url.startIndex
        for segment in segments(in: url) {
            guard let value = replacement(segment.name) else {
                continue
            }
            result += url[cursor..<segment.range.lowerBound]
            result += value
            cursor = segment.range.upperBound
        }
        return result + url[cursor...]
    }

    /// A value encoded as one path segment (RFC 3986 `pchar`), as it is sent. Valid escapes typed into it (`%20`) are
    /// kept, as a query's are, while `/`, `?`, `#`, and a stray `%` are escaped, so a value can never split its segment
    /// or end the path. Applied after `{{variables}}` resolve, so their values are encoded too.
    public static func encoded(_ value: String) -> String {
        var result = ""
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%"), index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) {
                for escapeByte in bytes[index...(index + 2)] {
                    result.unicodeScalars.append(Unicode.Scalar(escapeByte))
                }
                index += 3
                continue
            }
            if segmentAllowed.contains(byte) {
                result.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                result += String(format: "%%%02X", byte)
            }
            index += 1
        }
        return result
    }

    /// Letters, digits, `_`, `-`, and `.`, at least one.
    public static func isValidName(_ name: some StringProtocol) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_-.".unicodeScalars.contains(scalar))
        }
    }

    /// Unreserved characters, sub-delimiters, `:`, and `@`.
    private static let segmentAllowed: Set<UInt8> = Set(Array("-._~!$&'()*+,;=:@".utf8))
        .union(UInt8(ascii: "a")...UInt8(ascii: "z"))
        .union(UInt8(ascii: "A")...UInt8(ascii: "Z"))
        .union(UInt8(ascii: "0")...UInt8(ascii: "9"))

    private static func isHex(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    /// From the path's first `/` up to its query or fragment; `nil` when the URL has no path. The authority ends at the
    /// first `/` after `://`, or at the first `/` when the URL names no scheme, as `{{baseUrl}}/pets` does.
    private static func pathRange(in url: String) -> Range<String.Index>? {
        var authorityStart = url.startIndex
        if let scheme = url.range(of: "://"), !url[..<scheme.lowerBound].contains("/") {
            authorityStart = scheme.upperBound
        }
        guard let pathStart = url[authorityStart...].firstIndex(of: "/") else {
            return nil
        }
        let pathEnd = url[pathStart...].firstIndex { $0 == "?" || $0 == "#" } ?? url.endIndex
        return pathStart..<pathEnd
    }
}
