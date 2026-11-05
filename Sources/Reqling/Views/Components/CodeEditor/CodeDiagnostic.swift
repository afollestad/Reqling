import Foundation

/// One problem a `CodeEditor` underlines, in UTF-16 offsets of the text it was found in.
struct CodeDiagnostic: Hashable, Sendable {
    enum Severity: Hashable, Sendable {
        case error
        case warning
    }

    let range: NSRange
    let message: String
    let severity: Severity
}

/// The diagnostics found in one version of an editor's text. Checking takes a moment, so a set arrives after the
/// text has moved on: the editor shows a set only when its text is still `text`, and moves the shown underlines
/// through the edits typed since (`CodeTextView+Diagnostics`).
struct CodeDiagnosticSet: Equatable, Sendable {
    static let none = CodeDiagnosticSet(text: "", items: [])

    let text: String
    let items: [CodeDiagnostic]
}
