/// A row of an editable list stored in a request file: query parameters, headers, form fields, and gRPC metadata.
///
/// Each row carries an ID, unique within its list and stored with it, so a merge can tell a row the draft edited
/// from one changed elsewhere (`ListMerge`), and a table keeps focus on the right row. Rows built in memory get a
/// random ID. A row stored without one gets an ID derived from where it sits in its file, so reading the same bytes
/// twice yields equal documents: `ProjectDocument` compares by content, and a random ID would make every reload of
/// an older file look like an external edit.
///
/// Anything that rebuilds a list (from text, as `HTTPRequestSpec.applyDisplayURL` does, or from an agent's input) must
/// hand surviving rows their old IDs (`carryingIDs(into:reserving:name:)`), or every edit would read as a removal
/// plus an addition, and a merge would drop or duplicate the rows changed elsewhere meanwhile.
public protocol ListRow: Identifiable, Hashable, Sendable where ID == TypedID<IDTag> {
    associatedtype IDTag
    var id: ID { get set }
}

extension ListRow {
    /// Whether the rows hold the same content, whatever their IDs.
    func hasSameContent(as other: Self) -> Bool {
        var other = other
        other.id = id
        return self == other
    }

    /// The ID of a row stored without a usable one, derived from its coding path (`http/headers/2`).
    static func derivedID(at codingPath: [any CodingKey]) -> ID {
        .derived(from: rowPath(codingPath))
    }

    static func rowPath(_ codingPath: [any CodingKey]) -> String {
        codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: "/")
    }
}

extension Array where Element: ListRow {
    /// Gives the rows at `indices` IDs derived from `name(index, row)`, salted (`#2`, `#3`, …) past every ID another
    /// row of the list, or `reserved`, holds. Deterministic, so rebuilding the same list from the same text yields
    /// equal rows. Callers name rows by position and content, so rows two sides derived independently share an ID
    /// only when they are the same row, never by sitting at the same index.
    mutating func deriveIDs(
        at indices: some Sequence<Int>,
        reserving reserved: Set<Element.ID> = [],
        name: (_ index: Int, _ row: Element) -> String
    ) {
        let indices = Set(indices)
        var taken = reserved.union(enumerated().filter { !indices.contains($0.offset) }.map(\.element.id))
        for index in indices.sorted() {
            let base = name(index, self[index])
            var candidate = Element.ID.derived(from: base)
            var salt = 2
            while taken.contains(candidate) {
                candidate = .derived(from: "\(base)#\(salt)")
                salt += 1
            }
            taken.insert(candidate)
            self[index].id = candidate
        }
    }

    /// `rebuilt` with each row that corresponds to one of these rows taking that row's ID, and every other row one
    /// from `deriveIDs` that neither the list nor `reserved` holds.
    ///
    /// Rows equal in content correspond in order (their longest common subsequence, after any shared prefix and
    /// suffix); between two such pairs, leftover rows correspond by position, as an edit in place leaves them. So
    /// typing into one row, inserting a row, or deleting one keeps every other row's ID.
    func carryingIDs(
        into rebuilt: [Element],
        reserving reserved: Set<Element.ID> = [],
        name: (_ index: Int, _ row: Element) -> String
    ) -> [Element] {
        var result = rebuilt
        var unmatched = Set(rebuilt.indices)
        for (new, old) in Self.correspondence(from: self, to: rebuilt) {
            result[new].id = self[old].id
            unmatched.remove(new)
        }
        result.deriveIDs(at: unmatched, reserving: reserved, name: name)
        return result
    }

    /// Pairs of (`new` index, `old` index); see `carryingIDs(into:reserving:name:)`.
    private static func correspondence(from old: [Element], to new: [Element]) -> [(Int, Int)] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix].hasSameContent(as: new[prefix]) {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix].hasSameContent(as: new[new.count - 1 - suffix]) {
            suffix += 1
        }
        let oldMiddle = prefix..<(old.count - suffix)
        let newMiddle = prefix..<(new.count - suffix)
        var anchors = (0..<prefix).map { ($0, $0) }
        anchors += commonSubsequence(Array(old[oldMiddle]), Array(new[newMiddle])).map { ($0 + prefix, $1 + prefix) }
        anchors += (0..<suffix).map { (old.count - suffix + $0, new.count - suffix + $0) }

        var pairs: [(Int, Int)] = []
        var previous = (old: -1, new: -1)
        for anchor in anchors + [(old.count, new.count)] {
            let gap = Swift.min(anchor.0 - previous.old - 1, anchor.1 - previous.new - 1)
            for offset in 0..<Swift.max(gap, 0) {
                pairs.append((previous.new + 1 + offset, previous.old + 1 + offset))
            }
            if anchor.0 < old.count {
                pairs.append((anchor.1, anchor.0))
            }
            previous = (old: anchor.0, new: anchor.1)
        }
        return pairs
    }

    /// The longest common subsequence of rows equal in content, as increasing (`old`, `new`) index pairs. Past
    /// `maximumCells` it finds none and every row pairs by position: a paste that replaces hundreds of rows is not
    /// worth a quadratic table on every keystroke.
    private static func commonSubsequence(_ old: [Element], _ new: [Element]) -> [(Int, Int)] {
        let maximumCells = 65_536
        guard !old.isEmpty, !new.isEmpty, old.count * new.count <= maximumCells else {
            return []
        }
        let width = new.count + 1
        var lengths = [Int](repeating: 0, count: (old.count + 1) * width)
        for oldIndex in stride(from: old.count - 1, through: 0, by: -1) {
            for newIndex in stride(from: new.count - 1, through: 0, by: -1) {
                lengths[oldIndex * width + newIndex] = old[oldIndex].hasSameContent(as: new[newIndex])
                    ? lengths[(oldIndex + 1) * width + newIndex + 1] + 1
                    : Swift.max(lengths[(oldIndex + 1) * width + newIndex], lengths[oldIndex * width + newIndex + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count, newIndex < new.count {
            if old[oldIndex].hasSameContent(as: new[newIndex]) {
                pairs.append((oldIndex, newIndex))
                oldIndex += 1
                newIndex += 1
            } else if lengths[(oldIndex + 1) * width + newIndex] >= lengths[oldIndex * width + newIndex + 1] {
                oldIndex += 1
            } else {
                newIndex += 1
            }
        }
        return pairs
    }
}

extension KeyedDecodingContainer {
    /// Decodes a list of rows whose IDs are unique: a row that states no usable ID, or repeats one an earlier row
    /// states (a row copied and pasted in a hand-edited file), gets one derived from its position, salted past every
    /// ID the list states. Stated IDs are collected first, so a derived ID never takes one a later row states.
    func decodeRowsIfPresent<Row: ListRow & Decodable>(_ type: [Row].Type, forKey key: Key) throws -> [Row]? {
        guard let entries = try decodeIfPresent([StatedRow<Row>].self, forKey: key) else {
            return nil
        }
        let listPath = Row.rowPath(codingPath + [key as any CodingKey])
        var taken = Set(entries.compactMap(\.statedID))
        var claimed: Set<Row.ID> = []
        return entries.enumerated().map { index, entry in
            var row = entry.row
            if let stated = entry.statedID, claimed.insert(stated).inserted {
                row.id = stated
                return row
            }
            let name = "\(listPath)/\(index)"
            var candidate = Row.ID.derived(from: name)
            var salt = 2
            while taken.contains(candidate) {
                candidate = .derived(from: "\(name)#\(salt)")
                salt += 1
            }
            taken.insert(candidate)
            row.id = candidate
            return row
        }
    }
}

/// A decoded row plus the ID its entry states, if a usable one: the row's own decoder fills a missing ID in, which
/// would hide a repeat from `decodeRowsIfPresent`.
private struct StatedRow<Row: ListRow & Decodable>: Decodable {
    let row: Row
    let statedID: Row.ID?

    init(from decoder: any Decoder) throws {
        row = try Row(from: decoder)
        statedID = try? decoder.container(keyedBy: RowIDKey.self).decodeIfPresent(Row.ID.self, forKey: .id)
    }
}

private enum RowIDKey: String, CodingKey {
    case id
}
