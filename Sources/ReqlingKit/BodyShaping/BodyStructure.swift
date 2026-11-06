import Foundation

/// A JSON or XML body as a tree for the response pane's Tree mode.
public enum BodyStructure: Sendable {
    case json(JSONStructureIndex)
    case xml(XMLStructureIndex)
    case messages(MessageTimeline)

    /// The same for every update of one call's or stream's timeline, which the tree applies in place.
    public var id: UUID {
        switch self {
        case .json(let index): index.id
        case .xml(let index): index.id
        case .messages(let timeline): timeline.id
        }
    }

    /// Changes whenever the content does under the same `id`: a timeline's newest message. A search reruns on it.
    public var revision: Int {
        if case .messages(let timeline) = self {
            return (timeline.messages.last?.item.sequence ?? -1) &* 31 &+ timeline.messages.count
        }
        return 0
    }

    /// Every node whose key, name, or value contains `query`, ignoring case, up to `limit`, in tree order. Throws once
    /// the current task is cancelled.
    public func find(_ query: String, limit: Int = TextDocument.searchLimit) throws(CancellationError) -> BodyTreeSearchResult {
        guard !query.isEmpty else {
            return .empty
        }
        switch self {
        case .json(let index): return try index.find(query, limit: limit)
        case .xml(let index): return try index.find(query, limit: limit)
        case .messages(let timeline): return try timeline.find(query, limit: limit)
        }
    }
}

/// A node found by searching a tree, as the child index at each level from the top: the top-level value first.
public struct BodyTreeMatch: Hashable, Sendable {
    public let path: [Int]

    public init(path: [Int]) {
        self.path = path
    }
}

public struct BodyTreeSearchResult: Sendable, Equatable {
    public let matches: [BodyTreeMatch]
    /// The search stopped at its limit; there are more.
    public let isTruncated: Bool

    public static let empty = BodyTreeSearchResult(matches: [], isTruncated: false)
}

/// How a node's path reads when copied: JSONPath for JSON (`$.users[0]["first name"]`), an XPath-like path for XML
/// (`/stations/station[3]/@id`).
public enum BodyTreePathComponent: Hashable, Sendable {
    case key(String)
    case index(Int)
    /// An XML element, attribute, or text node, with its 1-based position among same-named siblings.
    case xml(name: String, position: Int?, isAttribute: Bool)

    public static func jsonPath(_ components: [BodyTreePathComponent]) -> String {
        components.reduce(into: "$") { path, component in
            switch component {
            case .key(let key) where isIdentifier(key):
                path += ".\(key)"
            case .key(let key):
                let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                path += "[\"\(escaped)\"]"
            case .index(let index):
                path += "[\(index)]"
            case .xml(let name, _, _):
                path += ".\(name)"
            }
        }
    }

    public static func xmlPath(_ components: [BodyTreePathComponent]) -> String {
        components.reduce(into: "") { path, component in
            switch component {
            case .xml(let name, let position, let isAttribute):
                path += isAttribute ? "/@\(name)" : "/\(name)" + (position.map { "[\($0)]" } ?? "")
            case .key(let key):
                path += "/\(key)"
            case .index(let index):
                path += "[\(index + 1)]"
            }
        }
    }

    private static func isIdentifier(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first == "_" || first == "$" || first.properties.isAlphabetic else {
            return false
        }
        return key.unicodeScalars.allSatisfy { $0 == "_" || $0 == "$" || $0.properties.isAlphabetic || ("0"..."9").contains($0) }
    }
}

/// Case-insensitive matching shared by the tree searches: ASCII queries compare bytes with ASCII letters folded,
/// anything else compares decoded text.
struct TreeQuery {
    let text: String
    private let folded: [UInt8]?

    init(_ text: String) {
        self.text = text
        folded = text.utf8.allSatisfy { $0 < 0x80 } ? text.utf8.map(Self.fold) : nil
    }

    /// True when the raw bytes, which hold no escapes, contain the query.
    func matches(raw bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>) -> Bool {
        guard let folded else {
            return matches(String(bytes: UnsafeBufferPointer(rebasing: bytes[range]), encoding: .utf8) ?? "")
        }
        guard range.count >= folded.count else {
            return false
        }
        var start = range.lowerBound
        while start + folded.count <= range.upperBound {
            var matched = 0
            while matched < folded.count, Self.fold(bytes[start + matched]) == folded[matched] {
                matched += 1
            }
            if matched == folded.count {
                return true
            }
            start += 1
        }
        return false
    }

    func matches(_ value: String) -> Bool {
        value.range(of: text, options: .caseInsensitive) != nil
    }

    private static func fold(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte | 0x20 : byte
    }
}
