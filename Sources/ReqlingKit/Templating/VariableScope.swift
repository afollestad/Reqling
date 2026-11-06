import Foundation
import ReqlingTemplating

/// The variables visible to one run, flattened from its `VariableLayers`: Global's enabled variables, overridden by the
/// project's Default's, overridden by the active environment's, overridden by one-run overrides (from MCP's
/// `execute_request`, for example), overridden by values a script set for the run.
public struct VariableScope: Sendable {
    public struct Entry: Hashable, Sendable {
        public let value: String
        public let source: Source
        public let isSecret: Bool
        /// The value is this Mac's current value, set by a script, rather than the environment's saved one.
        public let isCurrentValue: Bool

        public init(value: String, source: Source, isSecret: Bool, isCurrentValue: Bool = false) {
            self.value = value
            self.source = source
            self.isSecret = isSecret
            self.isCurrentValue = isCurrentValue
        }
    }

    public enum Source: Hashable, Sendable {
        case environment(id: EnvironmentID, name: String)
        case override
        /// Set by a script for the rest of its run.
        case script
    }

    public private(set) var entries: [String: Entry]
    /// What `entries` was flattened from; a run hands these to its scripts. A scope built from bare entries keeps them
    /// as run-local values.
    public let layers: VariableLayers

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
        layers = VariableLayers(local: entries.mapValues { TemplateVariable(value: $0.value, isSecret: $0.isSecret) })
    }

    /// `activeEnvironmentID` of `nil` or of the Default environment means Global and Default alone. `global` and
    /// `currentValues` have no default value, so no caller can leave Global's variables or what scripts set on this Mac
    /// out of what a run sees, what the editor shows, or what masking covers.
    public init(
        global: RequestEnvironment,
        document: ProjectDocument,
        activeEnvironmentID: EnvironmentID?,
        currentValues: CurrentValueSnapshot,
        overrides: [String: String] = [:]
    ) {
        let active = activeEnvironmentID.flatMap { id in
            document.isDefaultEnvironment(id) ? nil : document.environment(id)
        }
        let layers = VariableLayers(
            global: VariableLayer(global, current: currentValues.global),
            defaultEnvironment: VariableLayer(document.defaultEnvironment, current: currentValues.values(for: document.defaultEnvironment.id)),
            active: active.map { VariableLayer($0, current: currentValues.values(for: $0.id)) },
            overrides: overrides
        )
        self.init(layers: layers, environments: Environments(global: global, defaultEnvironment: document.defaultEnvironment, active: active))
    }

    /// A scope over `layers` as a run's scripts left them; `environments` names the layers' sources.
    init(layers: VariableLayers, environments: Environments) {
        self.layers = layers
        entries = layers.flattened().mapValues { resolved in
            let source: Source = switch resolved.layer {
            case .global: .environment(id: environments.global.id, name: environments.global.name)
            case .defaultEnvironment: .environment(id: environments.defaultEnvironment.id, name: environments.defaultEnvironment.name)
            case .activeEnvironment:
                environments.active.map { .environment(id: $0.id, name: $0.name) } ?? .override
            case .override: .override
            case .local: .script
            }
            return Entry(
                value: resolved.variable.value,
                source: source,
                isSecret: resolved.variable.isSecret,
                isCurrentValue: resolved.isCurrentValue
            )
        }
    }

    /// The environments behind a scope's layers, for naming where each entry came from.
    struct Environments {
        let global: RequestEnvironment
        let defaultEnvironment: RequestEnvironment
        let active: RequestEnvironment?
    }

    public func lookup(_ name: String) -> Entry? {
        entries[name]
    }

    /// All visible names, sorted, for completion.
    public var names: [String] {
        entries.keys.sorted()
    }
}

extension VariableLayer {
    /// An environment's enabled variables by key (a later row wins), remembering every secret key.
    init(_ environment: RequestEnvironment, current: [String: CurrentVariable] = [:]) {
        var saved: [String: TemplateVariable] = [:]
        var secretKeys: Set<String> = []
        for variable in environment.variables where !variable.key.isEmpty {
            if variable.isSecret {
                secretKeys.insert(variable.key)
            }
            if variable.isEnabled {
                saved[variable.key] = TemplateVariable(value: variable.value, isSecret: variable.isSecret)
            }
        }
        self.init(saved: saved, secretKeys: secretKeys, current: current)
    }
}
