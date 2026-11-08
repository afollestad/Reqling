import Foundation

/// Arguments a script passes by position, such as `require("lodash")`: completion and warnings read the parameter the
/// catalog types for them, as options literals do for their keys (`ScriptAnalyzer+Options.swift`).
extension ScriptAnalyzer {
    /// The parameter the argument holding `tokens[index]` is passed as, and the method's name as messages give it.
    func parameter(forArgumentAt index: Int) -> (parameter: ScriptParameter, callee: String)? {
        let tokens = expressions.tokens
        guard let (open, argument) = expressions.call(enclosing: index), open >= 1, expressions.parenthesis(at: open) == .call,
              let callee = expressions.chain(endingAt: open - 1) else {
            return nil
        }
        let resolved = resolve(callee, bindings: expressions.bindings(before: tokens[open].range.location))
        guard case .method(let method) = resolved.value, argument < method.parameters.count else {
            return nil
        }
        return (method.parameters[argument], resolved.steps.last.map { "\($0.receiverText).\($0.name)" } ?? callee.root)
    }

    /// A warning for each string passed whole as an argument whose parameter's exhaustive choices lack it, such as
    /// `require("moment")`, which the runtime refuses when the script runs.
    func argumentChoiceDiagnostics() -> [ScriptDiagnostic] {
        let tokens = expressions.tokens
        var found: [ScriptDiagnostic] = []
        for index in tokens.indices {
            guard case .string(terminated: true) = tokens[index].kind, index >= 1, index + 1 < tokens.count,
                  tokens[index - 1].isPunctuator("(") || tokens[index - 1].isPunctuator(","),
                  tokens[index + 1].isPunctuator(")") || tokens[index + 1].isPunctuator(","),
                  let (parameter, callee) = parameter(forArgumentAt: index) else {
                continue
            }
            let value = expressions.stringContents(tokens[index])
            guard let listed = Self.refusedChoice(value, by: parameter.completion) else {
                continue
            }
            let message = "\(callee)'s \(parameter.name) is \(listed), not “\(value)”."
            found.append(ScriptDiagnostic(range: tokens[index].range, message: message, severity: .warning))
        }
        return found
    }
}
