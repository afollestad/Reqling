import Foundation

/// Settling IDs once a whole project is read. Every ID a file states is known before any fallback is chosen, so a
/// derived ID can never repeat one already on disk, such as one an earlier save wrote into a copy made in Finder.
extension ProjectReader {
    struct ReadState {
        let projectID: ProjectID
        /// The index from the last load or save; empty on a first load.
        let previous: ProjectDiskIndex
        var index = ProjectDiskIndex()
        var issues: [ProjectLoadIssue] = []

        init(projectID: ProjectID, previous: ProjectDiskIndex) {
            self.projectID = projectID
            self.previous = previous
        }

        /// Keyed by project as well as path, so the same layout in two projects never yields the same IDs.
        func derivedID<Tag>(for path: String) -> TypedID<Tag> {
            TypedID.derived(from: "\(projectID)/\(path)")
        }

        func nodeRank(statedID: RequestNodeID?, path: String, name: String, isFolder: Bool, isListed: Bool) -> NodeRank {
            NodeRank(
                isPreviousPath: statedID.flatMap { previous.nodePaths[$0] } == path,
                isListed: isListed,
                slugRank: ProjectReader.slugRank(of: path, named: name, fallback: isFolder ? "folder" : "request")
            )
        }

        /// Records the raw bytes, and `decoded` in Reqling's encoding as the save-skip baseline. `decoded` is the value
        /// as the file states it, before the reader settles an ID or the Default's name, so such repairs are saved.
        mutating func cache(_ path: String, raw: Data, decoded: some Encodable) {
            index.diskContents[path] = raw
            index.contents[path] = (try? ProjectJSON.encode(decoded)) ?? raw
        }
    }

    /// What marks a node file as the original among files that state one ID: in order, the path that had the ID
    /// before, a name Reqling would give the item, a place in its folder's order, and the most exact slug.
    struct NodeRank {
        let isPreviousPath: Bool
        let isListed: Bool
        let slugRank: Int

        /// `isListed` counts only while every enclosing folder kept its own ID, because a copied folder's
        /// `_folder.json` lists its copied children just as the original's does.
        func preference(underReplacedFolder: Bool) -> [Int] {
            [isPreviousPath ? 0 : 1, slugRank == Int.max ? 1 : 0, isListed && !underReplacedFolder ? 0 : 1, slugRank]
        }
    }

    /// One file's claim to an ID.
    struct IDClaim<Tag> {
        let path: String
        /// The ID the file states, if any.
        let stated: TypedID<Tag>?
        /// Compared lexicographically, lower wins a contested stated ID; ties go to the claim read first.
        let preference: [Int]
    }

    struct SettledIDs<Tag> {
        var ids: [String: TypedID<Tag>] = [:]
        /// Claims that stated an ID another claim won.
        var replaced: Set<String> = []

        func id(for path: String) -> TypedID<Tag> {
            // `settle` assigns every claim; the fallback only keeps this total.
            ids[path] ?? TypedID()
        }
    }

    /// Gives each stated ID to its best claimant, and every other claim an ID derived from its path (salted with
    /// `#2`, `#3`, … while taken) that no stated ID and no earlier derivation uses.
    static func settle<Tag>(_ claims: [IDClaim<Tag>], derive: (String) -> TypedID<Tag>) -> SettledIDs<Tag> {
        var winners: [TypedID<Tag>: Int] = [:]
        for (index, claim) in claims.enumerated() {
            guard let stated = claim.stated else {
                continue
            }
            if let current = winners[stated], !claim.preference.lexicographicallyPrecedes(claims[current].preference) {
                continue
            }
            winners[stated] = index
        }
        var settled = SettledIDs<Tag>()
        var taken = Set(claims.compactMap(\.stated))
        for (index, claim) in claims.enumerated() {
            if let stated = claim.stated {
                if winners[stated] == index {
                    settled.ids[claim.path] = stated
                    continue
                }
                settled.replaced.insert(claim.path)
            }
            var candidate = derive(claim.path)
            var salt = 2
            while taken.contains(candidate) {
                candidate = derive("\(claim.path)#\(salt)")
                salt += 1
            }
            taken.insert(candidate)
            settled.ids[claim.path] = candidate
        }
        return settled
    }

    /// Whether a file states its own `id`; the model decoders fill a missing one with a random ID, which is unstable.
    struct IDProbe: Decodable {
        let id: String?
    }

    struct EnvironmentIDProbe: Decodable {
        let id: String?
        let variables: [IDProbe]?
    }
}
