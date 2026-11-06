import ReqlingScriptProtocol
import ReqlingTemplating

/// The phase's variables, which every level shares. Each write applies at once (`VariableLayers.apply`), so the next
/// `get`, `replaceIn`, or level sees it, and is reported straight away, so it survives a later throw or kill.
final class ScriptVariables {
    /// What `rq.environment`, `rq.defaultEnvironment`, `rq.globals`, and `rq.variables` read and write.
    enum Scope: String {
        case environment
        case defaultEnvironment
        case global
        /// Reads every layer, as `{{name}}` does; writes are run-local.
        case variables

        var writeScope: VariableWriteScope {
            switch self {
            case .environment: .environment
            case .defaultEnvironment: .defaultEnvironment
            case .global: .global
            case .variables: .local
            }
        }
    }

    private(set) var layers: VariableLayers
    private let limits: ScriptLimits
    private let events: EventWriter
    private var writes = 0

    init(layers: VariableLayers, limits: ScriptLimits, events: EventWriter) {
        self.layers = layers
        self.limits = limits
        self.events = events
    }

    func get(_ scope: Scope, _ key: String) -> TemplateVariable? {
        switch scope {
        case .variables: layers.lookup(key)?.variable
        default: layers.layer(for: scope.writeScope)?.value(for: key)?.variable
        }
    }

    /// Every visible key in `scope` with its value.
    func values(_ scope: Scope) -> [String: String] {
        switch scope {
        case .variables:
            return layers.flattened().mapValues(\.variable.value)
        default:
            guard let layer = layers.layer(for: scope.writeScope) else {
                return [:]
            }
            var values: [String: String] = [:]
            for key in layer.visibleKeys {
                values[key] = layer.value(for: key)?.variable.value
            }
            return values
        }
    }

    /// Whether the key resolves to a secret in `scope`, or would be stored as one there.
    func isSecret(_ scope: Scope, _ key: String) -> Bool {
        if get(scope, key)?.isSecret == true {
            return true
        }
        return layers.layer(for: scope.writeScope)?.secretKeys.contains(key) ?? false
    }

    /// Sets, or with a `nil` value unsets, and reports the write.
    func set(_ scope: Scope, _ key: String, value: String?, secret: Bool) throws(ScriptFailure) {
        guard !key.isEmpty else {
            throw ScriptFailure("A variable needs a name.")
        }
        guard writes < limits.variableWrites else {
            throw ScriptFailure("Scripts can set at most \(limits.variableWrites) values in one phase.")
        }
        if let value, value.utf16.count > limits.valueLength {
            throw ScriptFailure("“\(key)” is too long to keep; a value can hold at most \(limits.valueLength) characters.")
        }
        writes += 1
        let applied = layers.apply(VariableWrite(scope: scope.writeScope, key: key, value: value, isSecret: secret))
        events.write(.variable(applied))
    }

    /// Resolves `{{name}}` references as the request will, with what scripts have set so far.
    func replaceIn(_ text: String) -> String {
        TemplateExpansion.resolve(text, dynamic: .live) { layers.lookup($0)?.variable }.value
    }
}
