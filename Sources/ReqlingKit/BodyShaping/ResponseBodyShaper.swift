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
    /// JSON re-indented; anything else as sent.
    case pretty
    case raw
}

/// A body ready to show: the text with the language it is highlighted as, or why there is none.
public struct ShapedBody: Sendable {
    public enum Content: Sendable {
        case text(String, SyntaxLanguage)
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

    /// The body as `format` (from `classify`) shows it in `mode`. Throws once the current task is cancelled.
    public static func shape(_ body: Data, as format: BodyFormat, mode: ShapingMode) throws(CancellationError) -> ShapedBody {
        guard !body.isEmpty else {
            return ShapedBody(content: .empty, format: .empty)
        }
        guard let text = String(data: body, encoding: .utf8) else {
            return ShapedBody(content: .binary(byteCount: body.count), format: format)
        }
        try checkCancellation()
        switch format {
        case .empty:
            return ShapedBody(content: .empty, format: .empty)
        case .image:
            return ShapedBody(content: .text(text, .plainText), format: .text(.plainText))
        case .json(let source):
            if source == .sniffed, !(try isJSON(body)) {
                return ShapedBody(content: .text(text, .plainText), format: .text(.plainText))
            }
            let confirmed = BodyFormat.json(source == .sniffed ? .declared : source)
            // The formatter copies every multi-byte character whole, so valid UTF-8 in stays valid out.
            guard mode == .pretty, let pretty = try JSONFormatter.pretty(body), let prettyText = String(bytes: pretty, encoding: .utf8) else {
                return ShapedBody(content: .text(text, .json), format: confirmed)
            }
            return ShapedBody(content: .text(prettyText, .json), format: confirmed)
        case .xml:
            return ShapedBody(content: .text(text, .xml), format: format)
        case .text(let language):
            return ShapedBody(content: .text(text, language), format: format)
        }
    }

    private static func isJSON(_ body: Data) throws(CancellationError) -> Bool {
        do {
            _ = try JSONStructureIndex.build(body)
            return true
        } catch .cancelled {
            throw CancellationError()
        } catch {
            return false
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

    private static func checkCancellation() throws(CancellationError) {
        if Task.isCancelled {
            throw CancellationError()
        }
    }
}
