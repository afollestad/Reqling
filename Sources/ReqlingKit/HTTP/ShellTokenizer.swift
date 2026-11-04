/// The quoting forms cURL commands use: backslash escapes and line continuations, `'…'`, `"…"`, and `$'…'`.
struct ShellTokenizer {
    private var characters: ArraySlice<Character>
    private var current = ""
    private var inWord = false

    init(_ command: String) {
        characters = Array(command)[...]
    }

    mutating func words() throws(CurlImportError) -> [String] {
        var words: [String] = []
        while let character = characters.popFirst() {
            switch character {
            case "\\":
                readEscape()
            case "'":
                try readSingleQuoted()
            case "\"":
                try readDoubleQuoted()
            case "$" where characters.first == "'":
                characters.removeFirst()
                try readANSIQuoted()
            case _ where character.isWhitespace:
                if inWord {
                    words.append(current)
                    current = ""
                    inWord = false
                }
            default:
                current.append(character)
                inWord = true
            }
        }
        if inWord {
            words.append(current)
        }
        return words
    }

    /// A backslash before a line break continues the line. `Character` holds `\r\n` as one newline, so Windows line
    /// endings continue too.
    private mutating func readEscape() {
        guard let escaped = characters.popFirst() else {
            return
        }
        if escaped.isNewline {
            return
        }
        current.append(escaped)
        inWord = true
    }

    private mutating func readSingleQuoted() throws(CurlImportError) {
        inWord = true
        guard let end = characters.firstIndex(of: "'") else {
            throw .unterminatedQuote
        }
        current += String(characters[..<end])
        characters = characters[characters.index(after: end)...]
    }

    private mutating func readDoubleQuoted() throws(CurlImportError) {
        inWord = true
        while let character = characters.popFirst() {
            if character == "\"" {
                return
            }
            if character == "\\", let escaped = characters.first, escaped.isNewline || "\"\\$`".contains(escaped) {
                characters.removeFirst()
                if !escaped.isNewline {
                    current.append(escaped)
                }
            } else {
                current.append(character)
            }
        }
        throw .unterminatedQuote
    }

    /// Bash's ANSI-C quoting, which browsers' "Copy as cURL" uses for anything unusual: Chrome writes `!` as `!`,
    /// Firefox writes non-ASCII as `\xHH` or `\uHHHH`.
    ///
    /// `\xHH` and octal escapes are bytes: consecutive ones decode together as UTF-8 (`\xc3\xa9` is "é"), or as
    /// Latin-1 when that fails, which is what Firefox's `\xe9` for "é" means. Unknown escapes keep their backslash,
    /// as in bash.
    private mutating func readANSIQuoted() throws(CurlImportError) {
        inWord = true
        var bytes: [UInt8] = []
        while let character = characters.popFirst() {
            if character == "'" {
                flush(&bytes)
                return
            }
            guard character == "\\", let escaped = characters.popFirst() else {
                flush(&bytes)
                current.append(character)
                continue
            }
            if escaped == "x", let value = readNumber(radix: 16, maximumDigits: 2) {
                bytes.append(UInt8(value))
                continue
            }
            if let digit = escaped.asciiValue, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) {
                let rest = readNumber(radix: 8, maximumDigits: 2, prefix: Int(digit - UInt8(ascii: "0")))
                bytes.append(UInt8(truncatingIfNeeded: rest ?? Int(digit - UInt8(ascii: "0"))))
                continue
            }
            flush(&bytes)
            switch escaped {
            case "u", "U":
                if let value = readNumber(radix: 16, maximumDigits: escaped == "u" ? 4 : 8) {
                    current.unicodeScalars.append(Unicode.Scalar(UInt32(value)) ?? "\u{FFFD}")
                } else {
                    current += "\\\(escaped)"
                }
            case "c":
                if let control = characters.first?.asciiValue {
                    characters.removeFirst()
                    current.unicodeScalars.append(Unicode.Scalar(control & 0x1F))
                } else {
                    current += "\\c"
                }
            case "a": current.append("\u{07}")
            case "b": current.append("\u{08}")
            case "e", "E": current.append("\u{1B}")
            case "f": current.append("\u{0C}")
            case "n": current.append("\n")
            case "r": current.append("\r")
            case "t": current.append("\t")
            case "v": current.append("\u{0B}")
            case "\\", "'", "\"", "?": current.append(escaped)
            default: current += "\\\(escaped)"
            }
        }
        throw .unterminatedQuote
    }

    /// Reads up to `maximumDigits` ASCII digits in `radix` after `prefix`; `nil` when there are none and no prefix.
    private mutating func readNumber(radix: Int, maximumDigits: Int, prefix: Int? = nil) -> Int? {
        var value = prefix
        var count = 0
        while count < maximumDigits, let next = characters.first, next.isASCII, let digit = next.hexDigitValue, digit < radix {
            characters.removeFirst()
            value = (value ?? 0) * radix + digit
            count += 1
        }
        return value
    }

    private mutating func flush(_ bytes: inout [UInt8]) {
        guard !bytes.isEmpty else {
            return
        }
        current += String(validating: bytes, as: UTF8.self) ?? String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
        bytes.removeAll()
    }
}
