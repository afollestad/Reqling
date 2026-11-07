import Foundation

/// The method whose call's arguments hold the cursor, and which parameter the cursor's argument fills.
public struct ScriptSignatureHelp: Hashable, Sendable {
    /// The type the method belongs to, as hover names it (`RequestCookies`); `nil` for a global such as `btoa`, or a
    /// method called through an alias.
    public let receiver: String?
    public let member: ScriptMember
    /// `nil` past the last parameter, unless that one is a rest parameter, which takes every argument from there on.
    public let activeParameter: Int?
    /// Where the call's `(` is, which the popup lines up with.
    public let openParen: Int
    /// How a Postman name maps to Reqling's, or why it doesn't work.
    public let note: String?
}

/// Parameter hints: what the method being called takes, and which argument the cursor is in. Any method the catalog
/// knows gets them, `pm`'s included, as hover does; a call to anything else gets none, rather than an outer call's.
extension ScriptAnalyzer {
    public func signatureHelp(at cursor: Int) -> ScriptSignatureHelp? {
        guard !expressions.isInsideComment(cursor), let (open, argument) = expressions.call(containing: cursor), open >= 1,
              let callee = expressions.chain(endingAt: open - 1) else {
            return nil
        }
        let openParen = expressions.tokens[open].range.location
        let resolved = resolve(callee, bindings: expressions.bindings(before: openParen))
        guard case .method(let member) = resolved.value else {
            return nil
        }
        let parameters = member.parameters
        let active: Int? = if argument < parameters.count {
            argument
        } else if parameters.last?.isRest == true {
            parameters.count - 1
        } else {
            nil
        }
        return ScriptSignatureHelp(
            receiver: callee.steps.isEmpty ? nil : resolved.steps.last?.receiver?.name,
            member: member,
            activeParameter: active,
            openParen: openParen,
            note: Self.note(for: member)
        )
    }
}
