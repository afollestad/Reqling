import Foundation
import ReqlingScriptProtocol

/// Scripts in a save. Each is a file beside its owner's JSON (`ProjectLayout.scriptPath`), written byte for byte as
/// typed and compared like any other file. A request's scripts move with its JSON (`ProjectWriter+Moves.swift`), and a
/// folder's ride along inside its directory. A script emptied since it was read goes to the Trash; one that was already
/// an empty file is left alone and stays tracked, so typing into it later overwrites it rather than finding it in the way.
extension ProjectWriter {
    /// Whose script a removal is: what tells where the file is once this save's moves are done.
    enum ScriptOwner: Equatable {
        case project
        case request(RequestNodeID)
        case folder(RequestNodeID)
    }

    /// A script emptied since it was read, at the path it was read from.
    struct PlannedScriptRemoval {
        let owner: ScriptOwner
        let phase: ScriptPhase
        let source: String
    }

    /// Every script file the save writes, and every emptied script it trashes.
    func plannedScripts(
        _ document: ProjectDocument,
        layout: ProjectSaveLayout,
        previous: ProjectDiskIndex
    ) -> (files: [PlannedFile], removals: [PlannedScriptRemoval]) {
        var files: [PlannedFile] = []
        var removals: [PlannedScriptRemoval] = []
        func plan(_ scripts: ScriptSet, owner: ScriptOwner, path: (ScriptPhase) -> String, previousPath: ((ScriptPhase) -> String)?) {
            for phase in ScriptPhase.allCases {
                let source = previousPath.map { $0(phase) }.flatMap { previous.diskContents[$0] == nil ? nil : $0 }
                let text = scripts[phase]
                let stored = source.flatMap { previous.contents[$0] }
                if !text.isEmpty || stored?.isEmpty == true {
                    files.append(PlannedFile(path: path(phase), data: Data(text.utf8), source: source))
                } else if let source {
                    removals.append(PlannedScriptRemoval(owner: owner, phase: phase, source: source))
                }
            }
        }
        plan(document.scripts, owner: .project, path: ProjectLayout.projectScriptPath, previousPath: ProjectLayout.projectScriptPath)
        func walk(_ nodes: [RequestNode]) {
            for node in nodes {
                guard let path = layout.nodePaths[node.id] else {
                    continue
                }
                let previousPath = previous.nodePaths[node.id]
                switch node {
                case .request(let request):
                    plan(
                        request.scripts,
                        owner: .request(request.id),
                        path: { ProjectLayout.scriptPath(forRequestAt: path, $0) },
                        previousPath: previousPath.map { previousPath in { ProjectLayout.scriptPath(forRequestAt: previousPath, $0) } }
                    )
                case .folder(let folder):
                    plan(
                        folder.scripts,
                        owner: .folder(folder.id),
                        path: { ProjectLayout.scriptPath(forFolderAt: path, $0) },
                        previousPath: previousPath.map { previousPath in { ProjectLayout.scriptPath(forFolderAt: previousPath, $0) } }
                    )
                    walk(folder.children)
                }
            }
        }
        walk(document.items)
        return (files, removals)
    }

    /// Refuses to trash a script whose bytes changed since they were read, as `checkUnchangedOnDisk` refuses to
    /// overwrite one. A script already gone needs nothing.
    func checkUnchangedOnDisk(_ removals: [PlannedScriptRemoval], previous: ProjectDiskIndex) throws {
        for removal in removals {
            guard exists(removal.source) else {
                continue
            }
            guard (try? Data(contentsOf: url(removal.source))) == previous.diskContents[removal.source] else {
                throw ProjectStorageError.changedOnDisk(removal.source)
            }
        }
    }

    /// Trashes emptied scripts from wherever this save's moves left them.
    func trashEmptiedScripts(_ removals: [PlannedScriptRemoval], live: inout LivePaths) throws {
        for removal in removals {
            let path: String
            switch removal.owner {
            case .project:
                path = ProjectLayout.projectScriptPath(removal.phase)
            case .request(let id):
                guard let requestPath = live.nodes[id] else {
                    continue
                }
                path = ProjectLayout.scriptPath(forRequestAt: requestPath, removal.phase)
                live.scripts[id]?.remove(removal.phase)
            case .folder(let id):
                guard let folderPath = live.nodes[id] else {
                    continue
                }
                path = ProjectLayout.scriptPath(forFolderAt: folderPath, removal.phase)
            }
            if exists(path) {
                try trasher.trash(url(path))
            }
        }
    }

    /// The phases whose script file each request had when last read or written. Only these move with it: a script
    /// file the reader left untracked beside it stays where it is, reserving its name.
    static func trackedScripts(in previous: ProjectDiskIndex) -> [RequestNodeID: Set<ScriptPhase>] {
        var tracked: [RequestNodeID: Set<ScriptPhase>] = [:]
        for (id, path) in previous.nodePaths where path.hasSuffix(".\(ProjectLayout.jsonExtension)") {
            let phases = ScriptPhase.allCases.filter { previous.diskContents[ProjectLayout.scriptPath(forRequestAt: path, $0)] != nil }
            if !phases.isEmpty {
                tracked[id] = Set(phases)
            }
        }
        return tracked
    }

    /// The request's tracked script files at `path`, for vacating and trashing them with it.
    static func scriptPaths(ofRequestAt path: String, phases: Set<ScriptPhase>?) -> [String] {
        (phases ?? []).sorted { $0.rawValue < $1.rawValue }.map { ProjectLayout.scriptPath(forRequestAt: path, $0) }
    }
}
