import Foundation

/// Parentheses in a JavaScript editor (a script, or a raw JavaScript body), paired as they are typed: `(` brings its
/// `)` with the cursor between them, a `)` typed just before a `)` that already closes its call steps over it, and
/// Backspace between an empty `()` removes both. Worked out from `JavaScriptLexer`'s tokens, so a parenthesis inside a
/// string, template text, regex, or comment is typed as it is. Other languages type parentheses as they are.
public enum CodePairs {
    public enum Typing: Equatable, Sendable {
        /// Type `()` with the cursor between them.
        case pair
        /// Move past the `)` after the cursor instead of typing another.
        case stepOver
    }

    /// What typing `typed` at `cursor` does instead of inserting it, or nil to insert it as is. A `(` pairs only before
    /// the end, a blank, or punctuation such as `)`, `,`, or `;`, so one typed in front of a name doesn't close
    /// before it. A `)` steps over only while the script has no `(` left open to close.
    public static func typing(_ typed: String, in text: String, at cursor: Int, language: SyntaxLanguage) -> Typing? {
        guard language == .javascript, typed == "(" || typed == ")" else {
            return nil
        }
        let units = text as NSString
        let next = cursor < units.length ? units.character(at: cursor) : nil
        if typed == "(" {
            guard next.map(pairsBefore.contains) ?? true else {
                return nil
            }
            return Scan(text, units: units, cursor: cursor).cursorIsInCode ? .pair : nil
        }
        guard next == closeParen else {
            return nil
        }
        let scan = Scan(text, units: units, cursor: cursor)
        return scan.cursorIsInCode && scan.closesAtCursor && scan.opened <= scan.closed ? .stepOver : nil
    }

    /// Whether Backspace at `cursor` removes the empty `()` around it rather than only its `(`.
    public static func deletesPair(in text: String, at cursor: Int, language: SyntaxLanguage) -> Bool {
        let units = text as NSString
        guard language == .javascript, cursor >= 1, cursor < units.length,
              units.character(at: cursor - 1) == openParen, units.character(at: cursor) == closeParen else {
            return false
        }
        let scan = Scan(text, units: units, cursor: cursor)
        return scan.cursorIsInCode && scan.opensBeforeCursor && scan.closesAtCursor
    }

    private static let openParen = unichar(UInt8(ascii: "("))
    private static let closeParen = unichar(UInt8(ascii: ")"))
    private static let backtick = unichar(UInt8(ascii: "`"))
    /// What a `(` may be typed before and still get its `)`: blanks, line breaks, and punctuation that ends or
    /// continues an expression, as VS Code's JavaScript rules have it.
    private static let pairsBefore: Set<unichar> = Set(" \t\r\n;:.,=}])>".utf16)

    /// One pass over the script's tokens: whether the cursor is in code, how many parentheses there are, and whether
    /// one of them ends or starts at the cursor.
    private struct Scan {
        private(set) var cursorIsInCode = true
        private(set) var opened = 0
        private(set) var closed = 0
        private(set) var opensBeforeCursor = false
        private(set) var closesAtCursor = false

        init(_ text: String, units: NSString, cursor: Int) {
            for token in JavaScriptLexer.tokens(in: text) {
                switch token.kind {
                case .templateText where token.range.location == cursor && cursor < units.length
                    && units.character(at: cursor) != CodePairs.backtick:
                    // Text resuming after a substitution's `}`: typing at its start types into the template.
                    cursorIsInCode = false
                case .string, .templateText, .regex, .comment:
                    if token.holds(cursor) {
                        cursorIsInCode = false
                    }
                case .punctuator where token.text == "(":
                    opened += 1
                    opensBeforeCursor = opensBeforeCursor || token.end == cursor
                case .punctuator where token.text == ")":
                    closed += 1
                    closesAtCursor = closesAtCursor || token.range.location == cursor
                default:
                    break
                }
            }
        }
    }
}
