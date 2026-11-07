import Foundation

/// The function whose call's arguments hold the cursor, and which parameter the cursor's argument fills.
public struct ScriptSignatureHelp: Hashable, Sendable {
    public struct Parameter: Hashable, Sendable {
        public let name: String
        /// As the signature shows it: `options?: object` for the API, or a script's own parameter as written.
        public let label: String
        public let summary: String?
    }

    /// Such as `RequestCookies.get`, as hover names it; a global's or the script's own function's bare name, and a
    /// method called through an alias by its own.
    public let name: String
    public let parameters: [Parameter]
    /// What an API method returns; nil for the script's own function, whose result isn't known.
    public let returnType: String?
    public let summary: String?
    /// How a Postman name maps to Reqling's, or why it doesn't work.
    public let note: String?
    /// `nil` past the last parameter, unless that one is a rest parameter, which takes every argument from there on.
    public let activeParameter: Int?
    /// Where the call's `(` is, which the popup lines up with.
    public let openParen: Int
}

/// Parameter hints: what the function being called takes, and which argument the cursor is in. Any method the catalog
/// knows gets them, `pm`'s included, as hover does, and so does a function the script declares itself, with what its
/// doc comment says; a call to anything else gets none, rather than an outer call's.
extension ScriptAnalyzer {
    public func signatureHelp(at cursor: Int) -> ScriptSignatureHelp? {
        guard !expressions.isInsideComment(cursor), let (open, argument) = expressions.call(containing: cursor), open >= 1,
              let callee = expressions.chain(endingAt: open - 1) else {
            return nil
        }
        let openParen = expressions.tokens[open].range.location
        if callee.steps.isEmpty, let local = expressions.localFunction(named: callee.root, calledAt: openParen) {
            return Self.help(for: local, argument: argument, openParen: openParen)
        }
        let resolved = resolve(callee, bindings: expressions.bindings(before: openParen))
        guard case .method(let member) = resolved.value else {
            return nil
        }
        let receiver = callee.steps.isEmpty ? nil : resolved.steps.last?.receiver?.name
        return ScriptSignatureHelp(
            name: [receiver, member.name].compactMap(\.self).joined(separator: "."),
            parameters: member.parameters.map { .init(name: $0.name, label: $0.signature, summary: $0.summary) },
            returnType: member.type.description,
            summary: member.summary,
            note: Self.note(for: member),
            activeParameter: Self.active(argument, of: member.parameters.count, lastIsRest: member.parameters.last?.isRest == true),
            openParen: openParen
        )
    }

    private static func help(for function: ScriptLocalFunction, argument: Int, openParen: Int) -> ScriptSignatureHelp {
        let parameters = function.parameters
        return ScriptSignatureHelp(
            name: function.name,
            parameters: parameters.map { .init(name: $0.name, label: $0.label, summary: $0.summary) },
            returnType: nil,
            summary: function.summary ?? "Declared in this script.",
            note: nil,
            activeParameter: active(argument, of: parameters.count, lastIsRest: parameters.last?.isRest == true),
            openParen: openParen
        )
    }

    private static func active(_ argument: Int, of count: Int, lastIsRest: Bool) -> Int? {
        if argument < count {
            return argument
        }
        return lastIsRest ? count - 1 : nil
    }
}
