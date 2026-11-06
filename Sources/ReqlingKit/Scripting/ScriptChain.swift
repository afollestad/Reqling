import ReqlingScriptProtocol

/// Which scripts run around a request: the project's, then each enclosing folder's from the outermost in, then the
/// request's own, in both phases. A request or folder whose "Run inherited scripts" is off cuts the chain there: its
/// own scripts run, and none from above it. Empty scripts are left out.
extension ProjectDocument {
    /// The owners of `item`'s scripts in run order, whatever their phases hold. An item the project doesn't hold, such
    /// as an agent's unsaved request, sits at the top level.
    public func scriptOwners(of item: RequestItem) -> [ScriptOwner] {
        var owners: [ScriptOwner] = [.request(item)]
        guard item.runsInheritedScripts else {
            return owners
        }
        let ancestors = request(item.id) == nil ? [] : ancestors(of: item.id)
        for folder in ancestors.reversed() {
            owners.insert(.folder(folder), at: 0)
            if !folder.runsInheritedScripts {
                return owners
            }
        }
        owners.insert(.project(self), at: 0)
        return owners
    }

    /// Whether the project, or any folder or request in it, has a script.
    public var hasScripts: Bool {
        func any(_ nodes: [RequestNode]) -> Bool {
            nodes.contains { node in
                switch node {
                case .request(let request): !request.scripts.isEmpty
                case .folder(let folder): !folder.scripts.isEmpty || any(folder.children)
                }
            }
        }
        return !scripts.isEmpty || any(items)
    }

    /// The scripts that run for `item` in `phase`, in order, ready for the runner.
    public func scriptLevels(of item: RequestItem, phase: ScriptPhase) -> [ScriptLevelSource] {
        let owners = scriptOwners(of: item)
        return owners.compactMap { owner in
            let source = owner.scripts[phase]
            guard !source.isEmpty else {
                return nil
            }
            return ScriptLevelSource(kind: owner.kind, name: owner.name, path: owner.displayPath(phase, in: self), source: source)
        }
    }
}

/// A project, folder, or request whose scripts run around a request.
public enum ScriptOwner: Hashable, Sendable {
    case project(ProjectDocument)
    case folder(RequestFolder)
    case request(RequestItem)

    public var kind: ScriptLevelKind {
        switch self {
        case .project: .project
        case .folder: .folder
        case .request: .request
        }
    }

    public var name: String {
        switch self {
        case .project(let project): project.name
        case .folder(let folder): folder.name
        case .request(let request): request.name
        }
    }

    public var scripts: ScriptSet {
        switch self {
        case .project(let project): project.scripts
        case .folder(let folder): folder.scripts
        case .request(let request): request.scripts
        }
    }

    /// A readable place for error locations and stack traces: the owner's names, not its file's slug, since the file
    /// may be renamed while the report lives on in the history.
    func displayPath(_ phase: ScriptPhase, in document: ProjectDocument) -> String {
        let suffix = ".\(phase.fileSuffix).\(ProjectLayout.scriptExtension)"
        switch self {
        case .project:
            return "project\(suffix)"
        case .folder(let folder):
            return (document.ancestors(of: folder.id).map(\.name) + [folder.name, "_folder\(suffix)"]).joined(separator: "/")
        case .request(let request):
            let folders = document.request(request.id) == nil ? [] : document.ancestors(of: request.id).map(\.name)
            return (folders + [request.name + suffix]).joined(separator: "/")
        }
    }
}
