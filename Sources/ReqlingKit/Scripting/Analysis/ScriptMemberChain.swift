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
    /// One name a `const`, `let`, or `var` declares, and where.
    private struct Declaration {
        let location: Int
        let name: String
        let value: ScriptMemberChain
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

    /// Whether typing at `offset` would extend a comment, template text, or regex; a `//` comment holds its end too,
    /// since its line goes on.
    func isInsideNonCode(_ offset: Int) -> Bool {
        nonCode.contains { token in
            guard !token.holds(offset) else {
                return true
            }
            return token.end == offset && token.range.length >= 2 && text.substring(with: NSRange(location: token.range.location, length: 2)) == "//"
        }
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
    func bindings(before offset: Int) -> [String: ScriptMemberChain] {
        var bindings: [String: ScriptMemberChain] = [:]
        for declaration in declarations where declaration.location < offset {
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
        return declarations
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
