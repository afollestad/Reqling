import CryptoKit
import Foundation

/// What sync remembers on this Mac, per iCloud account: for each record, digests of what it last agreed with the
/// server on (never content or secret values), and the server's opaque version; which local edits still wait to be
/// sent; and the projects it holds back.
///
/// Kept in `<directory>/<account>/state.json`, whose folder is the account's digest, so one account's bases never meet
/// another's records. The folder is readable by this user only.
@MainActor
final class SyncBaseStore {
    /// One record as last synced.
    struct Base: Codable, Equatable {
        /// `SyncDigester.fingerprint` of the payload.
        var fingerprint: String
        /// `SyncDigester.tree` of the payload, for a field-by-field merge.
        var tree: OrderedJSONCodable
        /// Each secret's digested key and value, as last synced.
        var secrets: [String: String]
        /// The server's version, opaque.
        var systemFields: Data?
    }

    struct State: Codable, Equatable {
        var bases: [String: Base] = [:]
        /// Records with an edit not yet confirmed saved, and when it was made.
        var pending: [String: Date] = [:]
        /// Projects removed from Reqling on this Mac, which a fetch must not bring back.
        var excluded: Set<ProjectID> = []
        /// Projects still in the library that stopped syncing: their zone vanished without a tombstone, or their
        /// deletion elsewhere was declined.
        var detached: Set<ProjectID> = []
        /// Projects whose records this version can't read yet, held read-only until it can.
        var deferred: Set<ProjectID> = []
        /// Projects another Mac deleted on purpose.
        var tombstones: Set<ProjectID> = []
        /// Projects deleted here whose tombstone must be saved before their zone is deleted.
        var outgoingTombstones: Set<ProjectID> = []
        /// The transport's own state (`CKSyncEngine.State.Serialization`), saved only once what it covers is applied.
        var transportState: Data?
        /// Whether some fetched change couldn't be applied, so everything must be fetched again.
        var needsRefetch = false
        /// A digest of a fixed text, to tell whether the bases were made with the key in use.
        var keyCheck: String?
    }

    let directory: URL
    let digester: SyncDigester
    private(set) var state: State
    private var isDirty = false

    /// Opens `account`'s state under `directory`, creating it empty when there's none or it can't be read.
    init(directory: URL, account: String, key: SymmetricKey) {
        self.directory = directory.appendingPathComponent(Self.folderName(for: account), isDirectory: true)
        digester = SyncDigester(key: key)
        let url = self.directory.appendingPathComponent("state.json")
        state = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        // Bases made with a lost key match nothing, which would make every field look changed here and this Mac's copy
        // win them all; without bases, a merge keeps both sides' items and takes the server's values instead.
        let check = digester.digest("key-check")
        if state.keyCheck != check {
            // Which projects are held back, and why, are IDs rather than digests, so they survive.
            state = State(
                excluded: state.excluded,
                detached: state.detached,
                tombstones: state.tombstones,
                outgoingTombstones: state.outgoingTombstones,
                keyCheck: check
            )
            isDirty = true
        }
    }

    /// The account's folder name: a hash of its identifier, so the folder doesn't name it. Unkeyed, so losing the digest
    /// key reads as the same account starting over (`State.keyCheck`) rather than as a different one.
    static func folderName(for account: String) -> String {
        SHA256.hash(data: Data(("reqling-account:" + account).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Reading

    func base(_ id: SyncRecordID) -> Base? {
        state.bases[id.description]
    }

    func baseIDs(in zone: SyncZone) -> [SyncRecordID] {
        let prefix = zone.name + "/"
        return state.bases.keys.filter { $0.hasPrefix(prefix) }.map { SyncRecordID(zone: zone, name: String($0.dropFirst(prefix.count))) }
    }

    func hasBases(in zone: SyncZone) -> Bool {
        let prefix = zone.name + "/"
        return state.bases.keys.contains { $0.hasPrefix(prefix) }
    }

    func pendingEdit(_ id: SyncRecordID) -> Date? {
        state.pending[id.description]
    }

    // MARK: - Writing

    func update(_ body: (inout State) -> Void) {
        let before = state
        body(&state)
        isDirty = isDirty || state != before
    }

    /// Records `record` as what this Mac and the server now agree on.
    func setBase(from record: SyncRecord, keepingSecretsIfUnsent: Bool = true) {
        let previous = base(record.id)
        let secrets = record.secrets.map(secretDigests) ?? (keepingSecretsIfUnsent ? previous?.secrets ?? [:] : [:])
        update {
            $0.bases[record.id.description] = Base(
                fingerprint: digester.fingerprint(record.payload),
                tree: OrderedJSONCodable(digester.tree(record.payload)),
                secrets: secrets,
                systemFields: record.systemFields ?? previous?.systemFields
            )
        }
    }

    func removeBase(_ id: SyncRecordID) {
        update { $0.bases[id.description] = nil }
    }

    /// Drops everything kept for `zone`'s records.
    func forget(_ zone: SyncZone) {
        let prefix = zone.name + "/"
        update { state in
            state.bases = state.bases.filter { !$0.key.hasPrefix(prefix) }
            state.pending = state.pending.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    func setPending(_ id: SyncRecordID, at date: Date?) {
        update { $0.pending[id.description] = date }
    }

    func secretDigests(_ secrets: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: secrets.map { (digester.digest("secret-key:" + $0.key), digester.digest("secret:" + $0.value)) })
    }

    /// Writes the state if it changed, readable by this user only.
    func save() {
        guard isDirty else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("state.json")
            try JSONEncoder().encode(state).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            isDirty = false
        } catch {
            // Losing this costs a slower next sync (no base merges as a union), never data.
        }
    }

    /// Deletes this account's state, as after its data was deleted from iCloud.
    func reset() {
        state = State()
        isDirty = false
        try? FileManager.default.removeItem(at: directory)
    }
}

/// `OrderedJSON` stored as its JSON text.
struct OrderedJSONCodable: Codable, Equatable {
    let json: OrderedJSON

    init(_ json: OrderedJSON) {
        self.json = json
    }

    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        json = try OrderedJSONParser.parse(text)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(json.prettyPrinted())
    }
}
