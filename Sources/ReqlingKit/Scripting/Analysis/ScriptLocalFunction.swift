import Foundation

/// A function the script declares itself, for parameter hints: `function name(…)`, or a `const`, `let`, or `var` given
/// an arrow function or a function expression. Nothing is known of its types but what a `/** … */` comment right above
/// it says with `@param {type} name description`; its description is that comment's text.
struct ScriptLocalFunction: Equatable {
    struct Parameter: Equatable {
        let name: String
        /// As the signature shows it: the parameter as written, such as `b = 1` or `{ id }`, or `name: type` from the
        /// comment.
        let label: String
        let isRest: Bool
        let summary: String?
    }

    let name: String
    /// Where its name is declared. A `function` declaration is hoisted, so it is callable before this too.
    let location: Int
    let isHoisted: Bool
    let parameters: [Parameter]
    let summary: String?
}

extension ScriptExpressions {
    /// The function a call to `name` whose `(` is at `offset` reaches: the latest binding declared before it, or a
    /// `function` declaration anywhere. Scopes aren't followed, so a parameter of the same name doesn't hide it.
    func localFunction(named name: String, calledAt offset: Int) -> ScriptLocalFunction? {
        let candidates = localFunctions(named: name)
        return candidates.last { !$0.isHoisted && $0.location < offset } ?? candidates.first { $0.isHoisted }
    }

    /// The functions the script declares with `name`, in order. Only those are read in full (their parameters and doc
    /// comment), as hints ask for one on every keystroke while they show.
    private func localFunctions(named name: String) -> [ScriptLocalFunction] {
        var functions: [ScriptLocalFunction] = []
        for index in tokens.indices {
            let token = tokens[index]
            if token.kind == .keyword, token.text == "function", let declared = declaredFunction(at: index, named: name) {
                functions.append(declared)
            } else if token.kind == .keyword, ["const", "let", "var"].contains(token.text), let bound = boundFunction(at: index, named: name) {
                functions.append(bound)
            }
        }
        return functions
    }

    /// `function name(…)` or `function* name(…)`.
    private func declaredFunction(at keyword: Int, named wanted: String) -> ScriptLocalFunction? {
        var name = keyword + 1
        if name < tokens.count, tokens[name].isPunctuator("*") {
            name += 1
        }
        guard name + 1 < tokens.count, tokens[name].kind == .identifier, tokens[name].text == wanted, tokens[name + 1].isPunctuator("("),
              let close = closer(of: name + 1, open: "(", close: ")") else {
            return nil
        }
        let start = keyword >= 1 && tokens[keyword - 1].text == "async" ? keyword - 1 : keyword
        return function(named: tokens[name], isHoisted: true, parameters: (name + 2, close), documentedAt: start)
    }

    /// `const name = (…) =>`, `= x =>`, or `= function (…)`, each maybe `async`.
    private func boundFunction(at keyword: Int, named wanted: String) -> ScriptLocalFunction? {
        let name = keyword + 1
        guard name + 2 < tokens.count, tokens[name].kind == .identifier, tokens[name].text == wanted, tokens[name + 1].isPunctuator("=") else {
            return nil
        }
        var value = name + 2
        if tokens[value].kind == .keyword, tokens[value].text == "async", value + 1 < tokens.count {
            value += 1
        }
        let list: (start: Int, end: Int)?
        if tokens[value].kind == .keyword, tokens[value].text == "function" {
            var open = value + 1
            while open < tokens.count, tokens[open].isPunctuator("*") || tokens[open].kind == .identifier {
                open += 1
            }
            let close = open < tokens.count && tokens[open].isPunctuator("(") ? closer(of: open, open: "(", close: ")") : nil
            list = close.map { (open + 1, $0) }
        } else if tokens[value].isPunctuator("("), let close = closer(of: value, open: "(", close: ")"),
                  close + 1 < tokens.count, tokens[close + 1].isPunctuator("=>") {
            list = (value + 1, close)
        } else if tokens[value].kind == .identifier, value + 1 < tokens.count, tokens[value + 1].isPunctuator("=>") {
            list = (value, value + 1)
        } else {
            list = nil
        }
        guard let list else {
            return nil
        }
        return function(named: tokens[name], isHoisted: false, parameters: list, documentedAt: keyword)
    }

    private func function(
        named name: JavaScriptToken,
        isHoisted: Bool,
        parameters list: (start: Int, end: Int),
        documentedAt start: Int
    ) -> ScriptLocalFunction {
        let doc = documentation(before: tokens[start].range.location)
        let parameters = parameterSlices(from: list.start, to: list.end).map { slice in
            parameter(slice, documented: doc?.parameters)
        }
        return ScriptLocalFunction(
            name: name.text,
            location: name.range.location,
            isHoisted: isHoisted,
            parameters: parameters,
            summary: doc?.summary
        )
    }

    /// The tokens of each parameter in a list, split at its top-level commas.
    private func parameterSlices(from start: Int, to end: Int) -> [ArraySlice<JavaScriptToken>] {
        var slices: [ArraySlice<JavaScriptToken>] = []
        var depth = 0
        var sliceStart = start
        for index in start..<end {
            let token = tokens[index]
            if token.isPunctuator("(") || token.isPunctuator("[") || token.isPunctuator("{") {
                depth += 1
            } else if token.isPunctuator(")") || token.isPunctuator("]") || token.isPunctuator("}") {
                depth -= 1
            } else if token.isPunctuator(","), depth == 0 {
                slices.append(tokens[sliceStart..<index])
                sliceStart = index + 1
            }
        }
        slices.append(tokens[sliceStart..<end])
        return slices.filter { !$0.isEmpty }
    }

    private func parameter(_ slice: ArraySlice<JavaScriptToken>, documented: [String: ScriptDocComment.Parameter]?) -> ScriptLocalFunction.Parameter {
        let start = slice.first?.range.location ?? 0
        let written = text.substring(with: NSRange(location: start, length: (slice.last?.end ?? start) - start))
        let label = written.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let isRest = slice.first?.isPunctuator("...") == true
        let nameToken = isRest ? slice.dropFirst().first : slice.first
        let name = nameToken?.kind == .identifier ? nameToken?.text ?? label : label
        let doc = documented?[name]
        let isPlain = slice.count == (isRest ? 2 : 1)
        let typed = doc?.type.map { isPlain ? "\(isRest ? "..." : "")\(name): \($0)" : label } ?? label
        return ScriptLocalFunction.Parameter(name: name, label: typed, isRest: isRest, summary: doc?.summary)
    }

    /// The `/** … */` comment that ends right before `location`, with nothing but blanks between.
    private func documentation(before location: Int) -> ScriptDocComment? {
        guard let comment = nonCode.last(where: { $0.end <= location }), case .comment = comment.kind else {
            return nil
        }
        let between = text.substring(with: NSRange(location: comment.end, length: location - comment.end))
        let body = text.substring(with: comment.range)
        guard between.allSatisfy(\.isWhitespace), body.hasPrefix("/**") else {
            return nil
        }
        return ScriptDocComment(body)
    }
}

/// A JSDoc comment's description and `@param` lines: `@param {type} name description`, the type optional, and the
/// name maybe bracketed as optional (`[name]` or `[name=default]`).
struct ScriptDocComment: Equatable {
    struct Parameter: Equatable {
        let type: String?
        let summary: String?
    }

    let summary: String?
    let parameters: [String: Parameter]

    init(_ comment: String) {
        var body = comment.dropFirst(3)
        if body.hasSuffix("*/") {
            body = body.dropLast(2)
        }
        var description: [String] = []
        var parameters: [String: Parameter] = [:]
        var isInTags = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("@param") {
                isInTags = true
                if let (name, parameter) = Self.parameter(String(line.dropFirst("@param".count))) {
                    parameters[name] = parameter
                }
            } else if line.hasPrefix("@") {
                isInTags = true
            } else if !isInTags, !line.isEmpty {
                description.append(line)
            }
        }
        summary = description.isEmpty ? nil : description.joined(separator: " ")
        self.parameters = parameters
    }

    /// ` {type} name description`, or without the type.
    private static func parameter(_ line: String) -> (String, Parameter)? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        var type: String?
        if rest.hasPrefix("{"), let close = rest.firstIndex(of: "}") {
            type = rest[rest.index(after: rest.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: close)...].drop { $0.isWhitespace }
        }
        let nameEnd = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
        guard nameEnd > rest.startIndex else {
            return nil
        }
        var name = rest[..<nameEnd]
        if name.hasPrefix("["), name.hasSuffix("]") {
            name = name.dropFirst().dropLast().split(separator: "=").first ?? ""
        }
        var summary = rest[nameEnd...].trimmingCharacters(in: .whitespaces)
        if summary.hasPrefix("- ") {
            summary = String(summary.dropFirst(2))
        }
        return (String(name), Parameter(type: type?.isEmpty == true ? nil : type, summary: summary.isEmpty ? nil : summary))
    }
}
