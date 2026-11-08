import Foundation
import ReqlingScriptProtocol

/// Maps a Postman collection, and the environment and globals files chosen with it, to a project: folders and requests
/// in order, their bodies and auth, the scripts at every level, and the variables. What doesn't carry over as it was
/// becomes a note for the person, never a silent loss. It only reads, so it runs off the main actor; writing is
/// `ProjectLifecycle.importProject`'s.
public enum PostmanImporter {
    /// `collectionDirectory` is where the collection file is, where a body's relative `src` is looked for.
    public static func plan(_ collection: PostmanCollection, files: [PostmanFile], collectionDirectory: URL?) -> ProjectImport {
        var planner = PostmanPlanner(root: collection.root, collectionDirectory: collectionDirectory)
        return planner.plan(name: collection.name, files: files)
    }
}

/// One import's work: the notes and counts it gathers while it walks the collection, and the credentials it moves out.
struct PostmanPlanner {
    let root: PostmanJSON
    let collectionDirectory: URL?
    var notes: [ImportNote] = []
    var counts = ImportCounts()
    var files: [ImportFileSlot] = []
    var credentials = ImportCredentials(reserved: [])
    var hasScripts = false
    /// The globals each enclosing folder's and the project's scripts define without declaring, outermost first, while
    /// the walk is inside them (`PostmanImporter+Scripts.swift`).
    var enclosingGlobals: [(owner: ImportNote.Owner, shared: [ScriptPhase: Set<String>])] = []
    /// How many scripts below read each of those globals, noted once on the script that defines it.
    var sharedGlobalUses: [SharedGlobalUse] = []

    init(root: PostmanJSON, collectionDirectory: URL?) {
        self.root = root
        self.collectionDirectory = collectionDirectory
    }

    mutating func plan(name: String, files chosen: [PostmanFile]) -> ProjectImport {
        let collectionVariables = Self.variables(root["variable"])
        var targets = PostmanEnvironmentMerge.Targets(
            global: .global(),
            defaultEnvironment: RequestEnvironment(name: RequestEnvironment.defaultName, variables: collectionVariables),
            environments: []
        )
        let merged = PostmanEnvironmentMerge.merge(chosen, into: &targets)
        counts.environments = chosen.filter { if case .environment = $0 { true } else { false } }.count
        let reserved = targets.global.variables + targets.defaultEnvironment.variables + targets.environments.flatMap(\.variables)
        credentials = ImportCredentials(reserved: Set(reserved.map(\.key)).union(Self.scriptSetNames(in: root)))
        noteRenamedEnvironments(chosen, into: targets)

        countDescription(root["info"])
        let auth = auth(root["auth"], owner: .project, inheritedByDefault: false)
        let scripts = scripts(root["event"], owner: .project, protocols: nil)
        enclosingGlobals = [(.project, Self.sharedGlobals(in: scripts))]
        let items = nodes(root["item"], path: [], profile: Self.profile(root["protocolProfileBehavior"], over: [:]))
        noteSharedGlobalUses()
        noteUnknownDynamicVariables(in: targets)

        var defaultEnvironment = targets.defaultEnvironment
        defaultEnvironment.variables += credentials.variables
        counts.credentials = credentials.variables.map(\.key)
        let defaultChange = merged.changes.filter { $0.environment != RequestEnvironment.globalName }
        return ProjectImport(
            name: name,
            auth: auth,
            scripts: scripts,
            items: items,
            defaultVariables: defaultEnvironment.variables,
            environments: targets.environments,
            globals: targets.global.variables,
            files: files,
            notes: notes,
            counts: counts,
            environmentChanges: defaultChange,
            hasScripts: hasScripts
        )
    }

    // MARK: - The tree

    /// Postman's `item` list: folders, which have an `item` list of their own, and requests, in order.
    private mutating func nodes(_ items: PostmanJSON?, path: [String], profile: [String: PostmanJSON]) -> [RequestNode] {
        (items?.array ?? []).map { item in
            let name = Self.name(of: item)
            let itemPath = path + [name]
            let itemProfile = Self.profile(item["protocolProfileBehavior"], over: profile)
            noteVariables(item["variable"], owner: .node(itemPath))
            guard item["item"]?.array != nil else {
                // A request's description is usually its request's, and sometimes the item's.
                countDescription(item["description"] == nil ? item["request"] : item)
                return .request(request(item, name: name, path: itemPath, profile: itemProfile))
            }
            countDescription(item)
            counts.folders += 1
            // Before its children, so credentials are numbered from the top of the tree down.
            let auth = auth(item["auth"], owner: .node(itemPath), inheritedByDefault: true)
            let scripts = scripts(item["event"], owner: .node(itemPath), protocols: nil)
            enclosingGlobals.append((.node(itemPath), Self.sharedGlobals(in: scripts)))
            let children = nodes(item["item"], path: itemPath, profile: itemProfile)
            enclosingGlobals.removeLast()
            return .folder(RequestFolder(name: name, auth: auth, scripts: scripts, children: children))
        }
    }

    static func name(of item: PostmanJSON) -> String {
        let name = item["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Untitled" : name
    }

    /// Postman's `protocolProfileBehavior` for an item, over what its folders and the collection set: the nearest
    /// level's value wins, key by key.
    static func profile(_ behavior: PostmanJSON?, over inherited: [String: PostmanJSON]) -> [String: PostmanJSON] {
        inherited.merging(behavior?.object ?? [:]) { _, nearer in nearer }
    }

    // MARK: - Variables

    /// Postman's `variable` list (a collection's), as Reqling variables: a `secret` type keeps its value in the Keychain.
    static func variables(_ list: PostmanJSON?) -> [Variable] {
        (list?.array ?? []).compactMap { entry in
            guard let key = (entry["key"] ?? entry["id"])?.string, !key.isEmpty else {
                return nil
            }
            return Variable(
                key: key,
                value: entry["value"]?.text ?? "",
                isEnabled: !(entry["disabled"]?.bool ?? false),
                isSecret: entry["type"]?.string == "secret"
            )
        }
    }

    /// A folder's or request's own variables have nowhere to go: Reqling keeps variables in environments.
    private mutating func noteVariables(_ list: PostmanJSON?, owner: ImportNote.Owner) {
        let keys = Self.variables(list).map(\.key)
        guard !keys.isEmpty else {
            return
        }
        let listed = keys.map { "“\($0)”" }.joined(separator: ", ")
        note(owner, .variable, "Its variables \(listed) aren't imported, since Reqling keeps variables in environments; add them to one.")
    }

    private mutating func noteRenamedEnvironments(_ chosen: [PostmanFile], into targets: PostmanEnvironmentMerge.Targets) {
        for file in chosen {
            guard case .environment(let environment) = file, RequestEnvironment.isGlobalName(environment.name) else {
                continue
            }
            let renamed = "\(RequestEnvironment.globalName) (Postman)"
            let message = "“\(environment.name)” is the name of the environment every project shares, so it's “\(renamed)” here."
            note(.environment(renamed), .variable, message)
        }
    }

    // MARK: - Notes

    mutating func note(_ owner: ImportNote.Owner, _ topic: ImportNote.Topic, _ message: String) {
        notes.append(ImportNote(owner: owner, topic: topic, message: message))
    }

    private mutating func countDescription(_ value: PostmanJSON?) {
        if let description = value?["description"], !description.text.isEmpty, description != .null {
            counts.omitted[.descriptions, default: 0] += 1
        }
    }
}
