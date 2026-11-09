import Foundation
import ReqlingScriptProtocol

/// Reading the request tree and what an interrupted save left in scratch, then settling node IDs across all of it.
extension ProjectReader {
    /// A request or folder as read, before its ID is settled.
    enum LoadedNode {
        case request(LoadedRequest)
        case folder(LoadedFolder)
    }

    struct LoadedRequest {
        let path: String
        let statedID: RequestNodeID?
        let rank: NodeRank
        let item: RequestItem
        let scripts: ScriptSet
    }

    struct LoadedFolder {
        let path: String
        let statedID: RequestNodeID?
        let rank: NodeRank
        let file: FolderFile
        let scripts: ScriptSet
        let children: [LoadedNode]
    }

    /// The children of `directory` in display order, or `nil` when it could not be listed.
    func loadChildren(directory: String, order: [String], state: inout ReadState) -> [LoadedNode]? {
        guard let names = listEntries(directory, state: &state) else {
            return nil
        }
        return loadChildren(named: names, in: directory, order: order, state: &state)
    }

    /// A request's scripts are paired with it only when its JSON loads; any other script file is left untracked, which
    /// reserves its name (`ProjectSaveLayout`) so no new item adopts it.
    private func loadChildren(named names: [String], in directory: String, order: [String], state: inout ReadState) -> [LoadedNode] {
        var loaded: [(slug: String, node: LoadedNode)] = []
        let siblings = Set(names)
        var paired: Set<String> = []
        var scripts: [String] = []
        for name in names {
            let path = ProjectLayout.join(directory, name)
            if name == ProjectLayout.folderFile {
                continue
            } else if isDirectory(path) {
                if let folder = loadFolder(path: path, isListed: order.contains(name), state: &state) {
                    loaded.append((name, .folder(folder)))
                }
            } else if name.hasSuffix(".\(ProjectLayout.jsonExtension)") {
                let slug = String(name.dropLast(ProjectLayout.jsonExtension.count + 1))
                if let request = loadRequest(path: path, isListed: order.contains(slug), siblings: siblings, paired: &paired, state: &state) {
                    loaded.append((slug, .request(request)))
                }
            } else if ProjectLayout.scriptOwner(ofFileNamed: name) != nil {
                scripts.append(name)
            } else {
                state.index.untrackedPaths.insert(path)
            }
        }
        for name in scripts where !paired.contains(name) {
            state.index.untrackedPaths.insert(ProjectLayout.join(directory, name))
        }
        return loaded.sorted { lhs, rhs in
            let lhsIndex = order.firstIndex(of: lhs.slug) ?? Int.max
            let rhsIndex = order.firstIndex(of: rhs.slug) ?? Int.max
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.slug.localizedStandardCompare(rhs.slug) == .orderedAscending
        }.map(\.node)
    }

    private func loadFolder(path: String, isListed: Bool, state: inout ReadState) -> LoadedFolder? {
        // A folder whose contents cannot be listed is skipped whole: loading it empty would let a save write into it.
        guard let names = listEntries(path, state: &state) else {
            return nil
        }
        let folderFilePath = ProjectLayout.join(path, ProjectLayout.folderFile)
        let folderFile: FolderFile
        let statedID: RequestNodeID?
        switch readFile(folderFilePath) {
        case .data(let data):
            guard let decoded = try? ProjectJSON.decode(FolderFile.self, from: data) else {
                state.index.untrackedPaths.insert(path)
                state.issues.append(ProjectLoadIssue(path: folderFilePath, message: "This folder file could not be read."))
                return nil
            }
            folderFile = decoded
            statedID = (try? ProjectJSON.decode(IDProbe.self, from: data))?.id == nil ? nil : decoded.id
            state.cache(folderFilePath, raw: data, decoded: decoded)
            state.index.orders[path] = decoded.order
        case .missing:
            // A folder created by another tool: adopt it under its directory name. Its ID is derived when settled.
            folderFile = FolderFile(id: RequestNodeID(), name: (path as NSString).lastPathComponent, order: [], auth: .inherit)
            statedID = nil
        case .failed:
            state.index.untrackedPaths.insert(path)
            state.issues.append(ProjectLoadIssue(path: folderFilePath, message: "This folder file could not be read."))
            return nil
        }
        let rank = state.nodeRank(statedID: statedID, path: path, name: folderFile.name, isFolder: true, isListed: isListed)
        var scripts = ScriptSet()
        for phase in ScriptPhase.allCases where names.contains(ProjectLayout.folderScriptName(phase)) {
            scripts[phase] = readScript(ProjectLayout.scriptPath(forFolderAt: path, phase), state: &state)
        }
        let folderScripts = Set(ScriptPhase.allCases.map(ProjectLayout.folderScriptName))
        let children = loadChildren(named: names.filter { !folderScripts.contains($0) }, in: path, order: folderFile.order, state: &state)
        return LoadedFolder(path: path, statedID: statedID, rank: rank, file: folderFile, scripts: scripts, children: children)
    }

    private func loadRequest(
        path: String,
        isListed: Bool,
        siblings: Set<String>,
        paired: inout Set<String>,
        state: inout ReadState
    ) -> LoadedRequest? {
        guard let data = readTrackedFile(path, state: &state) else {
            return nil
        }
        guard let item = try? ProjectJSON.decode(RequestItem.self, from: data) else {
            state.index.untrackedPaths.insert(path)
            state.issues.append(ProjectLoadIssue(path: path, message: "This request file could not be read."))
            return nil
        }
        let statedID = (try? ProjectJSON.decode(IDProbe.self, from: data))?.id == nil ? nil : item.id
        state.cache(path, raw: data, decoded: item)
        var scripts = ScriptSet()
        for phase in ScriptPhase.allCases {
            let scriptPath = ProjectLayout.scriptPath(forRequestAt: path, phase)
            let name = (scriptPath as NSString).lastPathComponent
            if siblings.contains(name) {
                paired.insert(name)
                scripts[phase] = readScript(scriptPath, state: &state)
            }
        }
        return LoadedRequest(
            path: path,
            statedID: statedID,
            rank: state.nodeRank(statedID: statedID, path: path, name: item.name, isFolder: false, isListed: isListed),
            item: item,
            scripts: scripts
        )
    }

    /// Gives every node its ID, considering the whole tree (and anything recovered from scratch) at once.
    ///
    /// A folder that loses its ID is a copy, so the children its copied `_folder.json` lists stop counting as listed.
    /// Settling again until no further folder loses carries that down one level per round. A folder stays demoted once
    /// it has lost, even if it wins a later round: otherwise two folders that each hold a copy of the other trade the
    /// win every round, and whichever round came last would decide. The demoted set only grows, so the rounds are
    /// bounded by the number of folders.
    func settleNodes(_ nodes: [LoadedNode], state: inout ReadState) -> [RequestNode] {
        let folders = Self.folderPaths(in: nodes)
        var demotedFolders: Set<String> = []
        while true {
            let settled = Self.settle(Self.claims(for: nodes, demotedFolders: demotedFolders)) { state.derivedID(for: $0) }
            let demoted = demotedFolders.union(folders.intersection(settled.replaced))
            if demoted == demotedFolders {
                return build(nodes, settled: settled, state: &state)
            }
            demotedFolders = demoted
        }
    }

    private static func claims(
        for nodes: [LoadedNode],
        demotedFolders: Set<String>,
        underDemotedFolder: Bool = false
    ) -> [IDClaim<RequestNodeTag>] {
        var claims: [IDClaim<RequestNodeTag>] = []
        for node in nodes {
            switch node {
            case .request(let request):
                let preference = request.rank.preference(underDemotedFolder: underDemotedFolder)
                claims.append(IDClaim(path: request.path, stated: request.statedID, preference: preference))
            case .folder(let folder):
                let preference = folder.rank.preference(underDemotedFolder: underDemotedFolder)
                claims.append(IDClaim(path: folder.path, stated: folder.statedID, preference: preference))
                let isDemoted = underDemotedFolder || demotedFolders.contains(folder.path)
                claims += Self.claims(for: folder.children, demotedFolders: demotedFolders, underDemotedFolder: isDemoted)
            }
        }
        return claims
    }

    private static func folderPaths(in nodes: [LoadedNode]) -> Set<String> {
        var paths: Set<String> = []
        for case .folder(let folder) in nodes {
            paths.insert(folder.path)
            paths.formUnion(folderPaths(in: folder.children))
        }
        return paths
    }

    private func build(_ nodes: [LoadedNode], settled: SettledIDs<RequestNodeTag>, state: inout ReadState) -> [RequestNode] {
        var result: [RequestNode] = []
        for node in nodes {
            switch node {
            case .request(let loaded):
                let id = settled.id(for: loaded.path)
                if settled.replaced.contains(loaded.path) {
                    state.issues.append(ProjectLoadIssue(path: loaded.path, message: "A duplicate request ID was replaced.", losesContent: false))
                }
                state.index.nodePaths[id] = loaded.path
                result.append(.request(RequestItem(
                    id: id,
                    name: loaded.item.name,
                    kind: loaded.item.kind,
                    scripts: loaded.scripts,
                    runsInheritedScripts: loaded.item.runsInheritedScripts
                )))
            case .folder(let loaded):
                let id = settled.id(for: loaded.path)
                if settled.replaced.contains(loaded.path) {
                    let folderFilePath = ProjectLayout.join(loaded.path, ProjectLayout.folderFile)
                    state.issues.append(ProjectLoadIssue(path: folderFilePath, message: "A duplicate folder ID was replaced.", losesContent: false))
                }
                state.index.nodePaths[id] = loaded.path
                let children = build(loaded.children, settled: settled, state: &state)
                result.append(.folder(RequestFolder(
                    id: id,
                    name: loaded.file.name,
                    auth: loaded.file.auth,
                    scripts: loaded.scripts,
                    runsInheritedScripts: loaded.file.inheritScripts,
                    children: children
                )))
            }
        }
        return result
    }

    // MARK: - Interrupted saves

    /// Loads what a crashed save left in the scratch directory as top-level items, so nothing it held goes missing;
    /// the next save moves them into the project proper. Anything that cannot be loaded is reported, never skipped.
    func loadScratch(state: inout ReadState) -> (nodes: [LoadedNode], environments: [LoadedEnvironment]) {
        let scratch = ProjectLayout.syncScratchDirectory
        guard isDirectory(scratch), let names = listEntries(scratch, state: &state) else {
            return ([], [])
        }
        var nodes: [LoadedNode] = []
        var environments: [LoadedEnvironment] = []
        for name in names {
            let path = ProjectLayout.join(scratch, name)
            if name == ProjectLayout.requestsDirectory, isDirectory(path) {
                nodes = loadChildren(directory: path, order: [], state: &state) ?? []
            } else if name == ProjectLayout.environmentsDirectory, isDirectory(path) {
                environments = loadEnvironments(in: path, state: &state)
            } else {
                state.index.untrackedPaths.insert(path)
                state.issues.append(ProjectLoadIssue(path: path, message: "An interrupted save left this behind, and it could not be recovered."))
            }
        }
        let count = nodes.count + environments.count
        if count > 0 {
            let items = count == 1 ? "1 item" : "\(count) items"
            state.issues.append(ProjectLoadIssue(
                path: scratch,
                message: "An interrupted save left \(items) behind; \(count == 1 ? "it was" : "they were") restored at the top level.",
                losesContent: false
            ))
        }
        return (nodes, environments)
    }
}
