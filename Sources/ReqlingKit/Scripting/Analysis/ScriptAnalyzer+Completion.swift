import Foundation
import ReqlingScriptProtocol

/// What a completion names, for its badge.
public enum ScriptSymbolKind: Hashable, Sendable {
    case namespace
    case property
    case method
    /// A name the script declared itself.
    case local
    /// A Reqling variable, inside a string argument such as `rq.environment.get("…")`.
    case variable
    case jsonKey
    case keyword
}

public struct ScriptCompletionItem: Hashable, Sendable {
    public let label: String
    public let kind: ScriptSymbolKind
    public let detail: String?
    public let summary: String?
    public let insertText: String
}

public struct ScriptCompletionList: Hashable, Sendable {
    /// What accepting an item replaces.
    public let replacementRange: NSRange
    public let items: [ScriptCompletionItem]
    /// The list completes a variable name in a string, whose characters (`-`, `.`) a code name never has.
    public let isVariableNames: Bool
}

/// Completion at the cursor: a receiver's members after a dot, the names a script starts from while typing one, and
/// variable names inside the string argument of an accessor such as `rq.environment.get("…")`. Members are those that
/// work in the script's phase and protocols; nothing is offered inside comments, other strings, or `pm` chains.
extension ScriptAnalyzer {
    /// The keywords a name may start, each with what the popup says about it.
    static let completionKeywords: KeyValuePairs<String, String> = [
        "await": "Waits for a promise and gives its value.",
        "async": "Marks a function that can use `await`.",
        "const": "Declares a name that can't be reassigned.",
        "let": "Declares a name that can be reassigned.",
        "if": "Runs a block when a condition holds.",
        "else": "Runs a block when the `if` condition doesn't hold.",
        "return": "Ends the script or function, giving back a value.",
        "for": "Loops: over a counter, over values with `of`, or over keys with `in`.",
        "of": "In `for (… of …)`, loops over an array's values.",
        "in": "In `for (… in …)`, loops over an object's keys; elsewhere, tests for a key.",
        "try": "Runs a block, handing any error it throws to `catch`.",
        "catch": "Handles an error thrown in the `try` block.",
        "finally": "Runs after `try` and `catch`, whatever happened.",
        "throw": "Raises an error, which fails the script unless something catches it.",
        "new": "Creates an object from a constructor, such as `new Date()`.",
        "function": "Declares a function.",
        "true": "The boolean true.",
        "false": "The boolean false.",
        "null": "No value, on purpose.",
        "undefined": "A value never set.",
        "typeof": "Gives a value's type as text, such as `\"string\"`."
    ]

    public func completions(at cursor: Int) -> ScriptCompletionList? {
        let tokens = expressions.tokens
        guard !expressions.isInsideNonCode(cursor) else {
            return nil
        }
        guard let index = expressions.tokenIndex(before: cursor) else {
            return names(prefix: "", replacement: NSRange(location: cursor, length: 0))
        }
        let token = tokens[index]
        if case .string = token.kind, token.holds(cursor) {
            return variableNames(inString: index, cursor: cursor)
        }
        if ScriptExpressions.isMemberName(token), token.end == cursor {
            let prefix = token.text
            if index >= 1, ScriptExpressions.isDot(tokens[index - 1]) {
                return index >= 2 ? members(receiverEnd: index - 2, prefix: prefix, replacement: token.range) : nil
            }
            return names(prefix: prefix, replacement: token.range)
        }
        if ScriptExpressions.isDot(token), token.end == cursor {
            return index >= 1 ? members(receiverEnd: index - 1, prefix: "", replacement: NSRange(location: cursor, length: 0)) : nil
        }
        // After a space or line break, whatever came before, a name may start; right after a value, such as a string
        // whose closing quote was just typed, none does.
        if token.end < cursor || (token.end == cursor && !Self.endsValue(token)) {
            return names(prefix: "", replacement: NSRange(location: cursor, length: 0))
        }
        return nil
    }

    private func members(receiverEnd: Int, prefix: String, replacement: NSRange) -> ScriptCompletionList? {
        guard let chain = expressions.chain(endingAt: receiverEnd) else {
            return nil
        }
        let value = resolve(chain, bindings: expressions.bindings(before: replacement.location)).value
        let items: [ScriptCompletionItem]
        switch value {
        case .typed(.responseJSON):
            items = jsonKeys(at: [])
        case .json(let path):
            items = jsonKeys(at: path)
        case .typed(let type):
            items = type.namedType.flatMap(catalog.type).map(memberItems) ?? []
        case .method(let method):
            items = method.functionType.flatMap(catalog.type).map(memberItems) ?? []
        case .unknown:
            items = []
        }
        return list(items, prefix: prefix, replacement: replacement)
    }

    /// The members that work where the script runs, once each; `pm`'s are never offered.
    private func memberItems(of type: ScriptType) -> [ScriptCompletionItem] {
        guard !type.name.hasPrefix("Postman") else {
            return []
        }
        var seen: Set<String> = []
        return type.members.compactMap { member in
            guard member.availability == .supported, member.applies(to: context.phase, protocols: context.protocols),
                  seen.insert(member.name).inserted else {
                return nil
            }
            return item(for: member)
        }
    }

    private func item(for member: ScriptMember) -> ScriptCompletionItem {
        let detail: String
        let kind: ScriptSymbolKind
        if member.isMethod {
            detail = "(\(member.parameters.map(\.name).joined(separator: ", "))) → \(member.type.description)"
            kind = .method
        } else {
            detail = member.type.description
            kind = member.type.namedType == nil ? .property : .namespace
        }
        return ScriptCompletionItem(label: member.name, kind: kind, detail: detail, summary: member.summary, insertText: member.name)
    }

    private func jsonKeys(at path: [String?]) -> [ScriptCompletionItem] {
        (context.responseShape?.keys(at: path) ?? []).map { key in
            ScriptCompletionItem(
                label: key.name,
                kind: .jsonKey,
                detail: Self.describe(key.kind),
                summary: "`\(Self.jsonPath(path, key: key.name))` in the latest response's JSON.",
                insertText: key.name
            )
        }
    }

    /// What a name may start: the script's own declarations, the globals that work here (not `pm`), and keywords.
    private func names(prefix: String, replacement: NSRange) -> ScriptCompletionList? {
        let locals = expressions.bindings(before: replacement.location).keys.sorted().map { name in
            ScriptCompletionItem(label: name, kind: .local, detail: nil, summary: "Declared in this script.", insertText: name)
        }
        let globals = catalog.globals.compactMap { member -> ScriptCompletionItem? in
            guard member.availability == .supported, member.applies(to: context.phase, protocols: context.protocols) else {
                return nil
            }
            return item(for: member)
        }
        let keywords = Self.completionKeywords.map { keyword, summary in
            ScriptCompletionItem(label: keyword, kind: .keyword, detail: nil, summary: summary, insertText: keyword)
        }
        return list(locals + globals + keywords, prefix: prefix, replacement: replacement)
    }

    /// A key's path from the response's root as a script reaches it, such as `data.users[].name`: `[]` for an array's
    /// items, and `["…"]` for a key that isn't a plain name.
    static func jsonPath(_ path: [String?], key: String) -> String {
        var text = ""
        for step in path + [key] {
            guard let step else {
                text += "[]"
                continue
            }
            if isPlainName(step) {
                text += text.isEmpty ? step : ".\(step)"
            } else {
                let escaped = step.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                text += "[\"\(escaped)\"]"
            }
        }
        return text
    }

    private static func isPlainName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" || first == "$" else {
            return false
        }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
    }

    /// The names the accessor whose string argument holds the cursor reads, when the catalog says what it reads.
    private func variableNames(inString index: Int, cursor: Int) -> ScriptCompletionList? {
        let tokens = expressions.tokens
        guard let (open, argument) = expressions.call(enclosing: index), open >= 1,
              let callee = expressions.chain(endingAt: open - 1),
              case .method(let method) = resolve(callee, bindings: expressions.bindings(before: tokens[open].range.location)).value,
              argument < method.parameters.count,
              case .variableName(let source)? = method.parameters[argument].completion else {
            return nil
        }
        let token = tokens[index]
        let start = token.range.location + 1
        let contents = expressions.stringContents(token) as NSString
        let typed = contents.substring(to: min(contents.length, cursor - start))
        let names = variables(from: source).map { name in
            ScriptCompletionItem(label: name, kind: .variable, detail: nil, summary: nil, insertText: name)
        }
        let items = names.filter { $0.label.lowercased().hasPrefix(typed.lowercased()) }
        return ScriptCompletionList(replacementRange: NSRange(location: start, length: contents.length), items: items, isVariableNames: true)
    }

    private func variables(from source: ScriptVariableSource) -> [String] {
        guard source == .all else {
            return context.variables[source] ?? []
        }
        var seen: Set<String> = []
        return context.variables.values.flatMap { $0 }.filter { seen.insert($0).inserted }.sorted()
    }

    private func list(_ items: [ScriptCompletionItem], prefix: String, replacement: NSRange) -> ScriptCompletionList {
        let lowered = prefix.lowercased()
        let matching = lowered.isEmpty ? items : items.filter { $0.label.lowercased().hasPrefix(lowered) }
        return ScriptCompletionList(replacementRange: replacement, items: matching, isVariableNames: false)
    }

    private static func endsValue(_ token: JavaScriptToken) -> Bool {
        switch token.kind {
        case .number, .string, .templateText, .regex: true
        default: token.isPunctuator(")") || token.isPunctuator("]")
        }
    }

    private static func describe(_ kind: JSONValueKind) -> String {
        switch kind {
        case .object: "object"
        case .array: "array"
        case .string: "string"
        case .number: "number"
        case .bool: "boolean"
        case .null: "null"
        }
    }
}
