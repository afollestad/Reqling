import Foundation

/// One token of a script. Ranges are UTF-16, as AppKit text views count.
struct JavaScriptToken: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case identifier
        case keyword
        /// An operator or bracket, including `?.`, `=>`, and a template's `${` and the `}` that closes it.
        case punctuator
        case number
        case string(terminated: Bool)
        /// The literal text of a template, from its opening backtick (or the `}` before it) up to the next `${` or
        /// through its closing backtick.
        case templateText(terminated: Bool)
        case regex(terminated: Bool)
        /// Never terminated when it starts `//`: it runs on to its line's end, so typing there extends it, as at the
        /// end of a `/*` comment left open.
        case comment(terminated: Bool)
        case unknown
    }

    let kind: Kind
    let range: NSRange
    /// The token's own text for identifiers, keywords, punctuators, and numbers; empty for the rest, which nothing
    /// reads by text.
    let text: String

    var end: Int {
        NSMaxRange(range)
    }

    func isPunctuator(_ character: String) -> Bool {
        kind == .punctuator && text == character
    }

    /// Whether `offset` falls within the token for completion, hover, and indentation. A string, template, regex, or
    /// comment that runs on (unterminated, which a `//` comment always is) also holds its end, where typing would
    /// extend it.
    func holds(_ offset: Int) -> Bool {
        if offset > range.location, offset < end {
            return true
        }
        switch kind {
        case .string(terminated: false), .templateText(terminated: false), .regex(terminated: false), .comment(terminated: false):
            return offset == end
        default:
            return false
        }
    }
}

/// Splits a script into tokens without ever failing: an unterminated string or regex runs to its line's end, an
/// unterminated template or block comment to the end of the text, and an unknown character becomes an `.unknown` token,
/// so a half-written script still tokenizes the way it reads. The one JavaScript tokenizer: highlighting, auto-indent,
/// and script analysis all read it, so they agree on what is a string, a comment, or code.
///
/// It tells a regex from a division by the token before the slash, as engines do for every case scripts realistically
/// hold; `}` always reads as ending an expression.
enum JavaScriptLexer {
    static let keywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
        "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof",
        "let", "new", "null", "of", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined",
        "var", "void", "while", "with", "yield"
    ]

    /// Keywords after which a slash divides, because they are values.
    fileprivate static let valueKeywords: Set<String> = ["false", "null", "super", "this", "true", "undefined"]

    /// Longest first, so `===` is never read as `==` then `=`.
    fileprivate static let punctuators: [[UInt16]] = [
        ">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=",
        "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "**", "++", "--", "<<", ">>", "+=", "-=", "*=", "/=", "%=",
        "&=", "|=", "^="
    ].map { Array($0.utf16) }

    fileprivate static let singlePunctuators: Set<UInt16> = Set("{}()[];,<>+-*/%&|^!~?:=.@#".utf16)

    static func tokens(in text: String) -> [JavaScriptToken] {
        var scanner = Scanner(units: Array(text.utf16))
        while scanner.index < scanner.units.count {
            scanner.step()
        }
        return scanner.tokens
    }

    /// Syntax roles for highlighting: an identifier after `.` or `?.` reads as a property, and a template's `${` and
    /// the `}` that closes it (the one template text follows directly) as symbols set apart from the text around them.
    static func syntaxTokens(in text: String) -> [SyntaxToken] {
        let tokens = tokens(in: text)
        var result: [SyntaxToken] = []
        var previous: JavaScriptToken?
        for (position, token) in tokens.enumerated() {
            let role: SyntaxRole?
            switch token.kind {
            case .keyword:
                role = .keyword
            case .string, .templateText, .regex:
                role = .string
            case .number:
                role = .number
            case .comment:
                role = .comment
            case .identifier:
                role = previous?.isPunctuator(".") == true || previous?.isPunctuator("?.") == true ? .property : nil
            case .punctuator where token.text == "${":
                role = .symbol
            case .punctuator where token.text == "}":
                let following = tokens.indices.contains(position + 1) ? tokens[position + 1] : nil
                if case .templateText = following?.kind, following?.range.location == token.end {
                    role = .symbol
                } else {
                    role = nil
                }
            case .punctuator, .unknown:
                role = nil
            }
            if let role, token.range.length > 0 {
                result.append(SyntaxToken(range: token.range, role: role))
            }
            if case .comment = token.kind {
                continue
            }
            previous = token
        }
        return result
    }
}

/// One pass over a script's UTF-16 units, emitting tokens as it goes. The brace stack tells a substitution's closing `}`
/// from a block's, so template text resumes after the right one.
private struct Scanner {
    private enum Brace {
        case code
        case template
    }

    let units: [UInt16]
    private(set) var index = 0
    private(set) var tokens: [JavaScriptToken] = []
    private var braces: [Brace] = []

    init(units: [UInt16]) {
        self.units = units
    }

    /// Scans the token, or the run of whitespace, starting at `index`.
    mutating func step() {
        let start = index
        let unit = units[index]
        if Code.isWhitespace(unit) {
            index += 1
        } else if unit == Code.slash, scanComment(from: start) {
            return
        } else if unit == Code.slash, startsRegex(after: tokens.last) {
            emit(.regex(terminated: scanRegex()), from: start)
        } else if unit == Code.quote || unit == Code.apostrophe {
            emit(.string(terminated: scanString(quote: unit)), from: start)
        } else if unit == Code.backtick {
            index += 1
            scanTemplate(from: start)
        } else if Code.isIdentifierStart(unit) {
            scanWord(from: start)
        } else if Code.isDigit(unit) || (unit == Code.dot && peek(1).map(Code.isDigit) == true) {
            scanNumber()
            emit(.number, from: start, keepsText: true)
        } else {
            scanPunctuator(from: start)
        }
    }

    private func peek(_ offset: Int) -> UInt16? {
        index + offset < units.count ? units[index + offset] : nil
    }

    private mutating func emit(_ kind: JavaScriptToken.Kind, from start: Int, keepsText: Bool = false) {
        let text = keepsText ? String(utf16CodeUnits: Array(units[start..<index]), count: index - start) : ""
        tokens.append(JavaScriptToken(kind: kind, range: NSRange(location: start, length: index - start), text: text))
    }

    /// A `//` or `/*` comment at `start`, if there is one there.
    private mutating func scanComment(from start: Int) -> Bool {
        if peek(1) == Code.slash {
            while index < units.count, !Code.isLineBreak(units[index]) {
                index += 1
            }
            emit(.comment(terminated: false), from: start)
            return true
        }
        guard peek(1) == Code.star else {
            return false
        }
        index += 2
        while index < units.count {
            if units[index] == Code.star, peek(1) == Code.slash {
                index += 2
                emit(.comment(terminated: true), from: start)
                return true
            }
            index += 1
        }
        emit(.comment(terminated: false), from: start)
        return true
    }

    private mutating func scanWord(from start: Int) {
        while index < units.count, Code.isIdentifierPart(units[index]) {
            index += 1
        }
        let word = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
        tokens.append(JavaScriptToken(
            kind: JavaScriptLexer.keywords.contains(word) ? .keyword : .identifier,
            range: NSRange(location: start, length: index - start),
            text: word
        ))
    }

    /// A punctuator, tracking braces; the `}` closing a substitution resumes its template's text.
    private mutating func scanPunctuator(from start: Int) {
        let unit = units[index]
        if unit == Code.closeBrace, braces.last == .template {
            braces.removeLast()
            index += 1
            emit(.punctuator, from: start, keepsText: true)
            scanTemplate(from: index)
            return
        }
        guard let length = punctuatorLength() else {
            index += 1
            emit(.unknown, from: start)
            return
        }
        if unit == Code.openBrace {
            braces.append(.code)
        } else if unit == Code.closeBrace, !braces.isEmpty {
            braces.removeLast()
        }
        index += length
        emit(.punctuator, from: start, keepsText: true)
    }

    /// Scans template text from `index` (just past a backtick or a substitution's `}`) to the next `${` or the closing
    /// backtick, emitting the text token from `start` and, at a `${`, the punctuator that opens code.
    private mutating func scanTemplate(from start: Int) {
        while index < units.count {
            let unit = units[index]
            if unit == Code.backslash {
                index = min(index + 2, units.count)
            } else if unit == Code.backtick {
                index += 1
                emit(.templateText(terminated: true), from: start)
                return
            } else if unit == Code.dollar, peek(1) == Code.openBrace {
                emit(.templateText(terminated: true), from: start)
                let open = index
                index += 2
                emit(.punctuator, from: open, keepsText: true)
                braces.append(.template)
                return
            } else {
                index += 1
            }
        }
        emit(.templateText(terminated: false), from: start)
    }

    /// A slash starts a regex unless the token before it ends an expression: a name, a value keyword, a literal, or a
    /// closing bracket.
    private func startsRegex(after previous: JavaScriptToken?) -> Bool {
        guard let previous else {
            return true
        }
        switch previous.kind {
        case .identifier, .number, .string, .templateText, .regex:
            return false
        case .keyword:
            return !JavaScriptLexer.valueKeywords.contains(previous.text)
        case .punctuator:
            return ![")", "]", "}"].contains(previous.text)
        case .comment, .unknown:
            return true
        }
    }

    /// Moves past a regex from its opening slash, through its flags; false when a line break or the end came first.
    private mutating func scanRegex() -> Bool {
        index += 1
        var inClass = false
        while index < units.count {
            let unit = units[index]
            if Code.isLineBreak(unit) {
                return false
            }
            index += 1
            if unit == Code.backslash {
                if index < units.count, !Code.isLineBreak(units[index]) {
                    index += 1
                }
            } else if unit == Code.openBracket {
                inClass = true
            } else if unit == Code.closeBracket {
                inClass = false
            } else if unit == Code.slash, !inClass {
                while index < units.count, Code.isIdentifierPart(units[index]) {
                    index += 1
                }
                return true
            }
        }
        return false
    }

    /// Moves past a string from its opening quote; false when an unescaped line break or the end came first.
    private mutating func scanString(quote: UInt16) -> Bool {
        index += 1
        while index < units.count {
            let unit = units[index]
            if Code.isLineBreak(unit) {
                return false
            }
            index += 1
            if unit == Code.backslash {
                // An escaped line break continues the string; `\r\n` counts as one.
                if index < units.count {
                    let escaped = units[index]
                    index += 1
                    if escaped == Code.carriageReturn, index < units.count, units[index] == Code.newline {
                        index += 1
                    }
                }
            } else if unit == quote {
                return true
            }
        }
        return false
    }

    /// Moves past a number: digits, a fraction, an exponent with its sign, hex or binary digits, separators, and a
    /// BigInt's `n`.
    private mutating func scanNumber() {
        while index < units.count {
            let unit = units[index]
            if Code.isIdentifierPart(unit) || unit == Code.dot {
                let isExponent = unit == Code.lowerE || unit == Code.upperE
                index += 1
                if isExponent, index < units.count, units[index] == Code.plus || units[index] == Code.minus {
                    index += 1
                }
            } else {
                return
            }
        }
    }

    private func punctuatorLength() -> Int? {
        for candidate in JavaScriptLexer.punctuators where units[index...].starts(with: candidate) {
            // `?.` before a digit is a conditional and a number (`a ?.5 : 1`), as the spec reads it.
            if candidate == Code.optionalChain, index + 2 < units.count, Code.isDigit(units[index + 2]) {
                continue
            }
            return candidate.count
        }
        return JavaScriptLexer.singlePunctuators.contains(units[index]) ? 1 : nil
    }
}

/// UTF-16 code units the lexer compares against.
private enum Code {
    static let slash = ascii("/")
    static let star = ascii("*")
    static let backslash = ascii("\\")
    static let quote = ascii("\"")
    static let apostrophe = ascii("'")
    static let backtick = ascii("`")
    static let dollar = ascii("$")
    static let openBrace = ascii("{")
    static let closeBrace = ascii("}")
    static let openBracket = ascii("[")
    static let closeBracket = ascii("]")
    static let dot = ascii(".")
    static let plus = ascii("+")
    static let minus = ascii("-")
    static let lowerE = ascii("e")
    static let upperE = ascii("E")
    static let underscore = ascii("_")
    static let newline = ascii("\n")
    static let carriageReturn = ascii("\r")
    static let optionalChain = Array("?.".utf16)

    static func ascii(_ scalar: Unicode.Scalar) -> UInt16 {
        UInt16(scalar.value)
    }

    static func isLineBreak(_ unit: UInt16) -> Bool {
        unit == newline || unit == carriageReturn || unit == 0x2028 || unit == 0x2029
    }

    static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0B || unit == 0x0C || unit == 0xA0 || unit == 0xFEFF || isLineBreak(unit)
    }

    static func isDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    static func isLetter(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
    }

    /// Any non-ASCII unit counts, so names in other scripts (and their surrogate halves) stay one identifier; the
    /// non-ASCII spaces `isWhitespace` lists are checked first.
    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        isLetter(unit) || unit == underscore || unit == dollar || (unit > 0x7F && !isWhitespace(unit))
    }

    static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }
}
