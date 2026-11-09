import CryptoKit
import Foundation

/// Keyed digests of JSON, the only form in which sync keeps what it last synced (`SyncBaseStore`): a three-way merge
/// needs to know which side changed a field, never what the field held, so no content or secret reaches the disk.
///
/// A digest tree has the JSON's shape: each object member's key and value digested, each list's rows by their digested
/// identity, and every other value one digest. The key lives in the Keychain (`SecretAccount.sync`), so the digests
/// can't be tested against guesses; two Macs' digests never meet, so each Mac keeps its own key.
struct SyncDigester: Sendable {
    let key: SymmetricKey

    /// A new random key, stored as base64 in the Keychain.
    static func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    func digest(_ text: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)
        return code.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The whole value as one digest, for telling quickly whether a record changed at all.
    func fingerprint(_ json: OrderedJSON) -> String {
        digest("record:" + json.prettyPrinted())
    }

    /// `json`'s digest tree.
    func tree(_ json: OrderedJSON) -> OrderedJSON {
        switch json {
        case .object(let members):
            return .object(members.map { OrderedJSONMember(key: digest("key:" + $0.key), value: tree($0.value)) }
                .sorted { $0.key < $1.key })
        case .array(let items):
            guard let identities = SyncJSONMerge.identities(of: items) else {
                return .string(digest("value:" + json.prettyPrinted()))
            }
            return .array(zip(identities, items).map { identity, item in
                .object([
                    OrderedJSONMember(key: "i", value: .string(digest("id:" + identity))),
                    OrderedJSONMember(key: "v", value: tree(item))
                ])
            })
        case .null, .bool, .number, .string:
            return .string(digest("value:" + json.prettyPrinted()))
        }
    }
}

/// The three-way merge of one record's payload: what this Mac has, what the server has, and the digest tree of what
/// they last agreed on.
///
/// - Objects merge member by member, and lists (arrays whose rows carry unique `id`s, or unique plain values) row by
///   row, so edits to different fields or rows both survive. An edit on either side beats a removal on the other.
/// - A value both sides changed takes the side that edited later (`localIsNewer`), as does the order of a list both
///   reordered.
/// - With no base (both Macs had the project before it ever synced), what only one side has is kept and a value that
///   differs takes the server's.
struct SyncJSONMerge {
    let digester: SyncDigester
    let localIsNewer: Bool

    func merge(base: OrderedJSON?, local: OrderedJSON, remote: OrderedJSON) -> OrderedJSON {
        merge(base, local, remote, hasBase: base != nil) ?? remote
    }

    /// `nil` means absent: a member or row one side removed, or that the base never had.
    private func merge(_ base: OrderedJSON?, _ local: OrderedJSON?, _ remote: OrderedJSON?, hasBase: Bool) -> OrderedJSON? {
        if local == remote {
            return local
        }
        guard let local, let remote else {
            guard hasBase else {
                return local ?? remote
            }
            // One side removed it: the removal stands only if the other side left it as it was.
            let kept = local ?? remote
            return kept.map(digester.tree) == base ? nil : kept
        }
        if hasBase {
            let localChanged = digester.tree(local) != base
            let remoteChanged = digester.tree(remote) != base
            if !localChanged {
                return remote
            }
            if !remoteChanged {
                return local
            }
        }
        switch (local, remote) {
        case (.object(let localMembers), .object(let remoteMembers)):
            return .object(mergeMembers(base, localMembers, remoteMembers, hasBase: hasBase))
        case (.array(let localItems), .array(let remoteItems)):
            if let rows = mergeRows(base, localItems, remoteItems, hasBase: hasBase) {
                return .array(rows)
            }
        default:
            break
        }
        return hasBase && localIsNewer ? local : remote
    }

    private func mergeMembers(
        _ base: OrderedJSON?,
        _ local: [OrderedJSONMember],
        _ remote: [OrderedJSONMember],
        hasBase: Bool
    ) -> [OrderedJSONMember] {
        var baseMembers: [String: OrderedJSON] = [:]
        if case .object(let members)? = base {
            for member in members {
                baseMembers[member.key] = member.value
            }
        }
        let localValues = Dictionary(local.map { ($0.key, $0.value) }) { first, _ in first }
        let remoteValues = Dictionary(remote.map { ($0.key, $0.value) }) { first, _ in first }
        return Set(localValues.keys).union(remoteValues.keys).sorted().compactMap { key in
            let baseValue = baseMembers[digester.digest("key:" + key)]
            return merge(baseValue, localValues[key], remoteValues[key], hasBase: hasBase).map { OrderedJSONMember(key: key, value: $0) }
        }
    }

    /// `nil` when either side isn't a list, which then merges as one value.
    private func mergeRows(_ base: OrderedJSON?, _ local: [OrderedJSON], _ remote: [OrderedJSON], hasBase: Bool) -> [OrderedJSON]? {
        guard let localIDs = Self.identities(of: local), let remoteIDs = Self.identities(of: remote) else {
            return nil
        }
        var baseRows: [String: OrderedJSON] = [:]
        var baseOrder: [String] = []
        if case .array(let entries)? = base {
            for case .object(let members) in entries {
                guard case .string(let identity)? = members.first(where: { $0.key == "i" })?.value else {
                    continue
                }
                baseRows[identity] = members.first { $0.key == "v" }?.value
                baseOrder.append(identity)
            }
        } else if base != nil {
            // The base held this as one value, so it can't say which rows changed. A list the base lacks entirely (an
            // empty one the encoder leaves out) merges as an empty list, so both sides' first rows survive.
            return nil
        }
        let localRows = Dictionary(uniqueKeysWithValues: zip(localIDs, local))
        let remoteRows = Dictionary(uniqueKeysWithValues: zip(remoteIDs, remote))
        var merged: [String: OrderedJSON] = [:]
        for id in Set(localIDs).union(remoteIDs) {
            let baseRow = baseRows[digester.digest("id:" + id)]
            if let row = merge(baseRow, localRows[id], remoteRows[id], hasBase: hasBase) {
                merged[id] = row
            }
        }
        let primary = primaryOrder(local: localIDs, remote: remoteIDs, baseOrder: baseOrder, hasBase: hasBase)
        let secondary = primary == localIDs ? remoteIDs : localIDs
        var order = primary.filter { merged[$0] != nil }
        var placed = Set(order)
        for (index, id) in secondary.enumerated() where merged[id] != nil && !placed.contains(id) {
            let predecessor = secondary[..<index].reversed().lazy.compactMap { order.firstIndex(of: $0) }.first
            order.insert(id, at: predecessor.map { $0 + 1 } ?? 0)
            placed.insert(id)
        }
        return order.compactMap { merged[$0] }
    }

    /// The side whose order the merged list follows: the one that reordered the rows it shares with the base, or the
    /// later editor when both did; the server's when neither did.
    private func primaryOrder(local: [String], remote: [String], baseOrder: [String], hasBase: Bool) -> [String] {
        guard hasBase else {
            return remote
        }
        func reordered(_ ids: [String]) -> Bool {
            let digested = ids.map { digester.digest("id:" + $0) }
            let shared = Set(digested).intersection(baseOrder)
            return digested.filter(shared.contains) != baseOrder.filter(shared.contains)
        }
        let localMoved = reordered(local)
        let remoteMoved = reordered(remote)
        return localMoved && (!remoteMoved || localIsNewer) ? local : remote
    }

    /// Each row's identity when `items` is a list: every row an object with a unique string `id`, or every row a unique
    /// plain value. `nil` otherwise.
    static func identities(of items: [OrderedJSON]) -> [String]? {
        var identities: [String] = []
        for item in items {
            switch item {
            case .object(let members):
                guard case .string(let id)? = members.first(where: { $0.key == "id" })?.value else {
                    return nil
                }
                identities.append("row:" + id)
            case .string, .number, .bool:
                identities.append("value:" + item.prettyPrinted())
            case .null, .array:
                return nil
            }
        }
        let rows = identities.filter { $0.hasPrefix("row:") }.count
        guard rows == 0 || rows == identities.count, Set(identities).count == identities.count else {
            return nil
        }
        return identities
    }
}
