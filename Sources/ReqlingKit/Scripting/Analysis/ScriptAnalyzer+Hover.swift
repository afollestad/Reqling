import Foundation
import ReqlingScriptProtocol

public struct ScriptHover: Hashable, Sendable {
    public let range: NSRange
    /// Such as `Request.headers: Rows`.
    public let signature: String
    public let summary: String?
    /// How a Postman name maps to Reqling's, or why it doesn't work.
    public let note: String?
}

/// What a global, member, or options literal's key under the pointer is, from the catalog, `pm`'s included: a script
/// brought from Postman reads best with each name's Reqling equivalent beside it.
extension ScriptAnalyzer {
    public func hover(at offset: Int) -> ScriptHover? {
        let tokens = expressions.tokens
        guard let index = tokens.firstIndex(where: { NSLocationInRange(offset, $0.range) }),
              ScriptExpressions.isMemberName(tokens[index]) else {
            return nil
        }
        if let key = optionKeyHover(at: index) {
            return key
        }
        guard let chain = expressions.chain(endingAt: index) else {
            return nil
        }
        let token = tokens[index]
        let bindings = expressions.bindings(before: token.range.location)
        if chain.steps.isEmpty {
            if let parameter = handlerParameter(chain.root, bindings: bindings) {
                let signature = "\(chain.root): \(parameter.type.description)"
                return ScriptHover(range: token.range, signature: signature, summary: parameter.summary, note: nil)
            }
            guard bindings[chain.root] == nil, let global = catalog.globals.first(where: { $0.name == chain.root }) else {
                return nil
            }
            return ScriptHover(range: token.range, signature: global.signature, summary: global.summary, note: Self.note(for: global))
        }
        guard case .name = chain.steps.last, let step = resolve(chain, bindings: bindings).steps.last,
              let member = step.member, let receiver = step.receiver else {
            return nil
        }
        return ScriptHover(
            range: token.range,
            signature: "\(receiver.name).\(member.signature)",
            summary: member.summary,
            note: Self.note(for: member)
        )
    }

    /// What the API calls a handler's parameter named `name` with, where it's bound to one (`rq.onEvent(event => …)`).
    private func handlerParameter(_ name: String, bindings: [String: ScriptMemberChain]) -> ScriptParameter? {
        guard let bound = bindings[name], case .parameter(let argument, let position)? = bound.steps.last else {
            return nil
        }
        let callee = ScriptMemberChain(root: bound.root, rootRange: bound.rootRange, steps: bound.steps.dropLast())
        let resolved = resolve(callee, bindings: bindings)
        return callbackParameter(of: resolved.value, receiver: resolved.steps.last?.receiver, argument: argument, position: position)
    }

    static func note(for member: ScriptMember) -> String? {
        switch member.availability {
        case .supported:
            nil
        case .compatibility(let equivalent):
            "For scripts from Postman. Reqling's own is `\(equivalent)`."
        case .unsupported(let reason):
            "Not supported in Reqling: \(reason)."
        }
    }
}
