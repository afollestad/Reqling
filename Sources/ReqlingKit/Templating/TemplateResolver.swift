/// The outcome of substituting a template.
public struct TemplateResolution: Hashable, Sendable {
    /// The substituted text, masked when `resolve` was asked to mask.
    public let value: String
    /// The same pass with secret values replaced by `TemplateResolver.mask`. Dynamic values (`{{$uuid}}`) are generated
    /// once and appear in both, so what is shown matches what was sent.
    public let maskedValue: String
    /// Referenced names that were not defined (or formed a cycle), in first-use order; their tokens stay verbatim.
    public let unresolved: [String]
    public let usedSecrets: Bool
    /// Expansion passed `TemplateResolver.maximumOutputLength` or `maximumExpansions` and stopped early; the text is
    /// incomplete and must not be sent.
    public let exceedsLimit: Bool
}

/// Substitutes `{{name}}` references. A variable's value may itself reference variables; resolution recurses up to
/// `maximumDepth`, and a reference cycle leaves the offending token verbatim and reports it as unresolved.
public struct TemplateResolver: Sendable {
    public static let maximumDepth = 10
    /// Caps the text substitutions add to one template (the template's own text does not count, so a large body with
    /// few variables is fine). Depth alone does not bound it: ten levels of variables that each reference the next ten
    /// times expand to 10¹⁰ copies and would hang the app.
    public static let maximumOutputLength = 16 * 1024 * 1024
    /// Caps substitutions made inside variable values (the template's own references are bounded by its length), which
    /// bounds the work even when every leaf value is empty.
    public static let maximumExpansions = 100_000
    /// What `masked` resolution shows in place of a secret value.
    public static let mask = "••••••"

    public let scope: VariableScope
    public let dynamic: DynamicVariables

    public init(scope: VariableScope, dynamic: DynamicVariables = .live) {
        self.scope = scope
        self.dynamic = dynamic
    }

    /// Resolves the plain and masked text in one pass; `masked` picks which one `value` carries.
    public func resolve(_ template: String, masked: Bool = false) -> TemplateResolution {
        var state = State()
        let output = substitute(template, depth: 0, visiting: [], state: &state)
        return TemplateResolution(
            value: masked ? output.masked : output.plain,
            maskedValue: output.masked,
            unresolved: state.unresolved,
            usedSecrets: state.usedSecrets,
            exceedsLimit: state.exceedsLimit
        )
    }

    private struct State {
        var unresolved: [String] = []
        var usedSecrets = false
        var length = 0
        var expansions = 0
        var exceedsLimit = false

        mutating func markUnresolved(_ name: String) {
            if !unresolved.contains(name) {
                unresolved.append(name)
            }
        }

        /// Counts text a substitution adds to the plain output, at its leaves, once per occurrence. Text at `depth` 0
        /// is the template itself and is free.
        mutating func emit(_ text: Substring, depth: Int) {
            guard depth > 0 else {
                return
            }
            length += text.utf8.count
            if length > TemplateResolver.maximumOutputLength {
                exceedsLimit = true
            }
        }

        mutating func expand() {
            expansions += 1
            if expansions > TemplateResolver.maximumExpansions {
                exceedsLimit = true
            }
        }
    }

    private struct Output {
        var plain = ""
        var masked = ""

        mutating func append(_ text: some StringProtocol) {
            plain += text
            masked += text
        }
    }

    private func substitute(_ template: String, depth: Int, visiting: Set<String>, state: inout State) -> Output {
        var output = Output()
        var cursor = template.startIndex
        for token in TemplateParser.tokens(in: template) {
            guard !state.exceedsLimit else {
                return output
            }
            let literal = template[cursor..<token.range.lowerBound]
            state.emit(literal, depth: depth)
            output.append(literal)
            cursor = token.range.upperBound
            if depth > 0 {
                state.expand()
            }
            let original = template[token.range]
            switch token.kind {
            case .dynamic:
                if let value = dynamic.value(for: token.name) {
                    // Generated text counts at every depth: it is what a substitution adds.
                    state.emit(Substring(value), depth: depth + 1)
                    output.append(value)
                } else {
                    state.markUnresolved(token.name)
                    state.emit(original, depth: depth)
                    output.append(original)
                }
            case .variable:
                guard let entry = scope.lookup(token.name), !visiting.contains(token.name), depth < Self.maximumDepth else {
                    state.markUnresolved(token.name)
                    state.emit(original, depth: depth)
                    output.append(original)
                    continue
                }
                if entry.isSecret {
                    state.usedSecrets = true
                }
                let expanded = substitute(entry.value, depth: depth + 1, visiting: visiting.union([token.name]), state: &state)
                output.plain += expanded.plain
                output.masked += entry.isSecret ? Self.mask : expanded.masked
            }
        }
        let rest = template[cursor...]
        state.emit(rest, depth: depth)
        output.append(rest)
        return output
    }
}
