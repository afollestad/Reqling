/// The outcome of substituting a template.
public struct TemplateResolution: Hashable, Sendable {
    /// The substituted text, masked when `resolve` was asked to mask.
    public let value: String
    /// The same pass with secret values replaced by `TemplateExpansion.mask`. Dynamic values (`{{$uuid}}`) are generated
    /// once and appear in both, so what is shown matches what was sent.
    public let maskedValue: String
    /// Referenced names that were not defined (or formed a cycle), in first-use order; their tokens stay verbatim.
    public let unresolved: [String]
    public let usedSecrets: Bool
    /// Expansion passed `TemplateExpansion.maximumOutputLength` or `maximumExpansions` and stopped early; the text is
    /// incomplete and must not be sent.
    public let exceedsLimit: Bool
}

/// One variable's value as substitution sees it.
public struct TemplateVariable: Hashable, Sendable, Codable {
    public var value: String
    public var isSecret: Bool

    public init(value: String, isSecret: Bool = false) {
        self.value = value
        self.isSecret = isSecret
    }
}

/// Substitutes `{{name}}` references against any lookup. A variable's value may itself reference variables; resolution
/// recurses up to `maximumDepth`, and a reference cycle leaves the offending token verbatim and reports it as
/// unresolved. Both Reqling's `TemplateResolver` and the script runner's `replaceIn` expand through here, so a script
/// resolves text exactly as a run does.
public enum TemplateExpansion {
    public static let maximumDepth = 10
    /// Caps the text substitutions add to one template (the template's own text does not count, so a large body with
    /// few variables is fine). Depth alone does not bound it: ten levels of variables that each reference the next ten
    /// times expand to 10¹⁰ copies and would hang the app.
    public static let maximumOutputLength = 16 * 1024 * 1024
    /// Caps substitutions made inside variable values (the template's own references are bounded by its length), which
    /// bounds the work even when every leaf value is empty.
    public static let maximumExpansions = 100_000
    /// What masked resolution shows in place of a secret value.
    public static let mask = "••••••"

    /// Resolves the plain and masked text in one pass; `masked` picks which one `value` carries.
    public static func resolve(
        _ template: String,
        masked: Bool = false,
        dynamic: DynamicVariables,
        lookup: (String) -> TemplateVariable?
    ) -> TemplateResolution {
        withoutActuallyEscaping(lookup) { lookup in
            var expander = Expander(dynamic: dynamic, lookup: lookup)
            let output = expander.substitute(template, depth: 0, visiting: [])
            return TemplateResolution(
                value: masked ? output.masked : output.plain,
                maskedValue: output.masked,
                unresolved: expander.unresolved,
                usedSecrets: expander.usedSecrets,
                exceedsLimit: expander.exceedsLimit
            )
        }
    }
}

private struct Expander {
    let dynamic: DynamicVariables
    let lookup: (String) -> TemplateVariable?
    var unresolved: [String] = []
    var usedSecrets = false
    var length = 0
    var expansions = 0
    var exceedsLimit = false

    init(dynamic: DynamicVariables, lookup: @escaping (String) -> TemplateVariable?) {
        self.dynamic = dynamic
        self.lookup = lookup
    }

    struct Output {
        var plain = ""
        var masked = ""

        mutating func append(_ text: some StringProtocol) {
            plain += text
            masked += text
        }
    }

    mutating func markUnresolved(_ name: String) {
        if !unresolved.contains(name) {
            unresolved.append(name)
        }
    }

    /// Counts text a substitution adds to the plain output, at its leaves, once per occurrence. Text at `depth` 0 is the
    /// template itself and is free.
    mutating func emit(_ text: Substring, depth: Int) {
        guard depth > 0 else {
            return
        }
        length += text.utf8.count
        if length > TemplateExpansion.maximumOutputLength {
            exceedsLimit = true
        }
    }

    mutating func expand() {
        expansions += 1
        if expansions > TemplateExpansion.maximumExpansions {
            exceedsLimit = true
        }
    }

    mutating func substitute(_ template: String, depth: Int, visiting: Set<String>) -> Output {
        var output = Output()
        var cursor = template.startIndex
        for token in TemplateParser.tokens(in: template) {
            guard !exceedsLimit else {
                return output
            }
            let literal = template[cursor..<token.range.lowerBound]
            emit(literal, depth: depth)
            output.append(literal)
            cursor = token.range.upperBound
            if depth > 0 {
                expand()
            }
            let original = template[token.range]
            switch token.kind {
            case .dynamic:
                if let value = dynamic.value(for: token.name) {
                    // Generated text counts at every depth: it is what a substitution adds.
                    emit(Substring(value), depth: depth + 1)
                    output.append(value)
                } else {
                    markUnresolved(token.name)
                    emit(original, depth: depth)
                    output.append(original)
                }
            case .variable:
                guard let variable = lookup(token.name), !visiting.contains(token.name), depth < TemplateExpansion.maximumDepth else {
                    markUnresolved(token.name)
                    emit(original, depth: depth)
                    output.append(original)
                    continue
                }
                if variable.isSecret {
                    usedSecrets = true
                }
                let expanded = substitute(variable.value, depth: depth + 1, visiting: visiting.union([token.name]))
                output.plain += expanded.plain
                output.masked += variable.isSecret ? TemplateExpansion.mask : expanded.masked
            }
        }
        let rest = template[cursor...]
        emit(rest, depth: depth)
        output.append(rest)
        return output
    }
}
