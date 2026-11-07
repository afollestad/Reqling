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

/// What a global or member under the pointer is, from the catalog, `pm`'s included: a script brought from Postman reads
/// best with each name's Reqling equivalent beside it.
extension ScriptAnalyzer {
    public func hover(at offset: Int) -> ScriptHover? {
        let tokens = expressions.tokens
        guard let index = tokens.firstIndex(where: { NSLocationInRange(offset, $0.range) }),
              ScriptExpressions.isMemberName(tokens[index]),
              let chain = expressions.chain(endingAt: index) else {
            return nil
        }
        let token = tokens[index]
        let bindings = expressions.bindings(before: token.range.location)
        if chain.steps.isEmpty {
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
