import Foundation
import ReqlingScriptProtocol

public struct ScriptDiagnostic: Hashable, Sendable {
    public enum Severity: Hashable, Sendable {
        case error
        case warning
    }

    public let range: NSRange
    public let message: String
    public let severity: Severity
}

/// A variable a script sets by a literal name, which counts as defined for `{{name}}` pills.
public struct ScriptDeclaredVariable: Hashable, Sendable {
    public let name: String
    /// Where the accessor writes: `.all` is `rq.variables`, which lasts only for the run.
    public let source: ScriptVariableSource

    public init(name: String, source: ScriptVariableSource) {
        self.name = name
        self.source = source
    }
}

/// Warnings for names the catalog knows don't work where the script runs: a member a closed type lacks, one of another
/// phase or protocol, and a Postman name Reqling refuses. Open types (assertion chains, libraries) and locals are never
/// warned about: the catalog lists only part of them.
extension ScriptAnalyzer {
    public func diagnostics() -> [ScriptDiagnostic] {
        let tokens = expressions.tokens
        var found: [ScriptDiagnostic] = []
        for (index, token) in tokens.enumerated() where token.kind == .identifier {
            guard index == 0 || !ScriptExpressions.isDot(tokens[index - 1]),
                  let (chain, _) = expressions.chain(startingAt: index), !chain.steps.isEmpty else {
                continue
            }
            // The first problem explains the rest of the chain: `rq.response.code` before a response warns once.
            let steps = resolve(chain, bindings: expressions.bindings(before: token.range.location)).steps
            if let step = steps.first(where: { $0.problem != nil }), let problem = step.problem {
                found.append(ScriptDiagnostic(range: step.range, message: message(for: problem, at: step), severity: .warning))
            }
        }
        return found
    }

    /// Every variable the script sets with a literal name through an accessor the catalog knows, `pm`'s included.
    public static func declaredVariables(in source: String) -> [ScriptDeclaredVariable] {
        let analyzer = ScriptAnalyzer(text: source, context: ScriptAnalysisContext(phase: .preRequest))
        let expressions = analyzer.expressions
        let tokens = expressions.tokens
        var found: [ScriptDeclaredVariable] = []
        for index in tokens.indices where tokens[index].text == "set" && index >= 1 && index + 2 < tokens.count {
            guard ScriptExpressions.isDot(tokens[index - 1]), tokens[index + 1].isPunctuator("("),
                  case .string(terminated: true) = tokens[index + 2].kind,
                  let chain = expressions.chain(endingAt: index),
                  case .method(let method) = analyzer.resolve(chain, bindings: expressions.bindings(before: tokens[index].range.location)).value,
                  case .variableName(let scope)? = method.parameters.first?.completion else {
                continue
            }
            let name = expressions.stringContents(tokens[index + 2])
            if !name.isEmpty {
                found.append(ScriptDeclaredVariable(name: name, source: scope))
            }
        }
        return found
    }

    private func message(for problem: ScriptStepProblem, at step: ScriptResolvedStep) -> String {
        let name = "\(step.receiverText).\(step.name)"
        switch problem {
        case .missing:
            return "\(step.receiverText) has no “\(step.name)”."
        case .phases(let phases):
            return "\(name) works only in \(phases.listed) scripts."
        case .protocols(let protocols):
            return "\(name) applies only to \(protocols.listed) requests."
        case .unsupported(let reason):
            return "\(name) isn't supported in Reqling: \(reason)."
        }
    }
}
