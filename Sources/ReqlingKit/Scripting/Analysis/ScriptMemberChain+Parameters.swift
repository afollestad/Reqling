import Foundation

/// The parameters a script's functions declare, each bound within its function's body. A function passed whole as a
/// call's argument binds its parameters to that call (`ScriptMemberChain.Step.parameter`), so the analyzer can type
/// them by what the API calls the function with; reading which call holds it stays syntax only.
extension ScriptExpressions {
    /// One function's parameter list.
    private struct ParameterList {
        /// Each name with its place in the list; `nil` for one destructured or a rest parameter.
        let names: [(token: JavaScriptToken, position: Int?)]
        let bodyStart: Int
        /// Where the function begins, when it can be a call's argument: an arrow's parameters or a `function`.
        let start: Int?
    }

    /// The parameters of arrow functions, `function`s, methods, and `catch` clauses, each scoped to its body.
    func readParameters() -> [Declaration] {
        var parameters: [Declaration] = []
        for index in tokens.indices {
            let token = tokens[index]
            let list: ParameterList?
            if token.isPunctuator("=>") {
                list = arrowParameters(before: index)
            } else if token.kind == .keyword, ["function", "catch"].contains(token.text) {
                list = parenthesizedParameters(after: index, isFunction: token.text == "function")
            } else if token.kind == .identifier, let method = methodParameters(at: index) {
                list = method
            } else {
                list = nil
            }
            guard let list, let scopeEnd = bodyEnd(from: list.bodyStart) else {
                continue
            }
            let callee = list.start.flatMap(calleeOfArgument(startingAt:))
            parameters += list.names.map { name, position in
                var value = Self.unknown(at: name.range)
                if let callee, let position {
                    value = callee.chain.appending(.parameter(argument: callee.argument, position: position))
                }
                return Declaration(location: name.range.location, name: name.text, value: value, scopeEnd: scopeEnd)
            }
        }
        return parameters
    }

    /// The method a function starting at `start` is passed to, and as which argument: `rq.onEvent(` in
    /// `rq.onEvent(event => …)`. Only a function that is a whole argument, after `(` or `,` (or `async`), counts; one
    /// grouped, in a ternary, or called at once is no call's argument.
    private func calleeOfArgument(startingAt start: Int) -> (chain: ScriptMemberChain, argument: Int)? {
        var first = start
        if first >= 1, tokens[first - 1].text == "async" {
            first -= 1
        }
        guard first >= 1, tokens[first - 1].isPunctuator("(") || tokens[first - 1].isPunctuator(","),
              let (open, argument) = call(enclosing: first), parenthesis(at: open) == .call,
              open >= 1, let chain = chain(endingAt: open - 1) else {
            return nil
        }
        return (chain, argument)
    }

    /// `x =>` or `(a, { b }, c = 1) =>`.
    private func arrowParameters(before arrow: Int) -> ParameterList? {
        guard arrow >= 1 else {
            return nil
        }
        let last = tokens[arrow - 1]
        if last.kind == .identifier {
            return ParameterList(names: [(last, 0)], bodyStart: arrow + 1, start: arrow - 1)
        }
        guard last.isPunctuator(")"), let open = opener(of: arrow - 1, open: "(", close: ")") else {
            return nil
        }
        return ParameterList(names: names(from: open + 1, to: arrow - 1), bodyStart: arrow + 1, start: open)
    }

    /// `function name(a, b) {`, `function (a) {`, or `catch (error) {`, and where the body starts.
    private func parenthesizedParameters(after keyword: Int, isFunction: Bool) -> ParameterList? {
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
        return ParameterList(names: names(from: open + 1, to: close), bodyStart: close + 1, start: isFunction ? keyword : nil)
    }

    /// `name(a, b) {`, a method in an object or class: a call is never followed by a block.
    private func methodParameters(at name: Int) -> ParameterList? {
        guard name + 1 < tokens.count, tokens[name + 1].isPunctuator("("), name == 0 || !Self.isDot(tokens[name - 1]),
              let close = closer(of: name + 1, open: "(", close: ")"),
              close + 1 < tokens.count, tokens[close + 1].isPunctuator("{") else {
            return nil
        }
        return ParameterList(names: names(from: name + 2, to: close), bodyStart: close + 1, start: nil)
    }

    /// The names a parameter list binds: each identifier but a destructured key (`{ key: name }`) and those of a
    /// default value. A name's position counts the commas before it at the list's own depth.
    private func names(from start: Int, to end: Int) -> [(token: JavaScriptToken, position: Int?)] {
        var names: [(token: JavaScriptToken, position: Int?)] = []
        var depth = 0
        var position = 0
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
                if depth == 0 {
                    position += 1
                }
            } else if token.kind == .identifier, !isInDefault, !(index + 1 < end && tokens[index + 1].isPunctuator(":")) {
                let isRest = index > start && tokens[index - 1].isPunctuator("...")
                names.append((token, depth == 0 && !isRest ? position : nil))
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
}
