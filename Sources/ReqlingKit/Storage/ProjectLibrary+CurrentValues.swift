import Foundation
import ReqlingTemplating

/// Current values (`CurrentValueStore`) where they meet saved ones: an edit of a saved variable made in Reqling drops
/// its current value so the edit takes effect, and Save as Value turns a current value into the saved one. Both go
/// through `mutate` or `mutateGlobalEnvironment`, so every edit path (the Environments sheet, MCP) clears alike, while
/// a reload after an outside change (a `git pull`) never does.
extension ProjectLibrary {
    /// Makes a current value its environment's saved value (`RequestEnvironment.adoptCurrentValue`) and drops the
    /// current value.
    public func saveCurrentValue(_ key: String, in scope: CurrentValueScope) throws {
        guard case .value(let current)? = currentValues.values(in: scope)[key] else {
            throw CurrentValueError.nothingToSave(key)
        }
        switch scope {
        case .global:
            try mutateGlobalEnvironment { $0.adoptCurrentValue(current, for: key) }
        case .environment(let project, let environment):
            try mutate(project) { $0.updateEnvironment(environment) { $0.adoptCurrentValue(current, for: key) } }
        }
        // The saved value may already have matched, in which case the edit changed nothing and cleared nothing.
        currentValues.reset([key], in: scope)
    }

    /// Drops the current values an edit made stale: every key whose saved rows changed, and every environment removed.
    func resetCurrentValues(old: [RequestEnvironment], new: [RequestEnvironment], scope: (EnvironmentID) -> CurrentValueScope) {
        guard old != new else {
            return
        }
        let changes = SavedVariableChanges(old: old, new: new)
        for environment in changes.removedEnvironments {
            currentValues.reset(in: scope(environment))
        }
        for (environment, keys) in changes.changedKeys {
            currentValues.reset(keys, in: scope(environment))
        }
    }
}

extension RequestEnvironment {
    /// Saves a current value as this environment's value for `key`, secret when the current value is: Save as Value.
    /// The last enabled variable with the key takes it (the one that resolves), else the last disabled one, which is
    /// turned on; with none, a variable is added.
    public mutating func adoptCurrentValue(_ current: TemplateVariable, for key: String) {
        if let index = variables.lastIndex(where: { $0.key == key && $0.isEnabled }) ?? variables.lastIndex(where: { $0.key == key }) {
            variables[index].value = current.value
            variables[index].isEnabled = true
            variables[index].isSecret = variables[index].isSecret || current.isSecret
        } else {
            variables.append(Variable(key: key, value: current.value, isSecret: current.isSecret))
        }
    }
}

/// The saved variables one edit changed, compared per key by what resolution sees of each row (value, enabled, secret)
/// rather than by ID, so a renamed key counts for both names and a reordered list for neither.
public struct SavedVariableChanges {
    public private(set) var changedKeys: [EnvironmentID: Set<String>] = [:]
    public private(set) var removedEnvironments: Set<EnvironmentID> = []

    public init(old: [RequestEnvironment], new: [RequestEnvironment]) {
        let updated = Dictionary(new.map { ($0.id, $0) }) { first, _ in first }
        for environment in old {
            guard let after = updated[environment.id] else {
                removedEnvironments.insert(environment.id)
                continue
            }
            let before = Self.rows(environment)
            let rows = Self.rows(after)
            let keys = Set(before.keys).union(rows.keys).filter { before[$0] != rows[$0] }
            if !keys.isEmpty {
                changedKeys[environment.id] = keys
            }
        }
    }

    private struct Row: Equatable {
        let value: String
        let isEnabled: Bool
        let isSecret: Bool
    }

    private static func rows(_ environment: RequestEnvironment) -> [String: [Row]] {
        Dictionary(grouping: environment.variables.filter { !$0.key.isEmpty }, by: \.key).mapValues { variables in
            variables.map { Row(value: $0.value, isEnabled: $0.isEnabled, isSecret: $0.isSecret) }
        }
    }
}

public enum CurrentValueError: Error, Equatable, LocalizedError {
    case nothingToSave(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToSave(let key):
            "“\(key)” has no current value to save."
        }
    }
}
