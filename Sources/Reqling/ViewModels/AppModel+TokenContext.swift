import Foundation
import ReqlingKit
import ReqlingScriptProtocol

/// What the editors know about the variables in a project: its environments and Global, plus the names its scripts
/// set by literal name, so a `{{token}}` a login's script saves isn't marked undefined before it first runs.
extension AppModel {
    /// Rebuilt only when Global, the project's environments, the active one, what scripts set on this Mac, or the
    /// project's scripts change. Every `TemplateField` and `CodeEditor` compares this in `updateNSView`, and a request
    /// screen re-renders once per frame of a resize, so building a fresh scope per read multiplied across every field.
    ///
    /// Environment and Global names count wherever in the project a script sets them; a run-local name
    /// (`rq.variables.set`) counts only for `request`, when its own pre-request chain sets it.
    func tokenContext(for project: ProjectID, request: RequestNodeID? = nil) -> TemplateTokenContext {
        // Read every observable input before consulting the cache, so observation keeps tracking them.
        let document = library.document(project)
        let key = TokenContextKey(
            globalEnvironment: library.globalEnvironment,
            defaultEnvironment: document?.defaultEnvironment,
            environments: document?.environments ?? [],
            activeEnvironmentID: activeEnvironmentID(for: project),
            currentValuesRevision: library.currentValues.revision,
            scripts: ScriptVariablesKey(document)
        )
        let id = TokenContextID(project: project, request: request)
        if let cached = tokenContexts[id], cached.key == key {
            return cached.value
        }
        var value = TemplateTokenContext(scope: scope(for: project))
        if let document {
            let chain = request.flatMap(document.request).map { item in Set(document.scriptOwners(of: item).map(ScriptsOwnerID.init)) }
            value.addScriptVariables(scriptSetVariables(in: project), chain: chain)
        }
        tokenContexts[id] = (key, value)
        return value
    }

    /// Every variable the project's scripts set by literal name.
    func scriptSetVariables(in project: ProjectID) -> [ScriptSetVariable] {
        guard let document = library.document(project) else {
            return []
        }
        let key = ScriptVariablesKey(document)
        if let cached = scriptVariableCache[project], cached.key == key {
            return cached.value
        }
        let value = document.scriptSetVariables()
        scriptVariableCache[project] = (key, value)
        return value
    }

    /// The same, as a script's string arguments complete with them.
    func scriptDeclaredVariables(in project: ProjectID) -> [ScriptDeclaredVariable] {
        scriptSetVariables(in: project).map { ScriptDeclaredVariable(name: $0.name, source: $0.source) }
    }
}

/// Which token context a memo entry is: a project's, or one request's within it.
struct TokenContextID: Hashable {
    let project: ProjectID
    let request: RequestNodeID?
}

/// Everything `AppModel.tokenContext(for:request:)` builds from: Global, the project's environments, Default included
/// (the document stores it apart from the others), which one is active, and its scripts.
struct TokenContextKey: Equatable {
    let globalEnvironment: RequestEnvironment
    let defaultEnvironment: RequestEnvironment?
    let environments: [RequestEnvironment]
    let activeEnvironmentID: EnvironmentID?
    let currentValuesRevision: Int
    let scripts: ScriptVariablesKey
}

/// Where a project's scripts are: its own, and its tree's. Comparing it costs nothing while the document is unchanged,
/// since an array compared with itself matches by its storage.
struct ScriptVariablesKey: Equatable {
    let scripts: ScriptSet?
    let items: [RequestNode]

    init(_ document: ProjectDocument?) {
        scripts = document?.scripts
        items = document?.items ?? []
    }
}

/// A variable a project's script sets by literal name, which `{{name}}` pills count as defined.
struct ScriptSetVariable: Hashable {
    let name: String
    let source: ScriptVariableSource
    let phase: ScriptPhase
    let owner: ScriptsOwnerID
    /// As a pill's tooltip names it: "the post-response script of “Login”".
    let setter: String
}

extension ScriptsOwnerID {
    init(_ owner: ScriptOwner) {
        switch owner {
        case .project: self = .project
        case .folder(let folder): self = .folder(folder.id)
        case .request(let request): self = .request(request.id)
        }
    }
}

extension ProjectDocument {
    /// Every variable the project's scripts set by literal name, the project's first, then its tree's in order.
    func scriptSetVariables() -> [ScriptSetVariable] {
        var found: [ScriptSetVariable] = []
        func add(_ scripts: ScriptSet, owner: ScriptsOwnerID, name: String) {
            for phase in ScriptPhase.allCases where !scripts[phase].isEmpty {
                for variable in ScriptAnalyzer.declaredVariables(in: scripts[phase]) {
                    let setter = "the \(phase.title.lowercased()) script of \(name)"
                    found.append(ScriptSetVariable(name: variable.name, source: variable.source, phase: phase, owner: owner, setter: setter))
                }
            }
        }
        func walk(_ nodes: [RequestNode]) {
            for node in nodes {
                switch node {
                case .request(let request):
                    add(request.scripts, owner: .request(request.id), name: "“\(request.name)”")
                case .folder(let folder):
                    add(folder.scripts, owner: .folder(folder.id), name: "folder “\(folder.name)”")
                    walk(folder.children)
                }
            }
        }
        add(scripts, owner: .project, name: "the project")
        walk(items)
        return found
    }
}

extension TemplateTokenContext {
    /// Adds the names scripts set that nothing else defines: Environment and Global ones as set anywhere, and run-local
    /// ones only when a pre-request script in `chain` sets them, the only ones that run before the request resolves.
    mutating func addScriptVariables(_ variables: [ScriptSetVariable], chain: Set<ScriptsOwnerID>?) {
        for variable in variables where entries[variable.name] == nil {
            if variable.source == .all {
                guard let chain, variable.phase == .preRequest, chain.contains(variable.owner) else {
                    continue
                }
            }
            entries[variable.name] = Entry(displayValue: "", sourceName: variable.setter, isSetByScript: true)
        }
    }
}
