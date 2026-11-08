import Foundation

extension CodeIndent {
    public struct Insertion: Sendable, Equatable {
        /// An empty range at the end of a line's text, or a blank line's whole text.
        public let range: NSRange
        public let replacement: String
        /// What to select once inserted, in UTF-16 units from the start of `replacement`: the placeholder, or a caret
        /// after the code.
        public let selection: NSRange
    }

    /// Where whole lines of `code` go for a selection: on its line when that line is blank, at the blanks already
    /// there; otherwise on a new line after it, indented as Return at the end of that line would indent, so never in
    /// the middle of a statement and never over selected text. A selection ending at the start of a line goes after
    /// the line it ends on, as its last selected text sits there. `placeholder` must sit within one of `code`'s lines.
    public static func insertion(
        of code: String,
        placeholder: NSRange?,
        in text: String,
        selection: NSRange,
        language: SyntaxLanguage
    ) -> Insertion {
        let units = text as NSString
        var anchor = min(NSMaxRange(selection), units.length)
        if selection.length > 0, anchor > selection.location, lineBreaks.contains(units.character(at: anchor - 1)) {
            anchor -= 1
        }
        let line = units.lineRange(for: NSRange(location: anchor, length: 0))
        let end = contentEnd(of: line, in: units)
        let blanks = leadingWhitespace(in: units, from: line.location, upTo: end)
        if line.location + blanks.utf16.count == end {
            let lines = indentedLines(code, by: blanks, placeholder: placeholder)
            let range = NSRange(location: line.location, length: end - line.location)
            return Insertion(range: range, replacement: lines.text, selection: lines.selection)
        }
        let indent = blanks + (opensBlock(at: end, in: text, units: units, language: language) ? indentUnit : "")
        let lines = indentedLines(code, by: indent, placeholder: placeholder)
        let selection = NSRange(location: lines.selection.location + 1, length: lines.selection.length)
        return Insertion(range: NSRange(location: end, length: 0), replacement: "\n" + lines.text, selection: selection)
    }

    /// Whether the line's code ends with a `{` or `[`, after which Return indents one level deeper.
    private static func opensBlock(at end: Int, in text: String, units: NSString, language: SyntaxLanguage) -> Bool {
        guard let context = Context(language, text: text, units: units, cursor: end),
              !context.cursorIsInString, !context.cursorIsInComment else {
            return false
        }
        return opener(context.lastBeforeCursor, in: units, opensTemplates: language != .javascript) != nil
    }

    /// `code` with `indent` before each of its lines that has text, and where its placeholder or end lands.
    private static func indentedLines(_ code: String, by indent: String, placeholder: NSRange?) -> (text: String, selection: NSRange) {
        let indentLength = indent.utf16.count
        var text = ""
        var selection: NSRange?
        var codeOffset = 0
        for (index, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 {
                text += "\n"
                codeOffset += 1
            }
            let lineLength = line.utf16.count
            let lineStart = text.utf16.count + (line.isEmpty ? 0 : indentLength)
            if let placeholder, selection == nil, placeholder.location >= codeOffset, placeholder.location <= codeOffset + lineLength {
                selection = NSRange(location: lineStart + placeholder.location - codeOffset, length: placeholder.length)
            }
            text += line.isEmpty ? "" : indent + line
            codeOffset += lineLength
        }
        return (text, selection ?? NSRange(location: text.utf16.count, length: 0))
    }
}
