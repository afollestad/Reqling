import Foundation

/// What sharing a project offers to bring along from Global, which the project doesn't carry: whoever it's shared with
/// resolves its variables against their own Global instead.
public struct GlobalVariablesOffer: Equatable, Sendable {
    /// Global's variables the project uses that its Default doesn't define, each as Global resolves it, to copy there.
    public var variables: [Variable] = []
    /// Global's variables the project's scripts read only through `rq.globals`, which a copy in Default can't stand in for.
    public var readThroughGlobals: [String] = []

    public var isEmpty: Bool {
        variables.isEmpty && readThroughGlobals.isEmpty
    }
}

extension ProjectLibrary {
    /// What sharing `id` offers to copy from Global (`GlobalVariablesOffer`).
    public func globalVariablesOffer(for id: ProjectID) -> GlobalVariablesOffer {
        guard let document = document(id) else {
            return GlobalVariablesOffer()
        }
        let references = document.variableReferences()
        let defined = Set(document.defaultEnvironment.variables.map(\.key))
        // The last enabled variable with a key is the one that resolves.
        var resolving: [String: Variable] = [:]
        for variable in globalEnvironment.variables where variable.isEnabled && !variable.key.isEmpty {
            resolving[variable.key] = variable
        }
        var offer = GlobalVariablesOffer()
        offer.variables = resolving.values
            .filter { references.names.contains($0.key) && !defined.contains($0.key) }
            .sorted { $0.key < $1.key }
        offer.readThroughGlobals = references.globalsOnly.filter { resolving[$0] != nil }.sorted()
        return offer
    }

    /// Copies Global's `keys` into `id`'s Default, as `globalVariablesOffer` offers them. A secret one keeps this person's
    /// value, which stays theirs: secret values never go to anyone the project is shared with.
    public func copyGlobalVariables(_ keys: Set<String>, into id: ProjectID) throws {
        let copies = globalVariablesOffer(for: id).variables.filter { keys.contains($0.key) }
        guard !copies.isEmpty else {
            return
        }
        try mutate(id) { document in
            document.defaultEnvironment.variables += copies.map { Variable(key: $0.key, value: $0.value, isSecret: $0.isSecret) }
        }
    }
}
