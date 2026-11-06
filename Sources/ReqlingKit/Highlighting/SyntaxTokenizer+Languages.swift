import Foundation

/// The per-language rules, compiled once. Patterns follow Alveary's `SyntaxHighlighter+Languages.swift`, plus a
/// protected `property` rule for object keys and a GraphQL spec.
struct CompiledSpec: @unchecked Sendable {
    // `NSRegularExpression` is immutable and documented thread-safe, but not annotated `Sendable`.
    struct Rule {
        let regex: NSRegularExpression
        let role: SyntaxRole
        /// Colors only this capture group (YAML keys exclude their indentation).
        let captureGroup: Int?
    }

    let protected: [Rule]
    let unprotected: [Rule]

    static let specs: [SyntaxLanguage: CompiledSpec] = {
        let doubleQuoted = #""([^"\\]|\\.)*""#
        let singleQuoted = #"'([^'\\]|\\.)*'"#
        let markup = CompiledSpec(
            protected: [rule(#"<!--[\s\S]*?-->"#, .comment), rule(doubleQuoted, .string), rule(singleQuoted, .string)],
            unprotected: [
                rule(#"<!DOCTYPE[\s\S]*?>"#, .keyword, options: [.caseInsensitive]),
                rule(#"<\?xml[\s\S]*?\?>"#, .keyword),
                rule(#"</?[A-Za-z_][A-Za-z0-9:._-]*"#, .keyword),
                rule(#"\s([A-Za-z_:][A-Za-z0-9:._-]*)(?=\s*=)"#, .property, group: 1),
                rule(#"&[A-Za-z0-9#]+;"#, .keyword),
                rule(#"[<>/=]"#, .symbol)
            ]
        )
        return [
            .json: CompiledSpec(
                protected: [rule(#""([^"\\]|\\.)*"(?=\s*:)"#, .property), rule(doubleQuoted, .string)],
                unprotected: [
                    keywords(["true", "false", "null"]),
                    rule(#"-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b"#, .number),
                    rule(#"[{}\[\]:,]"#, .symbol)
                ]
            ),
            .xml: markup,
            .html: markup,
            .yaml: CompiledSpec(
                protected: [rule("#.*$", .comment), rule(doubleQuoted, .string), rule(#"'[^']*'"#, .string)],
                unprotected: [
                    rule(#"^[\s-]*([A-Za-z_][A-Za-z0-9_.-]*)\s*:"#, .property, group: 1),
                    keywords(["true", "false", "null", "yes", "no", "~"]),
                    rule(#"\b-?\d+(\.\d+)?\b"#, .number)
                ]
            ),
            .css: CompiledSpec(
                protected: [rule(#"/\*[\s\S]*?\*/"#, .comment), rule(doubleQuoted, .string), rule(singleQuoted, .string)],
                unprotected: [
                    rule(#"@[A-Za-z-]+"#, .keyword),
                    rule(#"(^|[;\{\s])([-A-Za-z_][-\w]*)\s*(?=:)"#, .property, group: 2),
                    rule(#"#[0-9A-Fa-f]{3,8}\b"#, .number),
                    keywords(["important", "inherit", "initial", "unset", "revert"]),
                    rule(#"\b-?\d+(\.\d+)?(px|em|rem|vh|vw|%|s|ms|deg)?\b"#, .number),
                    rule(#"[{}();:,]"#, .symbol)
                ]
            ),
            .graphQL: CompiledSpec(
                protected: [rule("#.*$", .comment), rule(#""""[\s\S]*?""""#, .string), rule(doubleQuoted, .string)],
                unprotected: [
                    keywords([
                        "query", "mutation", "subscription", "fragment", "on", "type", "input", "enum", "interface",
                        "union", "scalar", "schema", "extend", "directive", "implements", "true", "false", "null"
                    ], caseInsensitive: false),
                    rule(#"\$[A-Za-z_][A-Za-z0-9_]*"#, .property),
                    rule(#"@[A-Za-z_][A-Za-z0-9_]*"#, .keyword),
                    rule(#"\b-?\d+(\.\d+)?\b"#, .number),
                    rule(#"[{}()\[\]:!=|&]"#, .symbol)
                ]
            ),
            .plainText: CompiledSpec(protected: [], unprotected: [])
        ]
    }()

    private static func rule(_ pattern: String, _ role: SyntaxRole, group: Int? = nil, options: NSRegularExpression.Options = []) -> Rule {
        // The patterns are constants; a typo should fail loudly in development, not degrade to no highlighting.
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options.union(.anchorsMatchLines)) else {
            preconditionFailure("Invalid syntax pattern: \(pattern)")
        }
        return Rule(regex: regex, role: role, captureGroup: group)
    }

    private static func keywords(_ words: [String], caseInsensitive: Bool = true) -> Rule {
        let alternatives = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return rule(#"(?<![\w$])("# + alternatives + #")(?![\w$])"#, .keyword, options: caseInsensitive ? [.caseInsensitive] : [])
    }
}
