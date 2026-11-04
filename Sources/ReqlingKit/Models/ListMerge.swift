/// The three-way merge of one list whose rows carry IDs, for a draft saved over a version that changed since the
/// draft was loaded: request editors merge their rows (`ListRow`), and the Environments and Project Settings sheets
/// their environments, variables, and client certificates.
public enum ListMerge {
    /// Merges `draft` (edited from `base`) with `stored` (changed from `base` elsewhere, such as by an agent or a
    /// `git pull`), row by row by ID:
    ///
    /// - A row the draft edited (`isEdited`) keeps the draft's version, combined with the stored one by `mergeEdited`
    ///   when that still exists; an edit beats a removal elsewhere.
    /// - A row the draft left alone takes the stored version, its removal included.
    /// - A row the draft removed stays removed; a row only one side added is kept, the draft's when both added it.
    ///
    /// Order follows the draft when it moved rows it shares with `base`, otherwise `stored`, so a reorder on either side
    /// survives. Rows only the other side has go right after their nearest preceding row from that side, or first when
    /// none precedes them.
    ///
    /// IDs are unique within a list (`KeyedDecodingContainer.decodeRowsIfPresent` settles repeats). Should any list
    /// still repeat one, rows cannot be told apart, so the whole list is one field: the draft's if edited, else stored.
    public static func merge<Row: Identifiable & Equatable>(
        base: [Row],
        draft: [Row],
        stored: [Row],
        isEdited: (_ base: Row, _ draft: Row) -> Bool = { $0 != $1 },
        mergeEdited: (_ base: Row, _ draft: Row, _ stored: Row) -> Row = { _, draft, _ in draft }
    ) -> [Row] {
        guard stored != base else {
            return draft
        }
        guard let baseRows = rowsByID(base), let draftRows = rowsByID(draft), let storedRows = rowsByID(stored) else {
            let isDraftEdited = base.map(\.id) != draft.map(\.id) || zip(base, draft).contains { isEdited($0, $1) }
            return isDraftEdited ? draft : stored
        }

        var merged: [Row.ID: Row] = [:]
        for id in Set(baseRows.keys).union(draftRows.keys).union(storedRows.keys) {
            switch (baseRows[id], draftRows[id], storedRows[id]) {
            case let (base?, draft?, stored):
                if !isEdited(base, draft) {
                    merged[id] = stored
                } else {
                    merged[id] = stored.map { mergeEdited(base, draft, $0) } ?? draft
                }
            case (_?, nil, _):
                break
            case let (nil, draft?, _):
                merged[id] = draft
            case let (nil, nil, stored):
                merged[id] = stored
            }
        }

        let shared = Set(baseRows.keys).intersection(draftRows.keys)
        let draftMoved = draft.map(\.id).filter(shared.contains) != base.map(\.id).filter(shared.contains)
        let (primary, secondary) = draftMoved ? (draft, stored) : (stored, draft)

        var order = primary.map(\.id).filter { merged[$0] != nil }
        var placed = Set(order)
        for (index, row) in secondary.enumerated() where merged[row.id] != nil && !placed.contains(row.id) {
            let predecessor = secondary[..<index].reversed().lazy.compactMap { order.firstIndex(of: $0.id) }.first
            order.insert(row.id, at: predecessor.map { $0 + 1 } ?? 0)
            placed.insert(row.id)
        }
        return order.compactMap { merged[$0] }
    }

    /// The rows keyed by ID, or `nil` when an ID repeats.
    private static func rowsByID<Row: Identifiable>(_ rows: [Row]) -> [Row.ID: Row]? {
        var result: [Row.ID: Row] = [:]
        for row in rows where result.updateValue(row, forKey: row.id) != nil {
            return nil
        }
        return result
    }
}
