import Foundation

/// Something wrong with a script where it runs: its syntax error, or what the analyzer warns of. The editor, MCP, and
/// the Postman importer all list a script's problems through `find`, so each reports the same ones.
public struct ScriptProblem: Hashable, Sendable {
    public let range: NSRange
    /// From 1, the line `range` starts on.
    public let line: Int
    public let message: String
    public let severity: ScriptDiagnostic.Severity

    /// The syntax error first, if any, then the analyzer's warnings in order. Call it off the main actor: the syntax
    /// check parses with JavaScriptCore.
    public static func find(in source: String, context: ScriptAnalysisContext) -> [ScriptProblem] {
        let lines = LineStarts(source as NSString)
        var problems: [ScriptProblem] = []
        if let error = ScriptSyntaxChecker.shared.error(in: source) {
            problems.append(ScriptProblem(range: error.range, line: error.line, message: error.message, severity: .error))
        }
        for diagnostic in ScriptAnalyzer(text: source, context: context).diagnostics() {
            problems.append(ScriptProblem(
                range: diagnostic.range,
                line: lines.line(at: diagnostic.range.location),
                message: diagnostic.message,
                severity: diagnostic.severity
            ))
        }
        return problems
    }
}

/// Where each line of a text starts, found once, so naming the line of each of many offsets stays cheap.
private struct LineStarts {
    private let starts: [Int]

    init(_ text: NSString) {
        var starts = [0]
        for offset in 0..<text.length where text.character(at: offset) == 0x0A {
            starts.append(offset + 1)
        }
        self.starts = starts
    }

    /// From 1, the line holding `offset`.
    func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low + 1
    }
}
