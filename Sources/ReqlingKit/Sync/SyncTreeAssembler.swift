import Foundation

/// Builds a project's folder tree from records that each name only their parent. Two Macs' edits can leave an item
/// whose folder is gone, or two folders each inside the other; the repairs here are deterministic, so every Mac that
/// applies the same records builds the same tree, and uploading a repair converges rather than flipping back and forth.
struct SyncTreeAssembler {
    /// Each folder's parent (`nil` for the top level) and its children's order.
    var folders: [RequestNodeID: (parent: RequestNodeID?, order: [RequestNodeID])]
    /// Each request's parent.
    var requests: [RequestNodeID: RequestNodeID?]
    var rootOrder: [RequestNodeID]

    /// The top-level nodes, built bottom-up by `make` from each ID and its built children.
    ///
    /// An item whose parent isn't a folder here moves to the top level. A folder that can't reach the top level is in a
    /// cycle, which is broken by moving its lowest-ID folder there. Nesting deeper than `maxDepth` is refused.
    mutating func assemble(
        maxDepth: Int,
        make: (RequestNodeID, [RequestNode]) -> RequestNode?
    ) throws -> [RequestNode] {
        repairParents()
        var children: [RequestNodeID?: [RequestNodeID]] = [:]
        for (id, folder) in folders {
            children[folder.parent, default: []].append(id)
        }
        for (id, parent) in requests {
            children[parent, default: []].append(id)
        }
        func build(_ parent: RequestNodeID?, depth: Int) throws -> [RequestNode] {
            guard depth <= maxDepth else {
                throw SyncRecordError.tooDeep
            }
            let order = parent.map { folders[$0]?.order ?? [] } ?? rootOrder
            return try ProjectRecordCoder.ordered(children[parent] ?? [], by: order).compactMap { id in
                var nested: [RequestNode] = []
                if folders[id] != nil {
                    nested = try build(id, depth: depth + 1)
                }
                return make(id, nested)
            }
        }
        return try build(nil, depth: 0)
    }

    /// Points every parent at a folder that exists and leads to the top level.
    private mutating func repairParents() {
        for (id, parent) in requests where parent.map({ folders[$0] == nil }) ?? false {
            requests[id] = .some(nil)
        }
        for (id, folder) in folders where folder.parent.map({ folders[$0] == nil }) ?? false {
            folders[id]?.parent = nil
        }
        // Each pass moves one folder of one cycle, then looks again: a chain hanging off a cycle reaches the top once
        // the cycle is broken.
        while let stranded = strandedFolders().min(by: { $0.description < $1.description }) {
            let cycle = cycle(from: stranded)
            if let lowest = cycle.min(by: { $0.description < $1.description }) {
                folders[lowest]?.parent = nil
            }
        }
    }

    /// Folders whose chain of parents never reaches the top level.
    private func strandedFolders() -> [RequestNodeID] {
        var reaches: [RequestNodeID: Bool] = [:]
        func reachesTop(_ id: RequestNodeID, visiting: inout Set<RequestNodeID>) -> Bool {
            if let known = reaches[id] {
                return known
            }
            guard visiting.insert(id).inserted, let folder = folders[id] else {
                return false
            }
            let result = folder.parent.map { reachesTop($0, visiting: &visiting) } ?? true
            reaches[id] = result
            return result
        }
        return folders.keys.filter { id in
            var visiting: Set<RequestNodeID> = []
            return !reachesTop(id, visiting: &visiting)
        }
    }

    /// The folders of the cycle `start`'s chain of parents runs into.
    private func cycle(from start: RequestNodeID) -> [RequestNodeID] {
        var path: [RequestNodeID] = []
        var current: RequestNodeID? = start
        while let id = current {
            if let index = path.firstIndex(of: id) {
                return Array(path[index...])
            }
            path.append(id)
            current = folders[id]?.parent
        }
        return []
    }
}
