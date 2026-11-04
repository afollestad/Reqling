import Foundation

/// One `{{name}}` reference in a template.
public struct TemplateToken: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case variable
        /// A built-in generated value such as `{{$uuid}}`.
        case dynamic
    }

    /// The name with surrounding whitespace trimmed; dynamic names keep their `$`.
    public let name: String
    /// The whole token, braces included.
    public let range: Range<String.Index>
    /// `range` in UTF-16 offsets, for AppKit text views.
    public let utf16Range: NSRange

    public var kind: Kind {
        name.hasPrefix("$") ? .dynamic : .variable
    }
}

/// Finds `{{name}}` references. This is the single source of token ranges for both resolution and the editor's
/// token drawing, so what is highlighted is exactly what will be substituted.
///
/// A name cannot contain braces or a newline, and `{{{a}}}` reads as `{` + `{{a}}` + `}`. Unterminated or empty
/// references are left as plain text.
public enum TemplateParser {
    /// One linear pass. A candidate name ends at its first brace or newline, and scanning resumes there rather than
    /// just after the `{{`: nothing in between can open a token, so text full of `{{` with a distant `}}` stays linear
    /// instead of rescanning to the `}}` once per `{{`.
    public static func tokens(in text: String) -> [TemplateToken] {
        var tokens: [TemplateToken] = []
        let end = text.endIndex
        var index = text.startIndex
        while index < end {
            guard text[index] == "{" else {
                index = text.index(after: index)
                continue
            }
            let second = text.index(after: index)
            guard second < end, text[second] == "{" else {
                index = second
                continue
            }
            let nameStart = text.index(after: second)
            if nameStart < end, text[nameStart] == "{" {
                // A run of braces opens its token at the last pair.
                index = second
                continue
            }
            var stop = nameStart
            while stop < end, text[stop] != "{", text[stop] != "}", !text[stop].isNewline {
                stop = text.index(after: stop)
            }
            guard stop < end, text[stop] == "}" else {
                // A `{` here may open the next token, so resume on it.
                index = stop
                continue
            }
            let secondClose = text.index(after: stop)
            guard secondClose < end, text[secondClose] == "}" else {
                index = secondClose
                continue
            }
            let close = text.index(after: secondClose)
            let name = text[nameStart..<stop].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                let range = index..<close
                tokens.append(TemplateToken(name: name, range: range, utf16Range: NSRange(range, in: text)))
            }
            index = close
        }
        return tokens
    }

    /// The distinct variable names referenced, in first-use order; dynamic names are excluded.
    public static func variableNames(in text: String) -> [String] {
        var seen: Set<String> = []
        return tokens(in: text).compactMap { token in
            guard token.kind == .variable, seen.insert(token.name).inserted else {
                return nil
            }
            return token.name
        }
    }
}
