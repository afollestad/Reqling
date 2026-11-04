import Foundation

/// What a response body is, judged from its content type and first bytes alone, so the format picker can show while
/// the body itself is still being shaped.
public enum BodyFormat: Hashable, Sendable {
    case empty
    /// An `image/*` type; the app decodes it, and shapes it as plain text if that fails.
    case image
    case json(JSONSource)
    case xml
    /// Everything else: HTML, YAML, JavaScript, CSS, GraphQL, or plain text. Shaping may still find it isn't text.
    case text(SyntaxLanguage)

    public enum JSONSource: Hashable, Sendable {
        /// The content type says JSON.
        case declared
        /// Plain text (or no type) that starts like JSON; many APIs label JSON `text/plain`. Shaping confirms it parses.
        case sniffed
        /// Newline-delimited JSON: one value per line.
        case lines
    }
}

/// How the app wants a body shown.
public enum ShapingMode: Hashable, Sendable {
    /// JSON and XML as a collapsible tree.
    case tree
    /// JSON re-indented; anything else as sent.
    case pretty
    case raw
}

/// A body ready to show: its text indexed for the viewer, or why there is none.
public struct ShapedBody: Sendable {
    public enum Content: Sendable {
        case text(TextDocument)
        case tree(BodyStructure)
        /// The body doesn't parse as its format, so there is no tree; the message says where it stops.
        case treeFailed(String)
        /// Not UTF-8 text, so there is nothing to show in place.
        case binary(byteCount: Int)
        case empty
    }

    public let content: Content
    /// The format shaping settled on: a sniffed JSON body that doesn't parse is plain text after all.
    public let format: BodyFormat
}

/// Turns response bodies into what the response pane shows.
///
/// Shaping reads the whole body, which can be hundreds of megabytes, so the app runs `shape` off the main actor and
/// keeps only `classify` on it.
public enum ResponseBodyShaper {
    /// The body's format from its content type and its first non-whitespace byte; it never reads the rest.
    public static func classify(_ body: Data, contentType: String?) -> BodyFormat {
        guard !body.isEmpty else {
            return .empty
        }
        if contentType?.lowercased().hasPrefix("image/") == true {
            return .image
        }
        let mediaType = contentType?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        switch ContentTypeLanguage.language(forContentType: contentType) {
        case .json:
            return .json(mediaType == "application/x-ndjson" ? .lines : .declared)
        case .xml:
            return .xml
        case .plainText:
            return startsLikeJSON(body) ? .json(.sniffed) : .text(.plainText)
        case let language:
            return .text(language)
        }
    }

    /// The body as `format` (from `classify`) shows it in `mode`. `isTruncated` says the body was cut short to fit the
    /// response cache, so a tree keeps what came before the cut rather than failing on it. Throws once the current task
    /// is cancelled.
    public static func shape(
        _ body: Data,
        as format: BodyFormat,
        mode: ShapingMode,
        isTruncated: Bool = false
    ) throws(CancellationError) -> ShapedBody {
        guard !body.isEmpty else {
            return ShapedBody(content: .empty, format: .empty)
        }
        let resolved: BodyFormat
        let language: SyntaxLanguage
        switch format {
        case .empty:
            return ShapedBody(content: .empty, format: .empty)
        case .image:
            (resolved, language) = (.text(.plainText), .plainText)
        case .json(let source):
            let index = source == .sniffed || mode == .tree ? try jsonIndex(body, source: source, isTruncated: isTruncated) : nil
            if source == .sniffed, index?.tree == nil {
                (resolved, language) = (.text(.plainText), .plainText)
                break
            }
            (resolved, language) = (.json(source == .sniffed ? .declared : source), .json)
            if mode == .tree, let index {
                return ShapedBody(content: index.tree.map { .tree(.json($0)) } ?? .treeFailed(index.failure ?? ""), format: resolved)
            }
            if mode == .pretty, let pretty = try JSONFormatter.pretty(body) {
                return try shaped(Data(pretty), language: .json, format: resolved, byteCount: body.count)
            }
        case .xml:
            (resolved, language) = (.xml, .xml)
            if mode == .tree {
                return ShapedBody(content: try xmlTree(body, isTruncated: isTruncated), format: resolved)
            }
        case .text(let textLanguage):
            (resolved, language) = (format, textLanguage)
        }
        return try shaped(body, language: language, format: resolved, byteCount: body.count)
    }

    private static func shaped(_ text: Data, language: SyntaxLanguage, format: BodyFormat, byteCount: Int) throws(CancellationError) -> ShapedBody {
        guard let document = try TextDocument.make(text, language: language) else {
            return ShapedBody(content: .binary(byteCount: byteCount), format: format)
        }
        return ShapedBody(content: .text(document), format: format)
    }

    /// The body's JSON index, or where it stops being JSON.
    private static func jsonIndex(
        _ body: Data,
        source: BodyFormat.JSONSource,
        isTruncated: Bool
    ) throws(CancellationError) -> (tree: JSONStructureIndex?, failure: String?) {
        do {
            return (try JSONStructureIndex.build(body, allowsSequence: source == .lines, allowsTruncation: isTruncated), nil)
        } catch {
            switch error {
            case .cancelled:
                throw CancellationError()
            case .syntax(let message, let line, let column):
                return (nil, "Line \(line), column \(column): \(message)")
            }
        }
    }

    private static func xmlTree(_ body: Data, isTruncated: Bool) throws(CancellationError) -> ShapedBody.Content {
        do {
            return .tree(.xml(try XMLStructureIndex.build(body, allowsTruncation: isTruncated)))
        } catch {
            switch error {
            case .cancelled:
                throw CancellationError()
            case .tooLarge:
                return .treeFailed("The XML has more than \(XMLStructureIndex.nodeLimit.formatted()) nodes, too many for the tree.")
            case .syntax(let message, let line, let column):
                return .treeFailed("Line \(line), column \(column): \(message)")
            }
        }
    }

    private static func startsLikeJSON(_ body: Data) -> Bool {
        var bytes = body.prefix(4096).makeIterator()
        var first = bytes.next()
        if first == 0xEF {
            // A UTF-8 byte-order mark.
            _ = bytes.next()
            _ = bytes.next()
            first = bytes.next()
        }
        while let byte = first, JSONFormatter.isWhitespace(byte) {
            first = bytes.next()
        }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

}
