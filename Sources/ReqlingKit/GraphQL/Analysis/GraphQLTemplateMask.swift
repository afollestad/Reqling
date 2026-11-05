import Foundation

/// A document with every `{{template}}` replaced by text GraphQL can parse, of the same UTF-16 length, so a query can
/// be validated before its variables resolve and every position still lines up with the editor's.
///
/// What a template becomes depends on where it stands, as the parser reads it: `null` (padded with spaces) where a
/// value goes, underscores where a name goes, and `x`s inside a string. A diagnostic starting inside a template, or a
/// syntax error just after one, is about what the mask put there, so the validator drops it.
struct GraphQLTemplateMask {
    let text: String
    /// The templates' ranges.
    let regions: [NSRange]

    /// `tokens` are `original`'s, from `GraphQLLexer`.
    init(_ original: String, tokens: [GraphQLToken], typeSystem: GraphQLTypeSystem) {
        var units = Array(original.utf16)
        var regions: [NSRange] = []
        let strings = tokens.filter {
            if case .string = $0.kind { true } else if case .blockString = $0.kind { true } else { false }
        }
        let inStrings = TemplateParser.tokens(in: original).filter { template in
            strings.contains { NSIntersectionRange($0.range, template.utf16Range).length > 0 }
        }
        for template in inStrings {
            Self.fill(&units, template.utf16Range, with: "x")
            regions.append(template.utf16Range)
        }
        var parser = GraphQLDocumentParser(typeSystem: typeSystem)
        for token in tokens {
            _ = parser.consume(token)
            guard token.kind == .template else {
                continue
            }
            switch parser.consumer {
            case .value?, .list?:
                Self.fill(&units, token.range, with: " ")
                Self.fill(&units, NSRange(location: token.range.location, length: min(4, token.range.length)), with: "null")
            default:
                Self.fill(&units, token.range, with: "_")
            }
            regions.append(token.range)
        }
        text = String(decoding: units, as: UTF16.self)
        self.regions = regions.sorted { $0.location < $1.location }
    }

    /// Whether a diagnostic at `location` is about the mask rather than the query: it starts inside a template, or
    /// at the token right after one, where a syntax error lands when the masked text does not fit.
    func covers(_ location: Int, syntaxError: Bool, tokens: [GraphQLToken]) -> Bool {
        regions.contains { region in
            if location >= region.location, location < NSMaxRange(region) {
                return true
            }
            guard syntaxError else {
                return false
            }
            let next = tokens.first { $0.range.location >= NSMaxRange(region) }?.range.location ?? NSMaxRange(region)
            return location == NSMaxRange(region) || location == next
        }
    }

    /// Overwrites `range` with `pattern`, repeated or cut to fit; patterns are ASCII, one unit per character.
    private static func fill(_ units: inout [UInt16], _ range: NSRange, with pattern: String) {
        let pattern = Array(pattern.utf16)
        for offset in 0..<range.length where range.location + offset < units.count {
            units[range.location + offset] = pattern[offset % pattern.count]
        }
    }
}
