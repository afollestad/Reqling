import Foundation

/// YAML's indentation is its structure, so Return works from the cursor's line alone rather than from brackets: the new
/// line keeps that line's indentation, one level deeper after a key that opens a block (`key:`), a block scalar's
/// indicator (`key: |`), or a bare `-` item. A closer never moves back, since YAML has none.
extension CodeIndent {
    static func yamlNewline(in units: NSString, at cursor: Int) -> Edit {
        let line = units.lineRange(for: NSRange(location: cursor, length: 0))
        let indent = leadingWhitespace(in: units, from: line.location, upTo: cursor)
        let before = units.substring(with: NSRange(location: line.location, length: cursor - line.location))
        let next: String
        if !opensYAMLBlock(before) {
            next = indent
        } else if before.trimmingCharacters(in: .whitespaces) == "-" {
            next = indent + indentUnit
        } else {
            // An item's own block scalar (`- |`) starts at the item's content; a key's block (`- key:`) one level under it.
            let content = contentIndent(of: before, after: indent)
            let rest = withoutYAMLComment(String(before.dropFirst(content.count))).trimmingCharacters(in: .whitespaces)
            next = content + (blockIndicators.contains(rest) ? "" : indentUnit)
        }
        return Edit(range: NSRange(location: cursor, length: 0), replacement: "\n" + next, caret: 1 + next.utf16.count)
    }

    private static let blockIndicators: Set<String> = ["|", ">", "|-", ">-", "|+", ">+"]

    /// Where the line's content starts, past any `- ` item markers, so a block opened in a list item (`- key:`) nests
    /// under its key rather than beside it, where it would be the item's next key.
    private static func contentIndent(of line: String, after indent: String) -> String {
        var rest = line.dropFirst(indent.count)
        var column = indent
        while rest.hasPrefix("- ") {
            let spaces = rest.dropFirst().prefix { $0 == " " }
            column += String(repeating: " ", count: 1 + spaces.count)
            rest = rest.dropFirst(1 + spaces.count)
        }
        return column
    }

    /// Whether the line's text before the cursor, its comment aside, ends where a nested block starts.
    static func opensYAMLBlock(_ text: String) -> Bool {
        let content = withoutYAMLComment(text).trimmingCharacters(in: .whitespaces)
        if content == "-" || content.hasSuffix(":") {
            return true
        }
        return blockIndicators.contains { indicator in
            content == indicator || content.hasSuffix(": \(indicator)") || content.hasSuffix("- \(indicator)")
        }
    }

    /// The text before a `#` that starts a comment: one at the start or after a blank, outside a quoted scalar. A quote
    /// opens one only where a scalar can start, so the apostrophe in `don't: x` doesn't.
    private static func withoutYAMLComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var lastNonBlank: Character?
        for index in text.indices {
            let character = text[index]
            if let open = quote {
                if character == open {
                    quote = nil
                }
            } else if character == "\"" || character == "'", lastNonBlank.map({ ":-[{,?".contains($0) }) ?? true {
                quote = character
            } else if character == "#", previous.isWhitespace {
                return String(text[..<index])
            }
            previous = character
            if !character.isWhitespace {
                lastNonBlank = character
            }
        }
        return text
    }
}
