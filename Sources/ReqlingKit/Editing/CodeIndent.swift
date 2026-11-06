import Foundation

/// How a JSON, JavaScript, or GraphQL editor indents, worked out from the text alone. On Return the new line keeps the
/// current one's indentation, one level deeper after `{` or `[`, and a bracket left open gets its closer on the line
/// after, so the cursor lands between the two; a `}` or `]` typed at the start of its line moves back to its opener's
/// indentation. Brackets inside strings, comments, regexes, template text, and (outside scripts, where `{{` is plain
/// code) `{{variables}}` are not brackets.
public enum CodeIndent {
    /// What one indentation level adds, as Tab inserts in the editors.
    public static let indentUnit = "  "

    public struct Edit: Sendable {
        /// What `replacement` replaces: the cursor, or with it the blank space up to a closer on the same line.
        public let range: NSRange
        public let replacement: String
        /// Where the cursor goes, in UTF-16 units from the start of `replacement`.
        public let caret: Int
    }

    /// The edit for Return at `cursor`, or nil where Return inserts a plain line break: inside a string, and in other
    /// languages.
    public static func newline(in text: String, at cursor: Int, language: SyntaxLanguage) -> Edit? {
        let units = text as NSString
        guard let context = Context(language, text: text, units: units, cursor: cursor), !context.cursorIsInString else {
            return nil
        }
        let line = units.lineRange(for: NSRange(location: cursor, length: 0))
        let indent = leadingWhitespace(in: units, from: line.location, upTo: cursor)
        guard !context.cursorIsInComment,
              let opener = opener(context.lastBeforeCursor, in: units, opensTemplates: language != .javascript),
              let closer = closers[opener] else {
            return Edit(range: NSRange(location: cursor, length: 0), replacement: "\n" + indent, caret: 1 + indent.utf16.count)
        }
        let lineEnd = contentEnd(of: line, in: units)
        let afterStart = firstNonBlank(in: units, from: cursor, upTo: lineEnd)
        let inner = "\n" + indent + indentUnit
        // `{|}`: the closer is already there; it moves down a line.
        if afterStart < lineEnd, units.character(at: afterStart) == closer {
            let range = NSRange(location: cursor, length: afterStart - cursor)
            return Edit(range: range, replacement: inner + "\n" + indent, caret: inner.utf16.count)
        }
        // `{|` at the end of its line, with more of this bracket open than closed: it needs its closer.
        if afterStart == lineEnd, context.unclosedCount(of: opener) > 0 {
            let range = NSRange(location: cursor, length: lineEnd - cursor)
            let closing = "\n" + indent + String(utf16CodeUnits: [closer], count: 1)
            return Edit(range: range, replacement: inner + closing, caret: inner.utf16.count)
        }
        return Edit(range: NSRange(location: cursor, length: 0), replacement: inner, caret: inner.utf16.count)
    }

    /// The edit for typing `typed` at `cursor`: a `}` or `]` typed where only blanks precede it on its line takes the
    /// indentation of the line that opened the bracket it closes. Nil where it is typed as is: anywhere else, inside a
    /// string or comment, when no bracket of its kind is open, and when the line already has that indentation.
    public static func typing(_ typed: String, in text: String, at cursor: Int, language: SyntaxLanguage) -> Edit? {
        let units = text as NSString
        guard typed.utf16.count == 1, let closer = typed.utf16.first, closers.values.contains(closer) else {
            return nil
        }
        let lineStart = units.lineRange(for: NSRange(location: cursor, length: 0)).location
        guard firstNonBlank(in: units, from: lineStart, upTo: cursor) == cursor,
              let context = Context(language, text: text, units: units, cursor: cursor),
              !context.cursorIsInString, !context.cursorIsInComment,
              let opener = context.openBeforeCursor.last, closers[opener.unit] == closer else {
            return nil
        }
        let openerLine = units.lineRange(for: NSRange(location: opener.index, length: 0))
        let indent = leadingWhitespace(in: units, from: openerLine.location, upTo: opener.index)
        let range = NSRange(location: lineStart, length: cursor - lineStart)
        guard units.substring(with: range) != indent else {
            return nil
        }
        let replacement = indent + typed
        return Edit(range: range, replacement: replacement, caret: replacement.utf16.count)
    }

    private static let openBrace = unichar(UInt8(ascii: "{"))
    private static let closeBrace = unichar(UInt8(ascii: "}"))
    private static let openBracket = unichar(UInt8(ascii: "["))
    private static let closeBracket = unichar(UInt8(ascii: "]"))
    private static let quote = unichar(UInt8(ascii: "\""))
    private static let backslash = unichar(UInt8(ascii: "\\"))
    private static let lineBreaks: Set<unichar> = [unichar(UInt8(ascii: "\n")), unichar(UInt8(ascii: "\r"))]
    private static let closers: [unichar: unichar] = [openBrace: closeBrace, openBracket: closeBracket]

    /// Plain comparisons rather than a set: every Return scans the whole document, which can be megabytes.
    private static func isBracket(_ unit: unichar) -> Bool {
        unit == openBrace || unit == closeBrace || unit == openBracket || unit == closeBracket
    }

    private static func isBlank(_ unit: unichar) -> Bool {
        unit == unichar(UInt8(ascii: " ")) || unit == unichar(UInt8(ascii: "\t"))
    }

    /// The opening bracket that ends the code before the cursor on its line; never the second `{` of a `{{` still
    /// being typed, which opens a variable, where `opensTemplates` says the language has them.
    private static func opener(_ last: (unit: unichar, index: Int)?, in units: NSString, opensTemplates: Bool) -> unichar? {
        guard let last, closers[last.unit] != nil else {
            return nil
        }
        if opensTemplates, last.unit == openBrace, last.index > 0, units.character(at: last.index - 1) == openBrace {
            return nil
        }
        return last.unit
    }

    /// The line's leading spaces and tabs, stopping at the cursor when it sits inside them.
    private static func leadingWhitespace(in units: NSString, from start: Int, upTo cursor: Int) -> String {
        var end = start
        while end < cursor, isBlank(units.character(at: end)) {
            end += 1
        }
        return units.substring(with: NSRange(location: start, length: end - start))
    }

    /// Where the line's text ends, before its line break.
    private static func contentEnd(of line: NSRange, in units: NSString) -> Int {
        var end = NSMaxRange(line)
        while end > line.location, lineBreaks.contains(units.character(at: end - 1)) {
            end -= 1
        }
        return end
    }

    private static func firstNonBlank(in units: NSString, from start: Int, upTo end: Int) -> Int {
        var index = start
        while index < end, isBlank(units.character(at: index)) {
            index += 1
        }
        return index
    }

    /// What one pass over the document finds: where the cursor sits, the code character that ends the text before it
    /// on its line, the brackets still open at the cursor, and how many of each bracket there are, all outside strings
    /// and comments.
    private struct Context {
        private(set) var cursorIsInString = false
        private(set) var cursorIsInComment = false
        /// The last character of code before the cursor on its line; for GraphQL, only when it is a bracket.
        private(set) var lastBeforeCursor: (unit: unichar, index: Int)?
        /// The brackets opened before the cursor and not closed by then, innermost last.
        private(set) var openBeforeCursor: [(unit: unichar, index: Int)] = []
        private var counts: [unichar: Int] = [:]
        private var inString = false
        private var escaped = false

        /// Nil for a language without these rules.
        init?(_ language: SyntaxLanguage, text: String, units: NSString, cursor: Int) {
            switch language {
            case .json:
                self.init(json: units, cursor: cursor)
            case .graphQL:
                self.init(graphQL: text, units: units, cursor: cursor)
            case .javascript:
                self.init(javaScript: text, units: units, cursor: cursor)
            default:
                return nil
            }
        }

        init(json units: NSString, cursor: Int) {
            let lineStart = units.lineRange(for: NSRange(location: cursor, length: 0)).location
            for index in 0..<units.length {
                if index == cursor {
                    cursorIsInString = inString
                }
                let unit = units.character(at: index)
                guard stepJSON(unit), index < cursor else {
                    continue
                }
                if CodeIndent.isBracket(unit) {
                    track(unit, at: index)
                }
                if index >= lineStart, !CodeIndent.isBlank(unit) {
                    lastBeforeCursor = (unit, index)
                }
            }
            if cursor >= units.length {
                cursorIsInString = inString
            }
        }

        /// From the GraphQL lexer's tokens, which already set strings, block strings, comments, and closed
        /// `{{variables}}` apart from the punctuation. The character before the cursor is a bracket only where a
        /// punctuator starts, never inside a name or a variable the cursor sits in or after.
        init(graphQL text: String, units: NSString, cursor: Int) {
            let lineStart = units.lineRange(for: NSRange(location: cursor, length: 0)).location
            var last = cursor - 1
            while last >= lineStart, CodeIndent.isBlank(units.character(at: last)) {
                last -= 1
            }
            for token in GraphQLLexer.tokens(in: text) {
                switch token.kind {
                case .string, .blockString:
                    cursorIsInString = cursorIsInString || token.holds(cursor)
                case .comment:
                    cursorIsInComment = cursorIsInComment || token.holds(cursor)
                case .punctuator where CodeIndent.isBracket(units.character(at: token.range.location)):
                    let unit = units.character(at: token.range.location)
                    counts[unit, default: 0] += 1
                    if token.range.location < cursor {
                        track(unit, at: token.range.location)
                    }
                    if token.range.location == last {
                        lastBeforeCursor = (unit, last)
                    }
                default:
                    break
                }
            }
        }

        /// From `JavaScriptLexer`'s tokens, so strings, template text, regexes, and comments are set apart exactly as
        /// highlighting sees them. A template's `${` counts as the `{` it ends with, closed by its `}`.
        init(javaScript text: String, units: NSString, cursor: Int) {
            let lineStart = units.lineRange(for: NSRange(location: cursor, length: 0)).location
            var last = cursor - 1
            while last >= lineStart, CodeIndent.isBlank(units.character(at: last)) {
                last -= 1
            }
            for token in JavaScriptLexer.tokens(in: text) {
                switch token.kind {
                case .string, .templateText, .regex:
                    cursorIsInString = cursorIsInString || token.holds(cursor)
                case .comment:
                    cursorIsInComment = cursorIsInComment || token.holds(cursor)
                case .punctuator where token.text == "${" || (token.range.length == 1 && CodeIndent.isBracket(units.character(at: token.end - 1))):
                    let index = token.end - 1
                    let unit = units.character(at: index)
                    counts[unit, default: 0] += 1
                    if index < cursor {
                        track(unit, at: index)
                    }
                    if index == last {
                        lastBeforeCursor = (unit, index)
                    }
                default:
                    break
                }
            }
        }

        func unclosedCount(of opener: unichar) -> Int {
            guard let closer = CodeIndent.closers[opener] else {
                return 0
            }
            return counts[opener, default: 0] - counts[closer, default: 0]
        }

        /// Opens or closes a bracket before the cursor. A closer that does not match the innermost opener is left out,
        /// as text being edited often has one.
        private mutating func track(_ unit: unichar, at index: Int) {
            if CodeIndent.closers[unit] != nil {
                openBeforeCursor.append((unit, index))
            } else if let innermost = openBeforeCursor.last, CodeIndent.closers[innermost.unit] == unit {
                openBeforeCursor.removeLast()
            }
        }

        /// Moves past `unit` in JSON, counting it if it is a bracket outside a string; returns whether it was outside one.
        private mutating func stepJSON(_ unit: unichar) -> Bool {
            if inString {
                if escaped {
                    escaped = false
                } else if unit == CodeIndent.backslash {
                    escaped = true
                } else if unit == CodeIndent.quote {
                    inString = false
                }
                return false
            }
            if unit == CodeIndent.quote {
                inString = true
            } else if CodeIndent.isBracket(unit) {
                counts[unit, default: 0] += 1
            }
            return true
        }
    }
}
