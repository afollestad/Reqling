import Foundation
internal import ReqlingYAML

/// A request as planned, with the auth its operation's security maps to, before `placeAuth` decides whether it
/// inherits that auth or keeps its own.
struct OpenAPIPlannedRequest {
    var item: RequestItem
    var auth: HTTPAuth
}

/// The folders the requests go in, one per tag with operations beneath it, nested by 3.2's tag `parent`.
struct OpenAPIFolderTree {
    var name: String
    var auth: HTTPAuth = .inherit
    var folders: [OpenAPIFolderTree] = []
    var requests: [OpenAPIPlannedRequest] = []

    /// The folder at `path`, made where missing, after the folders already there.
    mutating func ensureFolder(_ path: ArraySlice<String>) {
        guard let name = path.first else {
            return
        }
        if let index = folders.firstIndex(where: { $0.name == name }) {
            folders[index].ensureFolder(path.dropFirst())
        } else {
            var folder = OpenAPIFolderTree(name: name)
            folder.ensureFolder(path.dropFirst())
            folders.append(folder)
        }
    }

    /// Puts the request in the folder at `path`, made where missing, so a request never goes missing with its folder.
    mutating func insert(_ request: OpenAPIPlannedRequest, at path: ArraySlice<String>) {
        guard let name = path.first else {
            requests.append(request)
            return
        }
        if !folders.contains(where: { $0.name == name }) {
            folders.append(OpenAPIFolderTree(name: name))
        }
        if let index = folders.firstIndex(where: { $0.name == name }) {
            folders[index].insert(request, at: path.dropFirst())
        }
    }

    /// The project's items: each folder, then the requests at this level.
    func nodes(counting counts: inout ImportCounts) -> [RequestNode] {
        var nodes: [RequestNode] = []
        for folder in folders {
            counts.folders += 1
            nodes.append(.folder(RequestFolder(name: folder.name, auth: folder.auth, children: folder.nodes(counting: &counts))))
        }
        return nodes + requests.map { .request($0.item) }
    }
}

/// Tags as folders: an operation goes in its first tag's folder, skipping 3.2 tags whose `kind` isn't navigation.
/// Folders follow the document's `tags` list, then the order operations first use a tag it doesn't list; untagged
/// operations sit at the project's root, after the folders.
extension OpenAPIPlanner {
    mutating func folderTree(for operations: [OpenAPIOperation]) -> OpenAPIFolderTree {
        let definitions = root["tags"]?.elements ?? []
        var order = definitions.compactMap { $0["name"]?.value.string }
        let hidden = Set(definitions.filter { ($0["kind"]?.value.string ?? "nav") != "nav" }.compactMap { $0["name"]?.value.string })
        var multiTagged = 0
        let assigned: [(operation: OpenAPIOperation, tag: String?)] = operations.map { operation in
            let tags = (operation.node["tags"]?.value.array ?? []).compactMap(\.string)
            if tags.count > 1 {
                multiTagged += 1
            }
            let tag = tags.first { !hidden.contains($0) }
            if let tag, !order.contains(tag) {
                order.append(tag)
            }
            return (operation, tag)
        }
        if multiTagged > 0 {
            let operations = multiTagged == 1 ? "1 operation has" : "\(multiTagged) operations have"
            note(.project, .operation, "\(operations) more than one tag; each is in its first tag's folder only.")
        }
        let parents = tagParents(definitions, known: Set(order))
        func path(_ tag: String) -> [String] {
            var path = [tag]
            while let parent = parents[path[0]] {
                path.insert(parent, at: 0)
            }
            return path
        }
        let used = Set(assigned.compactMap(\.tag).flatMap(path))
        var tree = OpenAPIFolderTree(name: "")
        for tag in order where used.contains(tag) {
            tree.ensureFolder(path(tag)[...])
        }
        for (operation, tag) in assigned {
            let folder = tag.map(path) ?? []
            tree.insert(request(for: operation, in: folder), at: folder[...])
        }
        return tree
    }

    /// Each tag's 3.2 `parent`, where it names a tag and makes no cycle; a folder whose parent doesn't sits at the top
    /// level, with a note.
    private mutating func tagParents(_ definitions: [OpenAPINode], known: Set<String>) -> [String: String] {
        var parents: [String: String] = [:]
        for definition in definitions {
            guard let name = definition["name"]?.value.string, let parent = definition["parent"]?.value.string else {
                continue
            }
            guard known.contains(parent) else {
                note(.project, .operation, "The tag “\(name)” names “\(parent)” as its parent, which isn't a tag, so its folder is at the top.")
                continue
            }
            var ancestor: String? = parent
            while let current = ancestor, current != name {
                ancestor = parents[current]
            }
            guard ancestor == nil else {
                note(.project, .operation, "The tag “\(name)” is its own ancestor, so its folder is at the top.")
                continue
            }
            parents[name] = parent
        }
        return parents
    }
}
