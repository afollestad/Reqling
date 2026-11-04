/// Re-indents JSON text without parsing it into dictionaries, so key order, number spelling, and escapes are kept
/// exactly as the server sent them. `JSONSerialization` would reorder object keys, which is wrong for an API client.
public enum JSONFormatter {
    /// The text pretty-printed with `indent`, or `nil` when it does not start like JSON (an object or array).
    public static func pretty(_ text: String, indent: String = "  ") -> String? {
        let trimmed = text.drop { $0.isWhitespace }
        guard let first = trimmed.first, first == "{" || first == "[" else {
            return nil
        }
        var printer = Printer(indent: indent, capacity: text.utf8.count)
        for character in trimmed {
            printer.consume(character)
        }
        return printer.output
    }

    private struct Printer {
        let indent: String
        var output = ""
        private var depth = 0
        private var inString = false
        private var escaped = false
        /// Set after `{` or `[`, so an empty container can close on the same line.
        private var pendingNewline = false

        init(indent: String, capacity: Int) {
            self.indent = indent
            output.reserveCapacity(capacity + capacity / 4)
        }

        mutating func consume(_ character: Character) {
            if inString {
                consumeInString(character)
                return
            }
            if character.isWhitespace {
                return
            }
            if pendingNewline {
                pendingNewline = false
                if character == "}" || character == "]" {
                    // An empty container stays on one line: `{}` and `[]`.
                    depth -= 1
                    output.append(character)
                    return
                }
                newline()
            }
            switch character {
            case "{", "[":
                output.append(character)
                depth += 1
                pendingNewline = true
            case "}", "]":
                depth -= 1
                newline()
                output.append(character)
            case ",":
                output.append(character)
                newline()
            case ":":
                output.append(": ")
            case "\"":
                inString = true
                output.append(character)
            default:
                output.append(character)
            }
        }

        private mutating func consumeInString(_ character: Character) {
            output.append(character)
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                inString = false
            }
        }

        private mutating func newline() {
            output.append("\n")
            output.append(String(repeating: indent, count: max(depth, 0)))
        }
    }
}
