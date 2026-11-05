/// Queries and edits on the folder/request tree. Locations are parent folder IDs, with `nil` for the project root.
extension ProjectDocument {
    public func node(_ id: RequestNodeID) -> RequestNode? {
        Self.find(id, in: items)
    }

    public func request(_ id: RequestNodeID) -> RequestItem? {
        if case .request(let request) = node(id) {
            return request
        }
        return nil
    }

    public func folder(_ id: RequestNodeID) -> RequestFolder? {
        if case .folder(let folder) = node(id) {
            return folder
        }
        return nil
    }

    /// The folders enclosing `id`, outermost first; empty for a top-level node or an unknown ID.
    public func ancestors(of id: RequestNodeID) -> [RequestFolder] {
        Self.path(to: id, in: items) ?? []
    }

    /// The parent folder's ID, or `nil` for a top-level node.
    public func parentID(of id: RequestNodeID) -> RequestNodeID? {
        ancestors(of: id).last?.id
    }

    /// The children of `parentID`, or the top-level items for `nil`.
    public func children(of parentID: RequestNodeID?) -> [RequestNode]? {
        guard let parentID else {
            return items
        }
        return folder(parentID)?.children
    }

    /// Every request in tree order, with the names of its enclosing folders.
    public var allRequests: [(request: RequestItem, folderPath: [String])] {
        var result: [(RequestItem, [String])] = []
        func visit(_ nodes: [RequestNode], path: [String]) {
            for node in nodes {
                switch node {
                case .request(let request):
                    result.append((request, path))
                case .folder(let folder):
                    visit(folder.children, path: path + [folder.name])
                }
            }
        }
        visit(items, path: [])
        return result
    }

    /// Inserts `node` into `parentID` at `index` (clamped; `nil` appends). Refuses a node with any ID, its own or a
    /// descendant's, that is already in the tree or repeats within it: saves place files by ID, so the two items would
    /// share one file and only the last written would survive.
    public mutating func insert(_ node: RequestNode, into parentID: RequestNodeID?, at index: Int? = nil) throws(ProjectTreeError) {
        let incoming = node.subtreeIDs
        guard Set(incoming).count == incoming.count, Set(items.flatMap(\.subtreeIDs)).isDisjoint(with: incoming) else {
            throw .duplicateID
        }
        try Self.modifyChildren(of: parentID, in: &items) { children in
            let position = min(max(index ?? children.count, 0), children.count)
            children.insert(node, at: position)
        }
    }

    @discardableResult
    public mutating func removeNode(_ id: RequestNodeID) throws(ProjectTreeError) -> RequestNode {
        guard let removed = Self.remove(id, from: &items) else {
            throw .notFound
        }
        return removed
    }

    /// Moves a node under `parentID` at `index` within the destination's children as they are *after* the node is
    /// lifted out. A folder cannot move into itself or its own descendants.
    public mutating func moveNode(_ id: RequestNodeID, to parentID: RequestNodeID?, at index: Int? = nil) throws(ProjectTreeError) {
        guard node(id) != nil else {
            throw .notFound
        }
        if let parentID {
            guard folder(parentID) != nil else {
                throw .notFound
            }
            if parentID == id || ancestors(of: parentID).contains(where: { $0.id == id }) {
                throw .wouldCreateCycle
            }
        }
        var copy = self
        let moved = try copy.removeNode(id)
        try copy.insert(moved, into: parentID, at: index)
        self = copy
    }

    public mutating func updateNode(_ id: RequestNodeID, _ transform: (inout RequestNode) -> Void) throws(ProjectTreeError) {
        guard Self.update(id, in: &items, transform) else {
            throw .notFound
        }
    }

    public mutating func updateRequest(_ id: RequestNodeID, _ transform: (inout RequestItem) -> Void) throws(ProjectTreeError) {
        var found = false
        try updateNode(id) { node in
            if case .request(var request) = node {
                transform(&request)
                node = .request(request)
                found = true
            }
        }
        guard found else {
            throw .notFound
        }
    }

    public mutating func updateFolder(_ id: RequestNodeID, _ transform: (inout RequestFolder) -> Void) throws(ProjectTreeError) {
        var found = false
        try updateNode(id) { node in
            if case .folder(var folder) = node {
                transform(&folder)
                node = .folder(folder)
                found = true
            }
        }
        guard found else {
            throw .notFound
        }
    }

    private static func find(_ id: RequestNodeID, in nodes: [RequestNode]) -> RequestNode? {
        for node in nodes {
            if node.id == id {
                return node
            }
            if case .folder(let folder) = node, let match = find(id, in: folder.children) {
                return match
            }
        }
        return nil
    }

    private static func path(to id: RequestNodeID, in nodes: [RequestNode]) -> [RequestFolder]? {
        for node in nodes {
            if node.id == id {
                return []
            }
            if case .folder(let folder) = node, let rest = path(to: id, in: folder.children) {
                return [folder] + rest
            }
        }
        return nil
    }

    private static func modifyChildren(
        of parentID: RequestNodeID?,
        in nodes: inout [RequestNode],
        _ transform: (inout [RequestNode]) -> Void
    ) throws(ProjectTreeError) {
        guard let parentID else {
            transform(&nodes)
            return
        }
        var found = false
        _ = update(parentID, in: &nodes) { node in
            if case .folder(var folder) = node {
                transform(&folder.children)
                node = .folder(folder)
                found = true
            }
        }
        guard found else {
            throw .notFound
        }
    }

    private static func remove(_ id: RequestNodeID, from nodes: inout [RequestNode]) -> RequestNode? {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            return nodes.remove(at: index)
        }
        for index in nodes.indices {
            if case .folder(var folder) = nodes[index], let removed = remove(id, from: &folder.children) {
                nodes[index] = .folder(folder)
                return removed
            }
        }
        return nil
    }

    private static func update(_ id: RequestNodeID, in nodes: inout [RequestNode], _ transform: (inout RequestNode) -> Void) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == id {
                transform(&nodes[index])
                return true
            }
            if case .folder(var folder) = nodes[index], update(id, in: &folder.children, transform) {
                nodes[index] = .folder(folder)
                return true
            }
        }
        return false
    }
}

public enum ProjectTreeError: Error, Equatable, Sendable {
    case notFound
    case duplicateID
    case wouldCreateCycle
}
