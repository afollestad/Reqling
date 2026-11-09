import Foundation
internal import ReqlingYAML

/// Maps a loaded OpenAPI 3 document (`OpenAPILoader.load`) to a project: one request per operation, in folders by tag,
/// its URL on `{{baseUrl}}` with path variables, its parameters and an example body, and its auth from the security
/// schemes, placed on the project or a folder where every request beneath shares it. Servers become `baseUrl` in
/// Default and, when there are several, an environment each. What doesn't carry over becomes a note, never a silent
/// loss. It only reads; `ProjectLifecycle.importProject` writes.
public enum OpenAPIImporter {
    public static func plan(_ source: OpenAPISource) -> ProjectImport {
        var planner = OpenAPIPlanner(source: source)
        return planner.plan()
    }
}

/// One import's work: the notes, counts, variables, and credentials it gathers as it walks the document.
struct OpenAPIPlanner {
    let source: OpenAPISource
    let resolver: OpenAPIResolver
    let root: OpenAPINode
    var notes: [ImportNote] = []
    var counts = ImportCounts()
    var credentials = ImportCredentials(reserved: [])
    /// Default's variables other than credentials: `baseUrl`, the first server's variables, and in-segment path
    /// parameters.
    var defaultVariables: [Variable] = []
    var environments: [RequestEnvironment] = []
    /// What each security scheme maps to, worked out when a request first uses it (`OpenAPIPlanner+Security`).
    var schemes: [String: OpenAPISchemeAuth] = [:]
    /// Deprecated operations' requests, by name, listed in one note.
    var deprecated: [String] = []

    init(source: OpenAPISource) {
        self.source = source
        resolver = OpenAPIResolver(source: source)
        root = OpenAPINode(value: source.document.root, document: OpenAPIReferences.documentKey(source.document.location))
    }

    mutating func plan() -> ProjectImport {
        if source.document.minorVersion > 2 {
            note(.project, .variable, "It's OpenAPI \(source.document.version); what it shares with OpenAPI 3.2 is imported.")
        }
        planServers()
        noteServers()
        let collected = OpenAPIOperations.collect(in: source)
        for problem in collected.problems {
            note(.project, .url, "\(problem.path): \(problem.message)")
        }
        var tree = folderTree(for: collected.operations)
        let projectAuth = placeAuth(in: &tree)
        countOmissions(collected.operations)
        if !deprecated.isEmpty {
            let shown = deprecated.prefix(5).map { "“\($0)”" } + (deprecated.count > 5 ? ["\(deprecated.count - 5) more"] : [])
            note(.project, .operation, "Deprecated: \(listed(shown)).")
        }
        defaultVariables += credentials.variables
        counts.credentialsToFill = credentials.variables.map(\.key)
        return ProjectImport(
            name: source.document.title,
            auth: projectAuth,
            scripts: ScriptSet(),
            items: tree.nodes(counting: &counts),
            defaultVariables: defaultVariables,
            environments: environments,
            globals: [],
            files: [],
            notes: notes,
            counts: counts,
            environmentChanges: environmentChanges(),
            hasScripts: false
        )
    }

    /// Default, then each server's environment, as what the import adds.
    private func environmentChanges() -> [ImportEnvironmentChange] {
        var changes: [ImportEnvironmentChange] = []
        if !defaultVariables.isEmpty {
            changes.append(ImportEnvironmentChange(
                environment: RequestEnvironment.defaultName, isNew: false, added: defaultVariables.map(\.key), updated: []
            ))
        }
        for environment in environments {
            changes.append(ImportEnvironmentChange(environment: environment.name, isNew: true, added: environment.variables.map(\.key), updated: []))
        }
        return changes
    }

    /// A Default variable the import makes, unless one by that name is already there, a credential's included; the
    /// first value wins.
    mutating func addDefaultVariable(_ key: String, value: String) {
        guard !(defaultVariables + credentials.variables).contains(where: { $0.key == key }) else {
            return
        }
        credentials.reserve(key)
        defaultVariables.append(Variable(key: key, value: value))
    }

    // MARK: - Notes

    mutating func note(_ owner: ImportNote.Owner, _ topic: ImportNote.Topic, _ message: String) {
        let note = ImportNote(owner: owner, topic: topic, message: message)
        if !notes.contains(note) {
            notes.append(note)
        }
    }

    /// The node `node` refers to, or `nil` with a note on `owner` when the reference can't be followed.
    mutating func resolved(_ node: OpenAPINode?, owner: ImportNote.Owner) -> OpenAPINode? {
        guard let node else {
            return nil
        }
        switch resolver.resolve(node) {
        case .success(let resolved):
            return resolved
        case .failure(let failure):
            note(owner, .reference, failure.message)
            return nil
        }
    }

    // MARK: - Not imported

    /// Response definitions, callbacks, links, webhooks, and descriptions, which Reqling has nowhere to keep.
    private mutating func countOmissions(_ operations: [OpenAPIOperation]) {
        var omitted: [ImportOmission: Int] = [:]
        for operation in operations {
            let responses = operation.node["responses"]?.members ?? []
            omitted[.responses, default: 0] += responses.count
            omitted[.callbacks, default: 0] += operation.node["callbacks"]?.members.count ?? 0
            for (_, response) in responses {
                omitted[.links, default: 0] += resolver.resolveOrNil(response)?["links"]?.members.count ?? 0
            }
            if operation.node["description"]?.value.string?.isEmpty == false {
                omitted[.descriptions, default: 0] += 1
            }
        }
        omitted[.webhooks, default: 0] += root["webhooks"]?.members.count ?? 0
        counts.omitted = omitted.filter { $0.value > 0 }
    }
}

extension OpenAPIResolver {
    func resolveOrNil(_ node: OpenAPINode) -> OpenAPINode? {
        try? resolve(node).get()
    }
}
