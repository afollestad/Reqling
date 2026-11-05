import Foundation

/// A line-by-line diff of two texts, as an edit script from `old` to `new`.
///
/// Myers' O(ND) algorithm, after trimming the lines both share at either end, so a small change in a large body costs
/// about its own size. Lines compare as interned integers. Past `maxEditDistance` edits the search stops and the
/// untrimmed middle reads as all removed then all added: still a correct diff, only not the shortest, where the
/// shortest would take quadratic time and memory to find.
public enum LineDiff {
    public enum Edit: Hashable, Sendable {
        /// Line `old` of the old text is line `new` of the new one.
        case equal(old: Int, new: Int)
        case removed(old: Int)
        case added(new: Int)
    }

    public static let defaultMaxEditDistance = 2_000

    /// Indexes are 0-based into `old` and `new`. Throws once the current task is cancelled.
    public static func edits<Line: Hashable>(
        from old: [Line],
        to new: [Line],
        maxEditDistance: Int = defaultMaxEditDistance
    ) throws(CancellationError) -> [Edit] {
        var ids: [Line: Int] = [:]
        func intern(_ lines: [Line]) -> [Int] {
            lines.map { line in
                if let id = ids[line] {
                    return id
                }
                let id = ids.count
                ids[line] = id
                return id
            }
        }
        let interned = intern(old)
        let newIDs = intern(new)
        var prefix = 0
        while prefix < interned.count, prefix < newIDs.count, interned[prefix] == newIDs[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < interned.count - prefix, suffix < newIDs.count - prefix,
              interned[interned.count - 1 - suffix] == newIDs[newIDs.count - 1 - suffix] {
            suffix += 1
        }
        let oldMiddle = Array(interned[prefix..<(interned.count - suffix)])
        let newMiddle = Array(newIDs[prefix..<(newIDs.count - suffix)])

        var edits = (0..<prefix).map { Edit.equal(old: $0, new: $0) }
        let middle = try myers(oldMiddle, newMiddle, maxEditDistance: maxEditDistance)
            ?? oldMiddle.indices.map { Edit.removed(old: $0) } + newMiddle.indices.map { Edit.added(new: $0) }
        edits += middle.map { $0.offset(by: prefix) }
        let oldTail = interned.count - suffix
        let newTail = newIDs.count - suffix
        edits += (0..<suffix).map { Edit.equal(old: oldTail + $0, new: newTail + $0) }
        return edits
    }

    /// The shortest edit script, or `nil` once it would take more than `maxEditDistance` edits.
    private static func myers(_ old: [Int], _ new: [Int], maxEditDistance: Int) throws(CancellationError) -> [Edit]? {
        let oldCount = old.count
        let newCount = new.count
        guard oldCount > 0, newCount > 0 else {
            return old.indices.map { Edit.removed(old: $0) } + new.indices.map { Edit.added(new: $0) }
        }
        let limit = min(oldCount + newCount, maxEditDistance)
        let offset = limit + 1
        var frontier = [Int](repeating: 0, count: 2 * limit + 3)
        // Each step's frontier, diagonals -d through d, for walking the path back.
        var trace: [[Int]] = []
        for distance in 0...limit {
            if distance.isMultiple(of: 64), Task.isCancelled {
                throw CancellationError()
            }
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                var oldIndex: Int
                if diagonal == -distance || (diagonal != distance && frontier[offset + diagonal - 1] < frontier[offset + diagonal + 1]) {
                    oldIndex = frontier[offset + diagonal + 1]
                } else {
                    oldIndex = frontier[offset + diagonal - 1] + 1
                }
                var newIndex = oldIndex - diagonal
                while oldIndex < oldCount, newIndex < newCount, old[oldIndex] == new[newIndex] {
                    oldIndex += 1
                    newIndex += 1
                }
                frontier[offset + diagonal] = oldIndex
                if oldIndex >= oldCount, newIndex >= newCount {
                    trace.append(Array(frontier[(offset - distance)...(offset + distance)]))
                    return backtrack(trace, oldCount: oldCount, newCount: newCount)
                }
            }
            trace.append(Array(frontier[(offset - distance)...(offset + distance)]))
        }
        return nil
    }

    /// Walks from the end back to the start through each step's frontier, then reverses.
    private static func backtrack(_ trace: [[Int]], oldCount: Int, newCount: Int) -> [Edit] {
        var edits: [Edit] = []
        var oldIndex = oldCount
        var newIndex = newCount
        for distance in stride(from: trace.count - 1, to: 0, by: -1) {
            let previous = trace[distance - 1]
            // `previous` covers diagonals -(distance - 1) through distance - 1.
            func reach(_ diagonal: Int) -> Int {
                previous[diagonal + distance - 1]
            }
            let diagonal = oldIndex - newIndex
            let cameFrom = diagonal == -distance || (diagonal != distance && reach(diagonal - 1) < reach(diagonal + 1))
                ? diagonal + 1
                : diagonal - 1
            let startOld = reach(cameFrom)
            let startNew = startOld - cameFrom
            while oldIndex > startOld, newIndex > startNew {
                oldIndex -= 1
                newIndex -= 1
                edits.append(.equal(old: oldIndex, new: newIndex))
            }
            if oldIndex == startOld {
                newIndex -= 1
                edits.append(.added(new: newIndex))
            } else {
                oldIndex -= 1
                edits.append(.removed(old: oldIndex))
            }
        }
        while oldIndex > 0, newIndex > 0 {
            oldIndex -= 1
            newIndex -= 1
            edits.append(.equal(old: oldIndex, new: newIndex))
        }
        return edits.reversed()
    }
}

private extension LineDiff.Edit {
    func offset(by count: Int) -> Self {
        switch self {
        case .equal(let old, let new): .equal(old: old + count, new: new + count)
        case .removed(let old): .removed(old: old + count)
        case .added(let new): .added(new: new + count)
        }
    }
}
