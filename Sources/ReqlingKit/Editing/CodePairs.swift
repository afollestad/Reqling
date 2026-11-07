import Foundation

/// Brackets and quotes in a JavaScript editor (a script, or a raw JavaScript body) and a GraphQL query editor, paired as
/// they are typed, as code editors do. Worked out from each language's lexer, so strings, comments, and the rest are
/// told apart from code exactly as highlighting tells them. Other languages type every character as it is.
///
/// - `(`, `[`, and `{` in code bring their closer, the cursor between them, before the end, a blank, or punctuation
///   such as `)`, `,`, or `;`; never in front of a name, which the closer would land before. In JavaScript, a `{`
///   typed after `$` in template text opens a substitution, `${}`.
/// - A quote (in JavaScript also `'` and a backtick) in code brings its pair under the same rule, unless a name or
///   another quote ends right before it, as in `don't`. GraphQL's `"""` block strings are typed as they are.
/// - Typing a closer or quote just before the one that already closes its bracket, string, or template steps over it;
///   a bracket steps over only while none of its kind is left open to close. A `}` typed before a GraphQL
///   `{{variable}}`'s closing braces steps over them too, as a `{{variable}}` there is one token.
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
        guard let quotes = quotes(in: language), typed.utf16.count == 1, let unit = typed.utf16.first,
              closers[unit] != nil || openers[unit] != nil || quotes.contains(unit) else {
            return nil
        }
        let units = text as NSString
        let next = cursor < units.length ? units.character(at: cursor) : nil
        let previous = cursor > 0 ? units.character(at: cursor - 1) : nil
        let pairsHere = next.map(pairsBefore.contains) ?? true
        let scan = Scan(language, text: text, units: units, cursor: cursor)
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
            if unit == closeBrace, scan.cursorIsBeforeVariableClose {
                return .stepOver
            }
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
        guard let quotes = quotes(in: language), cursor >= 1, cursor < units.length else {
            return false
        }
        let opener = units.character(at: cursor - 1)
        let closer = units.character(at: cursor)
        let scan = Scan(language, text: text, units: units, cursor: cursor)
        if closers[opener] == closer {
            return scan.openerEndingAtCursor == opener && scan.closerAtCursor == closer
        }
        return quotes.contains(opener) && opener == closer && scan.emptyQuotesAroundCursor
    }

    /// The quotes a language pairs; nil for a language that pairs nothing.
    private static func quotes(in language: SyntaxLanguage) -> Set<unichar>? {
        switch language {
        case .javascript: [quote, unit("'"), backtick]
        case .graphQL: [quote]
        default: nil
        }
    }

    private static func unit(_ character: Character) -> unichar {
        character.utf16.first ?? 0
    }

    private static let openBrace = unit("{")
    private static let closeBrace = unit("}")
    private static let dollar = unit("$")
    private static let quote = unit("\"")
    private static let backtick = unit("`")
    private static let closers: [unichar: unichar] = [unit("("): unit(")"), unit("["): unit("]"), openBrace: closeBrace]
    private static let openers: [unichar: unichar] = Dictionary(uniqueKeysWithValues: closers.map { ($1, $0) })
    private static let allQuotes: Set<unichar> = [quote, unit("'"), backtick]
    /// What an opener or quote may be typed before and still get its closer: blanks, line breaks, and punctuation
    /// that ends or continues an expression, as VS Code's JavaScript rules have it.
    private static let pairsBefore: Set<unichar> = Set(" \t\r\n;:.,=}])>".utf16)

    private static func isNameUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else {
            return false
        }
        return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
    }

    /// One pass over the text's tokens: where the cursor sits, how many of each bracket there are, and the bracket,
    /// quote, or string boundary next to the cursor.
    private struct Scan {
        private(set) var cursorIsInCode = true
        private(set) var cursorIsInTemplateText = false
        /// The cursor is just before a GraphQL `{{variable}}`'s closing braces, inside the token.
        private(set) var cursorIsBeforeVariableClose = false
        /// A bracket's closer that starts at the cursor, and an opener that ends there (`${` as its `{`).
        private(set) var closerAtCursor: unichar?
        private(set) var openerEndingAtCursor: unichar?
        /// The quote or backtick at the cursor that closes the string or template the cursor is in.
        private(set) var quoteClosingAtCursor: unichar?
        /// The cursor sits in an empty string or template: `""`, `''`, or two backticks.
        private(set) var emptyQuotesAroundCursor = false
        private var opened: [unichar: Int] = [:]
        private var closed: [unichar: Int] = [:]
        private let units: NSString
        private let cursor: Int

        init(_ language: SyntaxLanguage, text: String, units: NSString, cursor: Int) {
            self.units = units
            self.cursor = cursor
            if language == .graphQL {
                readGraphQL(text)
            } else {
                readJavaScript(text)
            }
        }

        func unclosed(closer: unichar) -> Int {
            opened[closer, default: 0] - closed[closer, default: 0]
        }

        private mutating func readJavaScript(_ text: String) {
            for token in JavaScriptLexer.tokens(in: text) {
                switch token.kind {
                case .string(let terminated):
                    enterLiteral(token.range, holds: token.holds(cursor), terminated: terminated, resumes: false)
                case .templateText(let terminated):
                    // Text resuming after a substitution's `}`, rather than opening with its own backtick: it starts
                    // with anything but a backtick, is only the closing backtick, or is empty at the end of the text.
                    let first = token.range.length > 0 ? units.character(at: token.range.location) : nil
                    let resumes = first != CodePairs.backtick || (terminated && token.range.length == 1)
                    let holds = token.holds(cursor)
                    if holds || (resumes && token.range.location == cursor) {
                        cursorIsInTemplateText = true
                    }
                    enterLiteral(token.range, holds: holds, terminated: terminated, resumes: resumes)
                case .regex, .comment:
                    leaveCode(if: token.holds(cursor))
                case .punctuator:
                    count(token.range, text: token.text)
                default:
                    break
                }
            }
        }

        private mutating func readGraphQL(_ text: String) {
            for token in GraphQLLexer.tokens(in: text) {
                switch token.kind {
                case .string(let terminated):
                    enterLiteral(token.range, holds: token.holds(cursor), terminated: terminated, resumes: false)
                case .blockString, .comment:
                    leaveCode(if: token.holds(cursor))
                case .template:
                    leaveCode(if: token.holds(cursor))
                    if token.holds(cursor), cursor >= token.end - 2 {
                        cursorIsBeforeVariableClose = true
                    }
                case .punctuator:
                    count(token.range, text: token.text)
                default:
                    break
                }
            }
        }

        private mutating func leaveCode(if holds: Bool) {
            if holds {
                cursorIsInCode = false
            }
        }

        /// Notes a string or template piece: whether it holds the cursor, and whether its closing quote is at the
        /// cursor or it is empty around it. Typing at the start of a resumed piece types into the template.
        private mutating func enterLiteral(_ range: NSRange, holds: Bool, terminated: Bool, resumes: Bool) {
            leaveCode(if: holds || (resumes && range.location == cursor))
            guard terminated, NSMaxRange(range) == cursor + 1, range.location < cursor || resumes else {
                return
            }
            let quote = units.character(at: cursor)
            guard CodePairs.allQuotes.contains(quote) else {
                return
            }
            quoteClosingAtCursor = quote
            emptyQuotesAroundCursor = !resumes && range.location == cursor - 1 && units.character(at: range.location) == quote
        }

        /// Counts a bracket punctuator, and notes one that meets the cursor.
        private mutating func count(_ range: NSRange, text: String) {
            let last = units.character(at: NSMaxRange(range) - 1)
            if let closer = CodePairs.closers[last], text == "${" || range.length == 1 {
                opened[closer, default: 0] += 1
                if NSMaxRange(range) == cursor {
                    openerEndingAtCursor = last
                }
            } else if CodePairs.openers[last] != nil, range.length == 1 {
                closed[last, default: 0] += 1
                if range.location == cursor {
                    closerAtCursor = last
                }
            }
        }
    }
}
