import Foundation

public enum SyntaxRole: Hashable, Sendable, CaseIterable {
    case keyword
    case string
    /// An object key, such as a JSON property name.
    case property
    case comment
    case number
    case symbol
}

public struct SyntaxToken: Hashable, Sendable {
    public let range: NSRange
    public let role: SyntaxRole

    public init(range: NSRange, role: SyntaxRole) {
        self.range = range
        self.role = role
    }
}

public enum SyntaxLanguage: String, Hashable, Sendable, CaseIterable {
    case json
    case xml
    case html
    case yaml
    case javascript
    case css
    case graphQL = "graphql"
    case plainText = "text"
}

/// A regex-based tokenizer ported from Alveary's `SyntaxHighlighter`: keys, strings, and comments are matched first
/// and protected, then keywords, numbers, and symbols color what is left. It is deliberately lightweight; it makes
/// payloads scan quickly rather than parsing them. JSON goes through `JSONLexer` instead, and JavaScript through
/// `JavaScriptLexer`, which script editing reads as well.
///
/// Output is ranges and roles only, so the SwiftUI and AppKit renderers share one tokenizer and one palette.
public enum SyntaxTokenizer {
    /// Regex-highlighted sources longer than this (in UTF-16 units) come back with no tokens and render plain, so a
    /// multi-megabyte response stays responsive. JSON has no limit: `JSONLexer` makes one linear pass.
    public static let maximumLength = 2_000_000

    public static func tokens(in source: String, language: SyntaxLanguage) -> [SyntaxToken] {
        if language == .json {
            return JSONLexer.tokens(in: source)
        }
        let length = (source as NSString).length
        if language == .javascript {
            return length <= maximumLength ? JavaScriptLexer.syntaxTokens(in: source) : []
        }
        guard length > 0, length <= maximumLength, let spec = CompiledSpec.specs[language] else {
            return []
        }
        let range = NSRange(location: 0, length: length)
        var tokens = protectedTokens(in: source, length: length, rules: spec.protected)
        // An interval set keeps overlap checks logarithmic; a multi-megabyte payload has hundreds of thousands of tokens.
        var colored = IndexSet()
        for token in tokens {
            if let span = Range(token.range) {
                colored.insert(integersIn: span)
            }
        }
        for rule in spec.unprotected {
            for match in rule.regex.matches(in: source, range: range) {
                let matchRange = rule.captureGroup.map { match.range(at: $0) } ?? match.range
                guard matchRange.location != NSNotFound, matchRange.length > 0, let span = Range(matchRange),
                      !colored.intersects(integersIn: span) else {
                    continue
                }
                colored.insert(integersIn: span)
                tokens.append(SyntaxToken(range: matchRange, role: rule.role))
            }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }

    /// Keys, strings, and comments in one left-to-right pass: at each step the earliest match wins (the longest on a
    /// tie), and every rule resumes searching after it. Matching rules independently would let a comment marker inside
    /// a string (`"http://x"`) swallow the rest of the line and hide a real comment after the string.
    private static func protectedTokens(in source: String, length: Int, rules: [CompiledSpec.Rule]) -> [SyntaxToken] {
        func firstMatch(_ rule: CompiledSpec.Rule, from location: Int) -> NSRange? {
            // Not anchoring `^` at the search's start, which is mid-line after a token: it means a line's start.
            let searched = NSRange(location: location, length: length - location)
            guard location < length, let match = rule.regex.firstMatch(in: source, options: .withoutAnchoringBounds, range: searched) else {
                return nil
            }
            let range = rule.captureGroup.map { match.range(at: $0) } ?? match.range
            return range.location == NSNotFound ? nil : range
        }
        var next = rules.map { firstMatch($0, from: 0) }
        var tokens: [SyntaxToken] = []
        var cursor = 0
        while true {
            var best: (index: Int, range: NSRange)?
            for (index, candidate) in next.enumerated() {
                guard let candidate else {
                    continue
                }
                if let current = best,
                   candidate.location > current.range.location
                    || (candidate.location == current.range.location && candidate.length <= current.range.length) {
                    continue
                }
                best = (index, candidate)
            }
            guard let best else {
                break
            }
            if best.range.length > 0 {
                tokens.append(SyntaxToken(range: best.range, role: rules[best.index].role))
            }
            cursor = max(cursor + (best.range.length == 0 ? 1 : 0), NSMaxRange(best.range))
            for index in next.indices where (next[index]?.location ?? Int.max) < cursor {
                next[index] = firstMatch(rules[index], from: cursor)
            }
        }
        return tokens
    }
}

/// Maps a `Content-Type` to the language its body is highlighted as.
public enum ContentTypeLanguage {
    public static func language(forContentType contentType: String?) -> SyntaxLanguage {
        guard let contentType else {
            return .plainText
        }
        let mediaType = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if mediaType.hasSuffix("+json") || mediaType.hasSuffix("/json") || mediaType == "application/x-ndjson" {
            return .json
        }
        if mediaType.hasSuffix("+xml") || mediaType.hasSuffix("/xml") {
            return .xml
        }
        if mediaType.hasSuffix("+yaml") || mediaType.hasSuffix("/yaml") || mediaType.hasSuffix("/x-yaml") {
            return .yaml
        }
        switch mediaType {
        case "text/html", "application/xhtml":
            return .html
        case "application/javascript", "text/javascript", "application/ecmascript":
            return .javascript
        case "text/css":
            return .css
        case "application/graphql":
            return .graphQL
        default:
            return .plainText
        }
    }
}
