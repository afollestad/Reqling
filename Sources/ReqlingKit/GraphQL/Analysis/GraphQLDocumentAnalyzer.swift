import Foundation
import ReqlingTemplating

/// A GraphQL document read against a schema, for completion at the cursor and hover over a name. Offsets are UTF-16,
/// as AppKit text views count.
///
/// Building one reads the whole document once; each question rereads it up to the point asked about, which is cheap
/// for queries of any realistic size and keeps every answer exactly what the parser would say there.
public struct GraphQLDocumentAnalyzer: Sendable {
    public let text: String
    let typeSystem: GraphQLTypeSystem
    let tokens: [GraphQLToken]
    let outline: GraphQLDocumentParser.Outline

    public init(text: String, typeSystem: GraphQLTypeSystem) {
        self.text = text
        self.typeSystem = typeSystem
        tokens = GraphQLLexer.tokens(in: text)
        var parser = GraphQLDocumentParser(typeSystem: typeSystem)
        for token in tokens {
            _ = parser.consume(token)
        }
        parser.finish()
        outline = parser.outline
    }

    /// What may be typed at `cursor`: nil inside a string, a comment, or a `{{template}}` (whose completion is the
    /// editor's own), and where nothing from the schema fits, such as an operation's name.
    public func completions(at cursor: Int) -> GraphQLCompletionList? {
        let cursor = min(max(cursor, 0), text.utf16.count)
        guard TemplateParser.openTokenRange(in: text as NSString, cursor: cursor) == nil else {
            return nil
        }
        if let holder = tokens.first(where: { $0.holds(cursor) }), holder.kind != .name {
            return nil
        }
        // The name being typed is replaced whole; what precedes the cursor in it narrows the list.
        let partial = tokens.firstIndex { $0.kind == .name && $0.range.location < cursor && cursor <= $0.end }
        let boundary = partial ?? tokens.firstIndex { $0.range.location >= cursor } ?? tokens.count
        let parser = parser(through: boundary)
        guard let role = parser.role(ofNameAt: cursor) else {
            return nil
        }
        var replacement = partial.map { tokens[$0].range } ?? NSRange(location: cursor, length: 0)
        let typed = partial.map { String(tokens[$0].text.utf16.prefix(cursor - tokens[$0].range.location)) ?? "" } ?? ""
        if case .variable = role, boundary > 0, tokens[boundary - 1].isPunctuator("$"), tokens[boundary - 1].end == replacement.location {
            let dollar = tokens[boundary - 1].range.location
            replacement = NSRange(location: dollar, length: NSMaxRange(replacement) - dollar)
        }
        let candidates = GraphQLCompletionCandidates(typeSystem: typeSystem, outline: outline, operation: parser.currentOperation)
        let items = GraphQLCompletionRanking.rank(candidates.items(for: role), by: typed, name: \.filterText, isDeprecated: \.isDeprecated)
        return GraphQLCompletionList(replacementRange: replacement, items: items)
    }

    /// What the name at `offset` is, or nil where it is not a name the schema describes.
    public func hover(at offset: Int) -> GraphQLHover? {
        guard var index = tokens.firstIndex(where: { $0.range.location <= offset && offset < $0.end }) else {
            return nil
        }
        var start = tokens[index].range.location
        if tokens[index].isPunctuator("$"), index + 1 < tokens.count, tokens[index + 1].range.location == tokens[index].end {
            index += 1
        } else if index > 0, tokens[index - 1].isPunctuator("$"), tokens[index - 1].end == start {
            start = tokens[index - 1].range.location
        }
        let token = tokens[index]
        guard token.kind == .name else {
            return nil
        }
        var parser = parser(through: index)
        guard let role = parser.consume(token) else {
            return nil
        }
        // An alias describes the field it names: `title` in `heading: title`.
        var name = token.text
        if case .field = role, index + 2 < tokens.count, tokens[index + 1].isPunctuator(":"), tokens[index + 2].kind == .name {
            name = tokens[index + 2].text
        }
        let describer = GraphQLHoverDescriber(typeSystem: typeSystem, outline: outline, operation: parser.currentOperation)
        guard let description = describer.describe(role, name: name) else {
            return nil
        }
        return GraphQLHover(
            range: NSRange(location: start, length: token.end - start),
            signature: description.signature,
            description: description.description,
            deprecationReason: description.deprecationReason
        )
    }

    /// The parser after the first `count` tokens.
    func parser(through count: Int) -> GraphQLDocumentParser {
        var parser = GraphQLDocumentParser(typeSystem: typeSystem)
        for token in tokens.prefix(count) {
            _ = parser.consume(token)
        }
        return parser
    }
}
