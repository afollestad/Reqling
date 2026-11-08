import Foundation
import ReqlingScriptProtocol

/// Object literals a script passes where a parameter takes an options type, as `rq.sendRequest({ method, url })` and
/// `rq.cookies.set(name, value, { secure: true })` do: completion offers the type's keys not yet written, and in a
/// string written as a key's value, the values its property names (`ScriptArgumentCompletion.choices`); hover describes
/// a key, and diagnostics warn of one the type lacks or refuses, or of a string value its property's exhaustive choices
/// lack. Only a literal passed whole as the argument counts, so one nested in it (`headers: { … }`) offers nothing of its
/// parent's. A `pm` method's options are checked but never offered, as `pm`'s members aren't.
///
/// Keys are found from the tokens alone, so they complete wherever the editor's pairs and indentation leave the
/// cursor: between `({` and `})`, on a line Return indented, or before a `}` moved back to its opener's line.
extension ScriptAnalyzer {
    /// The keys an options literal can take after the `{` or `,` at `index`, filtered by `prefix`. `typing` is the
    /// name being typed there, if any, whose own text isn't a key written already.
    func optionKeys(after index: Int, typing: Int?, prefix: String, replacement: NSRange) -> ScriptCompletionList? {
        let tokens = expressions.tokens
        guard let brace = literalOpening(at: index), let type = optionsType(ofLiteralAt: brace)?.type, Self.isOffered(type) else {
            return nil
        }
        let written = Set(writtenKeys(inLiteralAt: brace).filter { $0.index != typing }.map(\.name))
        // A name already followed by its `:` is being renamed, so accepting replaces just the name.
        let colonFollows = typing.map { $0 + 1 < tokens.count && tokens[$0 + 1].isPunctuator(":") } ?? false
        let items = type.members.filter { !$0.isMethod && $0.availability == .supported && !written.contains($0.name) }.map { member in
            ScriptCompletionItem(
                label: member.name,
                kind: .property,
                detail: member.type.description,
                summary: member.summary,
                insertText: colonFollows ? member.name : "\(member.name): ",
                takesArguments: nil
            )
        }
        return list(items, prefix: prefix, replacement: replacement)
    }

    /// The values the key before the string at `index` takes, when its property names them.
    func optionChoices(inString index: Int, cursor: Int) -> ScriptCompletionList? {
        let tokens = expressions.tokens
        guard index >= 3, tokens[index - 1].isPunctuator(":"), let key = keyName(tokens[index - 2]),
              let brace = literalOpening(at: index - 3), let type = optionsType(ofLiteralAt: brace)?.type, Self.isOffered(type),
              let member = type.members.first(where: { !$0.isMethod && $0.name == key }),
              case .choices(let values, _, _)? = member.completion else {
            return nil
        }
        let token = tokens[index]
        let start = token.range.location + 1
        let contents = expressions.stringContents(token) as NSString
        let typed = contents.substring(to: min(contents.length, max(cursor - start, 0))).lowercased()
        let items = values.filter { $0.lowercased().hasPrefix(typed) }.map { value in
            ScriptCompletionItem(label: value, kind: .value, detail: nil, summary: nil, insertText: value, takesArguments: nil)
        }
        return ScriptCompletionList(replacementRange: NSRange(location: start, length: contents.length), items: items, isVariableNames: false)
    }

    /// What the key at `index` is, when it's one of an options literal's.
    func optionKeyHover(at index: Int) -> ScriptHover? {
        let tokens = expressions.tokens
        guard index >= 1, let key = keyName(tokens[index]), let brace = literalOpening(at: index - 1),
              let type = optionsType(ofLiteralAt: brace)?.type,
              let member = type.members.first(where: { !$0.isMethod && $0.name == key }) else {
            return nil
        }
        return ScriptHover(range: tokens[index].range, signature: "\(type.name).\(member.signature)", summary: member.summary, note: nil)
    }

    /// A warning for each key an options literal's type lacks: a typo the runtime refuses when the script runs, or for
    /// a variable's `{ secrets: true }`, ignores. A key the type lists as unsupported, such as `pm.sendRequest`'s
    /// `auth`, is one the runtime refuses, named with why.
    func optionDiagnostics() -> [ScriptDiagnostic] {
        let tokens = expressions.tokens
        var found: [ScriptDiagnostic] = []
        for brace in tokens.indices where tokens[brace].isPunctuator("{") {
            guard let (type, callee) = optionsType(ofLiteralAt: brace) else {
                continue
            }
            let properties = Dictionary(type.members.filter { !$0.isMethod }.map { ($0.name, $0) }) { first, _ in first }
            for key in writtenKeys(inLiteralAt: brace) {
                guard let property = properties[key.name] else {
                    let message = "\(callee)'s options have no “\(key.name)”."
                    found.append(ScriptDiagnostic(range: tokens[key.index].range, message: message, severity: .warning))
                    continue
                }
                if case .unsupported(let reason) = property.availability {
                    let message = "\(callee)'s \(key.name) isn't supported in Reqling: \(reason)."
                    found.append(ScriptDiagnostic(range: tokens[key.index].range, message: message, severity: .warning))
                    continue
                }
                if let unknown = unknownChoice(of: property, valueAfter: key.index, in: callee) {
                    found.append(unknown)
                }
            }
        }
        return found
    }

    /// A warning for the string the key at `index` is given, when that string is its whole value and isn't among the
    /// property's exhaustive choices; a value built any other way is the runtime's to check.
    private func unknownChoice(of property: ScriptMember, valueAfter index: Int, in callee: String) -> ScriptDiagnostic? {
        let tokens = expressions.tokens
        guard index + 2 < tokens.count, tokens[index + 1].isPunctuator(":"), case .string(terminated: true) = tokens[index + 2].kind,
              index + 3 >= tokens.count || tokens[index + 3].isPunctuator(",") || tokens[index + 3].isPunctuator("}"),
              let listed = Self.refusedChoice(expressions.stringContents(tokens[index + 2]), by: property.completion) else {
            return nil
        }
        let message = "\(callee)'s \(property.name) is \(listed), not “\(expressions.stringContents(tokens[index + 2]))”."
        return ScriptDiagnostic(range: tokens[index + 2].range, message: message, severity: .warning)
    }

    /// The exhaustive choices listed for a message (`lax, strict, or none`), when `value` isn't among them; `nil` when
    /// it is, or when the choices are only suggestions.
    static func refusedChoice(_ value: String, by completion: ScriptArgumentCompletion?) -> String? {
        guard case .choices(let values, exhaustive: true, let matchesCase)? = completion else {
            return nil
        }
        let isTaken = values.contains { matchesCase ? $0 == value : $0.caseInsensitiveCompare(value) == .orderedSame }
        guard !isTaken else {
            return nil
        }
        switch values.count {
        case 0, 1: return values.joined()
        case 2: return values.joined(separator: " or ")
        default: return values.dropLast().joined(separator: ", ") + ", or " + (values.last ?? "")
        }
    }

    /// The `{` of the literal a key after `index` belongs to, when `index` is that `{` or a `,` at its own depth; `nil`
    /// inside a call's parentheses or an array instead.
    private func literalOpening(at index: Int) -> Int? {
        let tokens = expressions.tokens
        guard tokens.indices.contains(index), tokens[index].isPunctuator("{") || tokens[index].isPunctuator(",") else {
            return nil
        }
        var depth = 0
        var cursor = index
        while cursor >= 0 {
            let token = tokens[cursor]
            if Self.closes(token) {
                depth += 1
            } else if Self.opens(token) {
                if depth == 0 {
                    return token.isPunctuator("{") ? cursor : nil
                }
                depth -= 1
            }
            cursor -= 1
        }
        return nil
    }

    /// The options type the literal opening at `brace` is passed as, the named type of the parameter it's the whole
    /// argument for, and the method's name as messages give it: `rq.sendRequest`.
    private func optionsType(ofLiteralAt brace: Int) -> (type: ScriptType, callee: String)? {
        let tokens = expressions.tokens
        guard brace >= 1, tokens[brace - 1].isPunctuator("(") || tokens[brace - 1].isPunctuator(","),
              let (open, argument) = expressions.call(enclosing: brace), open >= 1,
              let callee = expressions.chain(endingAt: open - 1) else {
            return nil
        }
        let resolved = resolve(callee, bindings: expressions.bindings(before: tokens[open].range.location))
        guard case .method(let method) = resolved.value, argument < method.parameters.count,
              let name = Self.optionsName(method.parameters[argument].type), let type = catalog.type(name) else {
            return nil
        }
        return (type, resolved.steps.last.map { "\($0.receiverText).\($0.name)" } ?? callee.root)
    }

    /// The keys written at the literal's own depth, each with its token's index.
    private func writtenKeys(inLiteralAt brace: Int) -> [(name: String, index: Int)] {
        let tokens = expressions.tokens
        var keys: [(name: String, index: Int)] = []
        var depth = 0
        var expectsKey = true
        for index in (brace + 1)..<tokens.count {
            let token = tokens[index]
            if Self.opens(token) {
                depth += 1
                expectsKey = false
                continue
            }
            if Self.closes(token) {
                guard depth > 0 else {
                    break
                }
                depth -= 1
                continue
            }
            guard depth == 0 else {
                continue
            }
            if token.isPunctuator(",") {
                expectsKey = true
                continue
            }
            if expectsKey, let key = keyName(token) {
                keys.append((key, index))
            }
            expectsKey = false
        }
        return keys
    }

    /// A key as written: a name, or a string's contents.
    private func keyName(_ token: JavaScriptToken) -> String? {
        if ScriptExpressions.isMemberName(token) {
            return token.text
        }
        if case .string = token.kind {
            return expressions.stringContents(token)
        }
        return nil
    }

    /// Whether completion offers `type`'s keys: never a `pm` method's, since scripts written here use `rq`.
    private static func isOffered(_ type: ScriptType) -> Bool {
        !type.name.hasPrefix("Postman")
    }

    /// The named type a parameter takes, through an optional or among alternatives such as `string | OutgoingRequest`.
    private static func optionsName(_ type: ScriptValueType) -> String? {
        switch type {
        case .named(let name): name
        case .optional(let wrapped): optionsName(wrapped)
        case .oneOf(let types): types.lazy.compactMap(optionsName).first
        default: nil
        }
    }

    private static func opens(_ token: JavaScriptToken) -> Bool {
        token.isPunctuator("(") || token.isPunctuator("[") || token.isPunctuator("{")
    }

    private static func closes(_ token: JavaScriptToken) -> Bool {
        token.isPunctuator(")") || token.isPunctuator("]") || token.isPunctuator("}")
    }
}
