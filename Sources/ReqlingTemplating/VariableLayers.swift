import Foundation

/// What a script left for one key of one environment on this Mac: a value that beats the saved one, or a marker that
/// hides the saved one until it is reset.
public enum CurrentVariable: Hashable, Sendable, Codable {
    case value(TemplateVariable)
    case unset
}

/// One environment's variables as a run sees them: its saved values with this Mac's current values over them.
public struct VariableLayer: Hashable, Sendable, Codable {
    /// Enabled saved variables by key.
    public var saved: [String: TemplateVariable]
    /// Every key a saved secret row uses, disabled rows included, so a value a script writes under it stays secret.
    public var secretKeys: Set<String>
    /// Values and markers scripts left on this Mac, which beat `saved` key by key.
    public var current: [String: CurrentVariable]

    public init(saved: [String: TemplateVariable] = [:], secretKeys: Set<String> = [], current: [String: CurrentVariable] = [:]) {
        self.saved = saved
        self.secretKeys = secretKeys
        self.current = current
    }

    /// The current value, else the saved one unless a marker hides it. `isCurrent` tells the two apart.
    public func value(for key: String) -> (variable: TemplateVariable, isCurrent: Bool)? {
        switch current[key] {
        case .value(let variable):
            (variable, true)
        case .unset:
            nil
        case nil:
            saved[key].map { ($0, false) }
        }
    }

    /// Keys with a value here, current or saved, that no marker hides.
    public var visibleKeys: Set<String> {
        Set(saved.keys).union(current.keys).filter { value(for: $0) != nil }
    }
}

/// Which layer a variable came from.
public enum VariableLayerKind: String, Hashable, Sendable, Codable {
    case global
    case defaultEnvironment
    case activeEnvironment
    case override
    /// Set by a script for the rest of this run only.
    case local
}

public struct ResolvedVariable: Hashable, Sendable {
    public let variable: TemplateVariable
    public let layer: VariableLayerKind
    public let isCurrentValue: Bool

    public init(variable: TemplateVariable, layer: VariableLayerKind, isCurrentValue: Bool) {
        self.variable = variable
        self.layer = layer
        self.isCurrentValue = isCurrentValue
    }
}

/// Where a script's `set` or `unset` lands.
public enum VariableWriteScope: String, Hashable, Sendable, Codable {
    /// The run's environment: the active one, or Default while Default is active.
    case environment
    case defaultEnvironment
    case global
    /// The rest of this run only.
    case local
}

/// One `set` or `unset` from a script.
public struct VariableWrite: Hashable, Sendable, Codable {
    public var scope: VariableWriteScope
    public var key: String
    /// `nil` unsets.
    public var value: String?
    public var isSecret: Bool

    public init(scope: VariableWriteScope, key: String, value: String?, isSecret: Bool = false) {
        self.scope = scope
        self.key = key
        self.value = value
        self.isSecret = isSecret
    }
}

/// Every variable one run can see, layered: run-local values beat one-run overrides, which beat each environment's
/// current-over-saved values, active above Default above Global. This is the only implementation of that order: Reqling's
/// `VariableScope` flattens it, and the script runner reads and writes it, so a script's `get` agrees with what the
/// request resolves. A marker (`CurrentVariable.unset`) hides only its own layer's saved value; lower layers still show.
public struct VariableLayers: Hashable, Sendable, Codable {
    /// Values shorter than this are never treated as secrets found inside other text: masking every "42" would garble
    /// output while hiding nothing.
    public static let minimumSecretLength = 3

    public var global: VariableLayer
    public var defaultEnvironment: VariableLayer
    /// `nil` while Default is the active environment.
    public var active: VariableLayer?
    public var overrides: [String: String]
    public var local: [String: TemplateVariable]

    public init(
        global: VariableLayer = VariableLayer(),
        defaultEnvironment: VariableLayer = VariableLayer(),
        active: VariableLayer? = nil,
        overrides: [String: String] = [:],
        local: [String: TemplateVariable] = [:]
    ) {
        self.global = global
        self.defaultEnvironment = defaultEnvironment
        self.active = active
        self.overrides = overrides
        self.local = local
    }

    public func lookup(_ key: String) -> ResolvedVariable? {
        if let variable = local[key] {
            return ResolvedVariable(variable: variable, layer: .local, isCurrentValue: false)
        }
        if let value = overrides[key] {
            return ResolvedVariable(variable: TemplateVariable(value: value), layer: .override, isCurrentValue: false)
        }
        let environments: [(VariableLayer?, VariableLayerKind)] = [
            (active, .activeEnvironment),
            (defaultEnvironment, .defaultEnvironment),
            (global, .global)
        ]
        for case let (layer?, kind) in environments {
            if let found = layer.value(for: key) {
                return ResolvedVariable(variable: found.variable, layer: kind, isCurrentValue: found.isCurrent)
            }
        }
        return nil
    }

    /// Every visible key with what `lookup` gives it.
    public func flattened() -> [String: ResolvedVariable] {
        var keys = Set(local.keys).union(overrides.keys).union(defaultEnvironment.visibleKeys).union(global.visibleKeys)
        if let active {
            keys.formUnion(active.visibleKeys)
        }
        var result: [String: ResolvedVariable] = [:]
        for key in keys {
            result[key] = lookup(key)
        }
        return result
    }

    /// The layer a scope writes to; `nil` for `.local`, which has no saved values.
    public func layer(for scope: VariableWriteScope) -> VariableLayer? {
        switch scope {
        case .environment: active ?? defaultEnvironment
        case .defaultEnvironment: defaultEnvironment
        case .global: global
        case .local: nil
        }
    }

    /// Every secret value any layer holds, saved, current, or run-local, for masking output and for the leak guard.
    public var allSecretValues: Set<String> {
        var values: Set<String> = []
        for layer in [global, defaultEnvironment] + (active.map { [$0] } ?? []) {
            for variable in layer.saved.values where variable.isSecret {
                values.insert(variable.value)
            }
            for case .value(let variable) in layer.current.values where variable.isSecret {
                values.insert(variable.value)
            }
        }
        for variable in local.values where variable.isSecret {
            values.insert(variable.value)
        }
        return values
    }

    /// Applies one write and returns it with its secret flag settled, which never downgrades. A value is secret when
    /// the script says so, when its key is secret anywhere it resolves or in the layer it lands in, or when it contains
    /// a secret value already in scope (`"Bearer " + token`), so a derived credential is never stored or shown in plain.
    @discardableResult
    public mutating func apply(_ write: VariableWrite) -> VariableWrite {
        var write = write
        write.isSecret = write.value != nil && isSecret(write)
        let current: CurrentVariable = write.value.map { .value(TemplateVariable(value: $0, isSecret: write.isSecret)) } ?? .unset
        switch write.scope {
        case .environment:
            if active != nil {
                active?.current[write.key] = current
            } else {
                defaultEnvironment.current[write.key] = current
            }
        case .defaultEnvironment:
            defaultEnvironment.current[write.key] = current
        case .global:
            global.current[write.key] = current
        case .local:
            local[write.key] = write.value.map { TemplateVariable(value: $0, isSecret: write.isSecret) }
        }
        return write
    }

    private func isSecret(_ write: VariableWrite) -> Bool {
        if write.isSecret || lookup(write.key)?.variable.isSecret == true {
            return true
        }
        if let layer = layer(for: write.scope) {
            if layer.secretKeys.contains(write.key) {
                return true
            }
            if case .value(let existing) = layer.current[write.key], existing.isSecret {
                return true
            }
        } else if local[write.key]?.isSecret == true {
            return true
        }
        guard let value = write.value else {
            return false
        }
        return Self.contains(value, anyOf: allSecretValues)
    }

    /// Whether `text` holds any of `secrets` long enough to count, ignoring case as masking does.
    public static func contains(_ text: String, anyOf secrets: Set<String>) -> Bool {
        secrets.contains { $0.count >= minimumSecretLength && text.range(of: $0, options: .caseInsensitive) != nil }
    }
}
