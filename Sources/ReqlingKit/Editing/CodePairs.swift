import Foundation

/// Brackets and quotes in a JavaScript editor (a script, or a raw JavaScript body), paired as they are typed, as code
/// editors do. Worked out from `JavaScriptLexer`'s tokens, so strings, template text, regexes, and comments are told
/// apart from code exactly as highlighting tells them. Other languages type every character as it is.
///
/// - `(`, `[`, and `{` in code bring their closer, the cursor between them, before the end, a blank, or punctuation
///   such as `)`, `,`, or `;`; never in front of a name, which the closer would land before. A `{` typed after `$`
///   in template text opens a substitution, `${}`.
/// - A quote or backtick in code brings its pair under the same rule, unless a name or another quote ends right
///   before it, as in `don't`.
/// - Typing a closer, quote, or backtick just before the one that already closes its bracket, string, or template
///   steps over it; a bracket steps over only while none of its kind is left open to close.
/// - Backspace between an empty pair removes both.
public enum CodePairs {
    public enum Typing: Equatable, Sendable {
        /// Type the character with `closer` after it, the cursor between them.
        case pair(closer: String)
        /// Move past the closer after the cursor instead of typing another.
        case stepOver
    }

    /// What typing `typed` at `cursor` does instead of inserting it, or nil to insert it as is.
    public static func typing(_ typed: String, in text: String, at cursor: Int, language: SyntaxLanguage) -> Typing? {
        guard language == .javascript, typed.utf16.count == 1, let unit = typed.utf16.first,
              closers[unit] != nil || openers[unit] != nil || quotes.contains(unit) else {
            return nil
        }
        let units = text as NSString
        let next = cursor < units.length ? units.character(at: cursor) : nil
        let previous = cursor > 0 ? units.character(at: cursor - 1) : nil
        let pairsHere = next.map(pairsBefore.contains) ?? true
        let scan = Scan(text, units: units, cursor: cursor)
        if let closer = closers[unit] {
            if scan.cursorIsInCode, pairsHere {
                return .pair(closer: String(utf16CodeUnits: [closer], count: 1))
            }
            if unit == openBrace, previous == dollar, scan.cursorIsInTemplateText, pairsHere || next == backtick {
                return .pair(closer: "}")
            }
            return nil
        }
        if openers[unit] != nil {
            return scan.cursorIsInCode && scan.closerAtCursor == unit && scan.unclosed(closer: unit) <= 0 ? .stepOver : nil
        }
        if scan.quoteClosingAtCursor == unit {
            return .stepOver
        }
        guard scan.cursorIsInCode, pairsHere, !(previous.map { isNameUnit($0) || quotes.contains($0) } ?? false) else {
            return nil
        }
        return .pair(closer: typed)
    }

    /// Whether Backspace at `cursor` removes the empty pair around it rather than only its opener.
    public static func deletesPair(in text: String, at cursor: Int, language: SyntaxLanguage) -> Bool {
        let units = text as NSString
        guard language == .javascript, cursor >= 1, cursor < units.length else {
            return false
        }
        let opener = units.character(at: cursor - 1)
        let closer = units.character(at: cursor)
        let scan = Scan(text, units: units, cursor: cursor)
        if closers[opener] == closer {
            return scan.openerEndingAtCursor == opener && scan.closerAtCursor == closer
        }
        return quotes.contains(opener) && opener == closer && scan.emptyQuotesAroundCursor
    }

    private static func unit(_ character: Character) -> unichar {
        character.utf16.first ?? 0
    }

    private static let openBrace = unit("{")
    private static let dollar = unit("$")
    private static let backtick = unit("`")
    private static let closers: [unichar: unichar] = [unit("("): unit(")"), unit("["): unit("]"), openBrace: unit("}")]
    private static let openers: [unichar: unichar] = Dictionary(uniqueKeysWithValues: closers.map { ($1, $0) })
    private static let quotes: Set<unichar> = [unit("\""), unit("'"), backtick]
    /// What an opener or quote may be typed before and still get its closer: blanks, line breaks, and punctuation
    /// that ends or continues an expression, as VS Code's JavaScript rules have it.
    private static let pairsBefore: Set<unichar> = Set(" \t\r\n;:.,=}])>".utf16)

    private static func isNameUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else {
            return false
        }
        return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
    }

    /// One pass over the script's tokens: where the cursor sits, how many of each bracket there are, and the bracket,
    /// quote, or string boundary next to the cursor.
    private struct Scan {
        private(set) var cursorIsInCode = true
        private(set) var cursorIsInTemplateText = false
        /// A bracket's closer that starts at the cursor, and an opener that ends there (`${` as its `{`).
        private(set) var closerAtCursor: unichar?
        private(set) var openerEndingAtCursor: unichar?
        /// The quote or backtick at the cursor that closes the string or template the cursor is in.
        private(set) var quoteClosingAtCursor: unichar?
        /// The cursor sits in an empty string or template: `""`, `''`, or two backticks.
        private(set) var emptyQuotesAroundCursor = false
        private var opened: [unichar: Int] = [:]
        private var closed: [unichar: Int] = [:]

        init(_ text: String, units: NSString, cursor: Int) {
            for token in JavaScriptLexer.tokens(in: text) {
                switch token.kind {
                case .string(let terminated):
                    enterLiteral(token, units: units, cursor: cursor, terminated: terminated, resumes: false)
                case .templateText(let terminated):
                    // Text resuming after a substitution's `}`, rather than opening with its own backtick: it starts
                    // with anything but a backtick, is only the closing backtick, or is empty at the end of the text.
                    let first = token.range.length > 0 ? units.character(at: token.range.location) : nil
                    let resumes = first != CodePairs.backtick || (terminated && token.range.length == 1)
                    if token.holds(cursor) || (resumes && token.range.location == cursor) {
                        cursorIsInTemplateText = true
                    }
                    enterLiteral(token, units: units, cursor: cursor, terminated: terminated, resumes: resumes)
                case .regex, .comment:
                    if token.holds(cursor) {
                        cursorIsInCode = false
                    }
                case .punctuator:
                    count(token, units: units, cursor: cursor)
                default:
                    break
                }
            }
        }

        func unclosed(closer: unichar) -> Int {
            opened[closer, default: 0] - closed[closer, default: 0]
        }

        /// Notes a string or template piece: whether it holds the cursor, and whether its closing quote is at the
        /// cursor or it is empty around it. Typing at the start of a resumed piece types into the template.
        private mutating func enterLiteral(_ token: JavaScriptToken, units: NSString, cursor: Int, terminated: Bool, resumes: Bool) {
            let range = token.range
            if token.holds(cursor) || (resumes && range.location == cursor) {
                cursorIsInCode = false
            }
            guard terminated, token.end == cursor + 1, range.location < cursor || resumes else {
                return
            }
            let quote = units.character(at: cursor)
            guard CodePairs.quotes.contains(quote) else {
                return
            }
            quoteClosingAtCursor = quote
            emptyQuotesAroundCursor = !resumes && range.location == cursor - 1 && units.character(at: range.location) == quote
        }

        /// Counts a bracket punctuator, and notes one that meets the cursor.
        private mutating func count(_ token: JavaScriptToken, units: NSString, cursor: Int) {
            let last = units.character(at: token.end - 1)
            if let closer = CodePairs.closers[last], token.text == "${" || token.range.length == 1 {
                opened[closer, default: 0] += 1
                if token.end == cursor {
                    openerEndingAtCursor = last
                }
            } else if CodePairs.openers[last] != nil, token.range.length == 1 {
                closed[last, default: 0] += 1
                if token.range.location == cursor {
                    closerAtCursor = last
                }
            }
        }
    }
}
