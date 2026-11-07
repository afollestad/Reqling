import Foundation

/// A member chain as a script spells it, such as `rq.response.json().data`: a root name, then names, calls, and indexes.
struct ScriptMemberChain: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case name(String, NSRange)
        case call
        /// `[…]`, with its key when that is one string or number literal.
        case index(String?)
    }

    var root: String
    var rootRange: NSRange
    var steps: [Step]

    func appending(_ step: Step) -> ScriptMemberChain {
        ScriptMemberChain(root: root, rootRange: rootRange, steps: steps + [step])
    }
}

/// Reads chains and bindings out of a script's code tokens (comments left out), backwards from where the cursor is or
/// forwards from a name. Nothing here evaluates: a chain is only what its tokens spell.
struct ScriptExpressions {
    /// One name a `const`, `let`, or `var` declares, or a function's parameter, and where it holds.
    private struct Declaration {
        let location: Int
        let name: String
        let value: ScriptMemberChain
        /// Where a parameter's function ends, outside which the name means what it did before; `nil` for the rest.
        var scopeEnd: Int?
    }

    let tokens: [JavaScriptToken]
    let text: NSString
    /// Comments, template text, and regexes: where nothing is completed.
    private let nonCode: [JavaScriptToken]
    /// Read once, so looking bindings up for each name a script uses stays linear.
    private var declarations: [Declaration] = []

    init(text: String) {
        self.text = text as NSString
        var tokens: [JavaScriptToken] = []
        var nonCode: [JavaScriptToken] = []
        for token in JavaScriptLexer.tokens(in: text) {
            switch token.kind {
            case .comment, .templateText, .regex:
                nonCode.append(token)
                if case .comment = token.kind {
                    continue
                }
            default:
                break
            }
            tokens.append(token)
        }
        self.tokens = tokens
        self.nonCode = nonCode
        declarations = readDeclarations()
    }

    /// Whether typing at `offset` would extend a comment, template text, or regex.
    func isInsideNonCode(_ offset: Int) -> Bool {
        nonCode.contains { $0.holds(offset) }
    }

    /// The `(` of the call whose arguments hold `tokens[index]`, and which argument it is.
    func call(enclosing index: Int) -> (open: Int, argument: Int)? {
        var depth = 0
        var argument = 0
        var cursor = index - 1
        while cursor >= 0 {
            let token = tokens[cursor]
            if token.isPunctuator(")") || token.isPunctuator("]") || token.isPunctuator("}") {
                depth += 1
            } else if token.isPunctuator("(") || token.isPunctuator("[") || token.isPunctuator("{") {
                if depth == 0 {
                    return token.isPunctuator("(") ? (cursor, argument) : nil
                }
                depth -= 1
            } else if token.isPunctuator(","), depth == 0 {
                argument += 1
            }
            cursor -= 1
        }
        return nil
    }

    /// Whether `offset` is inside a comment, where parameter hints never show; unlike `isInsideNonCode`, a regex or
    /// template text can be an argument.
    func isInsideComment(_ offset: Int) -> Bool {
        nonCode.contains { token in
            if case .comment = token.kind {
                return token.holds(offset)
            }
            return false
        }
    }

    /// The `(` of the innermost call whose arguments hold `offset`, and which of its arguments that is, for parameter
    /// hints. Unlike `call(enclosing:)`, it reads through what an argument may be built from: an array, an object
    /// literal (a `{` after `(`, `,`, `[`, or `:`), a template's `${`, and a grouping `(`, such as an arrow
    /// function's parameters. A block's `{` or a control statement's `(` ends the search, so a callback's body never
    /// shows hints for the call it is passed to.
    func call(containing offset: Int) -> (open: Int, argument: Int)? {
        guard var index = tokenIndex(before: offset) else {
            return nil
        }
        var depth = 0
        var argument = 0
        while index >= 0 {
            let token = tokens[index]
            if token.isPunctuator(")") || token.isPunctuator("]") || token.isPunctuator("}") {
                depth += 1
            } else if token.isPunctuator("(") || token.isPunctuator("[") || token.isPunctuator("{") || token.isPunctuator("${") {
                if depth > 0 {
                    depth -= 1
                } else if token.isPunctuator("(") {
                    switch parenthesis(at: index) {
                    case .call: return (index, argument)
                    case .grouping: argument = 0
                    case .control: return nil
                    }
                } else if token.isPunctuator("{"), !isObjectLiteral(at: index) {
                    return nil
                } else {
                    argument = 0
                }
            } else if token.isPunctuator(","), depth == 0 {
                argument += 1
            }
            index -= 1
        }
        return nil
    }

    private enum Parenthesis {
        case call
        case grouping
        /// `if (`, a `function`'s parameters, and the like: no call holds what is inside.
        case control
    }

    private static let controlKeywords: Set<String> = ["if", "for", "while", "switch", "catch", "with", "function"]

    /// What the `(` at `index` opens, by the token before it: a call follows a name, `)`, or `]`.
    private func parenthesis(at index: Int) -> Parenthesis {
        guard index >= 1 else {
            return .grouping
        }
        let previous = tokens[index - 1]
        if previous.kind == .identifier || previous.isPunctuator(")") || previous.isPunctuator("]")
            || (Self.isMemberName(previous) && index >= 2 && Self.isDot(tokens[index - 2])) {
            return .call
        }
        if previous.kind == .keyword, Self.controlKeywords.contains(previous.text) {
            return .control
        }
        return .grouping
    }

    /// Whether the `{` at `index` starts an object literal rather than a block.
    private func isObjectLiteral(at index: Int) -> Bool {
        guard index >= 1 else {
            return false
        }
        let previous = tokens[index - 1]
        return ["(", ",", "[", ":"].contains { previous.isPunctuator($0) }
    }

    /// The chain whose last token is `tokens[last]`, read backwards; `nil` when it isn't one.
    func chain(endingAt last: Int) -> ScriptMemberChain? {
        var steps: [ScriptMemberChain.Step] = []
        var index = last
        while index >= 0 {
            let token = tokens[index]
            if token.isPunctuator(")") {
                guard let open = opener(of: index, open: "(", close: ")") else {
                    return nil
                }
                steps.append(.call)
                index = open - 1
                continue
            }
            if token.isPunctuator("]") {
                guard let open = opener(of: index, open: "[", close: "]") else {
                    return nil
                }
                steps.append(.index(literal(from: open + 1, to: index)))
                index = open - 1
                continue
            }
            if index >= 1, Self.isDot(tokens[index - 1]), Self.isMemberName(token) {
                steps.append(.name(token.text, token.range))
                index -= 2
                continue
            }
            guard token.kind == .identifier else {
                return nil
            }
            return ScriptMemberChain(root: token.text, rootRange: token.range, steps: steps.reversed())
        }
        return nil
    }

    /// The chain whose root is `tokens[start]`, read forwards, and the index of its last token.
    func chain(startingAt start: Int) -> (chain: ScriptMemberChain, end: Int)? {
        guard start < tokens.count, tokens[start].kind == .identifier else {
            return nil
        }
        var chain = ScriptMemberChain(root: tokens[start].text, rootRange: tokens[start].range, steps: [])
        var end = start
        var index = start + 1
        while index < tokens.count {
            let token = tokens[index]
            if Self.isDot(token), index + 1 < tokens.count, Self.isMemberName(tokens[index + 1]) {
                chain.steps.append(.name(tokens[index + 1].text, tokens[index + 1].range))
                end = index + 1
            } else if token.isPunctuator("("), let close = closer(of: index, open: "(", close: ")") {
                chain.steps.append(.call)
                end = close
            } else if token.isPunctuator("["), let close = closer(of: index, open: "[", close: "]") {
                chain.steps.append(.index(literal(from: index + 1, to: close)))
                end = close
            } else {
                break
            }
            index = end + 1
        }
        return (chain, end)
    }

    /// The names `const`, `let`, and `var` declare before `offset`, each with the chain it was given: `const r =
    /// rq.request` binds `r`, and `const { headers, query: q } = rq.request` binds `headers` and `q`. A name given
    /// anything but a chain binds to `unknown`, which still hides a global of its name. A later declaration wins.
    ///
    /// A function's parameters bind to `unknown` within the function only, so `(rq) => rq.x` or `_ => _.id` hides the
    /// global there and nowhere else.
    func bindings(before offset: Int) -> [String: ScriptMemberChain] {
        var bindings: [String: ScriptMemberChain] = [:]
        for declaration in declarations where declaration.location < offset && offset <= declaration.scopeEnd ?? .max {
            bindings[declaration.name] = declaration.value
        }
        return bindings
    }

    private func readDeclarations() -> [Declaration] {
        var declarations: [Declaration] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            guard token.kind == .keyword, ["const", "let", "var"].contains(token.text), index < tokens.count else {
                continue
            }
            let isAssigned = { (index: Int) in index < self.tokens.count && self.tokens[index].isPunctuator("=") }
            var bound: [String: ScriptMemberChain] = [:]
            if tokens[index].kind == .identifier {
                let value = isAssigned(index + 1) ? chain(startingAt: skippingAwait(index + 2))?.chain : nil
                bound[tokens[index].text] = value ?? Self.unknown(at: tokens[index].range)
            } else if tokens[index].isPunctuator("{"), let close = closer(of: index, open: "{", close: "}") {
                let value = isAssigned(close + 1) ? chain(startingAt: skippingAwait(close + 2))?.chain : nil
                destructure(from: index + 1, to: close, of: value ?? Self.unknown(at: tokens[index].range), into: &bound)
            }
            declarations += bound.map { Declaration(location: token.range.location, name: $0.key, value: $0.value) }
        }
        return declarations + readParameters()
    }

    /// The parameters of arrow functions, `function`s, methods, and `catch` clauses, each scoped to its body.
    private func readParameters() -> [Declaration] {
        var parameters: [Declaration] = []
        for index in tokens.indices {
            let token = tokens[index]
            let list: (names: [JavaScriptToken], bodyStart: Int)?
            if token.isPunctuator("=>") {
                list = arrowParameters(before: index).map { ($0, index + 1) }
            } else if token.kind == .keyword, ["function", "catch"].contains(token.text) {
                list = parenthesizedParameters(after: index)
            } else if token.kind == .identifier, let method = methodParameters(at: index) {
                list = method
            } else {
                list = nil
            }
            guard let list, let scopeEnd = bodyEnd(from: list.bodyStart) else {
                continue
            }
            parameters += list.names.map { name in
                Declaration(location: name.range.location, name: name.text, value: Self.unknown(at: name.range), scopeEnd: scopeEnd)
            }
        }
        return parameters
    }

    /// `x =>` or `(a, { b }, c = 1) =>`.
    private func arrowParameters(before arrow: Int) -> [JavaScriptToken]? {
        guard arrow >= 1 else {
            return nil
        }
        let last = tokens[arrow - 1]
        if last.kind == .identifier {
            return [last]
        }
        guard last.isPunctuator(")"), let open = opener(of: arrow - 1, open: "(", close: ")") else {
            return nil
        }
        return names(from: open + 1, to: arrow - 1)
    }

    /// `function name(a, b) {`, `function (a) {`, or `catch (error) {`, and where the body starts.
    private func parenthesizedParameters(after keyword: Int) -> (names: [JavaScriptToken], bodyStart: Int)? {
        var open = keyword + 1
        while open < tokens.count, !tokens[open].isPunctuator("(") {
            guard tokens[open].kind == .identifier || tokens[open].isPunctuator("*") else {
                return nil
            }
            open += 1
        }
        guard open < tokens.count, let close = closer(of: open, open: "(", close: ")") else {
            return nil
        }
        return (names(from: open + 1, to: close), close + 1)
    }

    /// `name(a, b) {`, a method in an object or class: a call is never followed by a block.
    private func methodParameters(at name: Int) -> (names: [JavaScriptToken], bodyStart: Int)? {
        guard name + 1 < tokens.count, tokens[name + 1].isPunctuator("("), name == 0 || !Self.isDot(tokens[name - 1]),
              let close = closer(of: name + 1, open: "(", close: ")"),
              close + 1 < tokens.count, tokens[close + 1].isPunctuator("{") else {
            return nil
        }
        return (names(from: name + 2, to: close), close + 1)
    }

    /// The names a parameter list binds: each identifier but a destructured key (`{ key: name }`) and those of a
    /// default value.
    private func names(from start: Int, to end: Int) -> [JavaScriptToken] {
        var names: [JavaScriptToken] = []
        var depth = 0
        var isInDefault = false
        for index in start..<end {
            let token = tokens[index]
            if token.isPunctuator("(") || token.isPunctuator("[") || token.isPunctuator("{") {
                depth += 1
            } else if token.isPunctuator(")") || token.isPunctuator("]") || token.isPunctuator("}") {
                depth -= 1
            } else if token.isPunctuator("=") {
                isInDefault = true
            } else if token.isPunctuator(","), depth <= 1 {
                isInDefault = false
            } else if token.kind == .identifier, !isInDefault, !(index + 1 < end && tokens[index + 1].isPunctuator(":")) {
                names.append(token)
            }
        }
        return names
    }

    /// Where a body starting at `start` ends: a `{ … }` block's closing brace, or an arrow's expression up to the
    /// first `,`, `;`, or closing bracket outside it.
    private func bodyEnd(from start: Int) -> Int? {
        guard start < tokens.count else {
            return nil
        }
        if tokens[start].isPunctuator("{") {
            return closer(of: start, open: "{", close: "}").map { tokens[$0].end }
        }
        var depth = 0
        var last = start
        for index in start..<tokens.count {
            let token = tokens[index]
            if token.isPunctuator("(") || token.isPunctuator("[") || token.isPunctuator("{") {
                depth += 1
            } else if token.isPunctuator(")") || token.isPunctuator("]") || token.isPunctuator("}") {
                guard depth > 0 else {
                    break
                }
                depth -= 1
            } else if depth == 0, token.isPunctuator(",") || token.isPunctuator(";") {
                break
            }
            last = index
        }
        return tokens[last].end
    }

    /// A chain no global or binding starts, which resolves to `unknown`.
    static func unknown(at range: NSRange) -> ScriptMemberChain {
        ScriptMemberChain(root: "", rootRange: range, steps: [])
    }

    /// The index of the token holding `offset`, or the last one ending at or before it.
    func tokenIndex(before offset: Int) -> Int? {
        tokens.lastIndex { $0.range.location < offset }
    }

    /// A string token's contents, without its quotes.
    func stringContents(_ token: JavaScriptToken) -> String {
        let inner = NSRange(location: token.range.location + 1, length: max(0, token.range.length - (isTerminated(token) ? 2 : 1)))
        return text.substring(with: inner)
    }

    static func isDot(_ token: JavaScriptToken) -> Bool {
        token.isPunctuator(".") || token.isPunctuator("?.")
    }

    /// After a dot, a keyword names a member too: `expect(x).to.be.true`.
    static func isMemberName(_ token: JavaScriptToken) -> Bool {
        token.kind == .identifier || token.kind == .keyword
    }

    private func isTerminated(_ token: JavaScriptToken) -> Bool {
        token.kind == .string(terminated: true)
    }

    private func skippingAwait(_ index: Int) -> Int {
        index < tokens.count && tokens[index].kind == .keyword && tokens[index].text == "await" ? index + 1 : index
    }

    private func destructure(from start: Int, to close: Int, of value: ScriptMemberChain, into bindings: inout [String: ScriptMemberChain]) {
        var index = start
        while index < close {
            let token = tokens[index]
            guard token.kind == .identifier else {
                index += 1
                continue
            }
            if index + 2 < close, tokens[index + 1].isPunctuator(":"), tokens[index + 2].kind == .identifier {
                bindings[tokens[index + 2].text] = value.appending(.name(token.text, token.range))
                index += 3
            } else {
                bindings[token.text] = value.appending(.name(token.text, token.range))
                index += 1
            }
        }
    }

    /// One string or number literal between two indexes, as an index key.
    private func literal(from start: Int, to end: Int) -> String? {
        guard end == start + 1 else {
            return nil
        }
        let token = tokens[start]
        switch token.kind {
        case .string:
            return stringContents(token)
        case .number:
            return token.text
        default:
            return nil
        }
    }

    private func opener(of index: Int, open: String, close: String) -> Int? {
        var depth = 0
        var cursor = index
        while cursor >= 0 {
            if tokens[cursor].isPunctuator(close) {
                depth += 1
            } else if tokens[cursor].isPunctuator(open) {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
            cursor -= 1
        }
        return nil
    }

    func closer(of index: Int, open: String, close: String) -> Int? {
        var depth = 0
        var cursor = index
        while cursor < tokens.count {
            if tokens[cursor].isPunctuator(open) {
                depth += 1
            } else if tokens[cursor].isPunctuator(close) {
                depth -= 1
                if depth == 0 {
                    return cursor
                }
            }
            cursor += 1
        }
        return nil
    }
}
