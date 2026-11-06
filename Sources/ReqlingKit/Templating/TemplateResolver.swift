import ReqlingTemplating

/// Substitutes `{{name}}` references against a run's `VariableScope`, through the one expander scripts share
/// (`TemplateExpansion`).
public struct TemplateResolver: Sendable {
    /// What `masked` resolution shows in place of a secret value.
    public static let mask = TemplateExpansion.mask

    public let scope: VariableScope
    public let dynamic: DynamicVariables

    public init(scope: VariableScope, dynamic: DynamicVariables = .live) {
        self.scope = scope
        self.dynamic = dynamic
    }

    /// Resolves the plain and masked text in one pass; `masked` picks which one `value` carries.
    public func resolve(_ template: String, masked: Bool = false) -> TemplateResolution {
        TemplateExpansion.resolve(template, masked: masked, dynamic: dynamic) { name in
            scope.lookup(name).map { TemplateVariable(value: $0.value, isSecret: $0.isSecret) }
        }
    }
}
