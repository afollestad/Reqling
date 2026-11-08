import Foundation

/// How Postman environments and globals land in Reqling's, for a new project and for the Environments sheet alike:
/// Postman's value wins, so importing an updated export again brings its changes in.
public enum PostmanEnvironmentMerge {
    /// The environments an import merges into: Global, a project's Default, and its others.
    public struct Targets: Sendable {
        public var global: RequestEnvironment
        public var defaultEnvironment: RequestEnvironment
        public var environments: [RequestEnvironment]

        public init(global: RequestEnvironment, defaultEnvironment: RequestEnvironment, environments: [RequestEnvironment]) {
            self.global = global
            self.defaultEnvironment = defaultEnvironment
            self.environments = environments
        }
    }

    /// Merges each file in order. A globals file goes into Global, and an environment named "Default" into Default.
    /// Another environment merges into the one of its name, matched exactly, then ignoring case, or is added after the
    /// others. One named like Global, a name a project's environment can't take, is added as "Global (Postman)".
    ///
    /// Returns what changed in each environment, and the ID of each the files named, in order, for the sheet to select.
    public static func merge(_ files: [PostmanFile], into targets: inout Targets) -> (changes: [PostmanEnvironmentChange], touched: [EnvironmentID]) {
        var changes: [PostmanEnvironmentChange] = []
        var touched: [EnvironmentID] = []
        for file in files {
            switch file {
            case .collection:
                continue
            case .globals(let globals):
                let (added, updated) = merge(globals.variables, into: &targets.global)
                changes.append(PostmanEnvironmentChange(environment: RequestEnvironment.globalName, isNew: false, added: added, updated: updated))
                touched.append(targets.global.id)
            case .environment(let environment):
                let (change, id) = merge(environment, into: &targets)
                changes.append(change)
                touched.append(id)
            }
        }
        return (changes, touched)
    }

    /// Merges `imported` into `environment` by key, keeping each existing variable's ID, so the edit reads as changed
    /// rows rather than removed and added ones. Postman's value and enabled state win, with two exceptions that keep
    /// what's already here: an empty value never blanks a filled one (Postman exports often leave a secret's value out),
    /// and a secret stays secret, so an export that lost the type never writes its value into the project's files.
    /// Returns the keys added and the keys whose variable changed.
    public static func merge(_ imported: [Variable], into environment: inout RequestEnvironment) -> (added: [String], updated: [String]) {
        var added: [String] = []
        var updated: [String] = []
        for variable in imported {
            // The last of a key's variables is the one that resolves, so it's the one Postman's value replaces.
            guard let index = environment.variables.lastIndex(where: { $0.key == variable.key }) else {
                environment.variables.append(Variable(key: variable.key, value: variable.value, isEnabled: variable.isEnabled,
                                                      isSecret: variable.isSecret))
                added.append(variable.key)
                continue
            }
            var existing = environment.variables[index]
            if !variable.value.isEmpty {
                existing.value = variable.value
            }
            existing.isEnabled = variable.isEnabled
            existing.isSecret = existing.isSecret || variable.isSecret
            if existing != environment.variables[index] {
                environment.variables[index] = existing
                if !updated.contains(variable.key) && !added.contains(variable.key) {
                    updated.append(variable.key)
                }
            }
        }
        return (added, updated)
    }

    private static func merge(_ file: PostmanVariableFile, into targets: inout Targets) -> (PostmanEnvironmentChange, EnvironmentID) {
        let name = file.name.isEmpty ? "Postman" : file.name
        if name.caseInsensitiveCompare(RequestEnvironment.defaultName) == .orderedSame {
            let (added, updated) = merge(file.variables, into: &targets.defaultEnvironment)
            let change = PostmanEnvironmentChange(environment: RequestEnvironment.defaultName, isNew: false, added: added, updated: updated)
            return (change, targets.defaultEnvironment.id)
        }
        let wanted = RequestEnvironment.isGlobalName(name) ? "\(RequestEnvironment.globalName) (Postman)" : name
        let index = targets.environments.firstIndex { $0.name == wanted }
            ?? targets.environments.firstIndex { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
        if let index {
            let (added, updated) = merge(file.variables, into: &targets.environments[index])
            let change = PostmanEnvironmentChange(environment: targets.environments[index].name, isNew: false, added: added, updated: updated)
            return (change, targets.environments[index].id)
        }
        var environment = RequestEnvironment(name: wanted)
        let (added, _) = merge(file.variables, into: &environment)
        targets.environments.append(environment)
        return (PostmanEnvironmentChange(environment: wanted, isNew: true, added: added, updated: []), environment.id)
    }
}
