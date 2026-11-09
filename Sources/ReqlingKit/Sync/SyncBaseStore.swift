import CryptoKit
import Foundation

/// What sync remembers on this Mac, per iCloud account: for each record, digests of what it last agreed with the
/// server on (never content or secret values), and the server's opaque version; which local edits still wait to be
/// sent; and the projects it holds back.
///
/// Kept in `<directory>/<account>/state.json`, whose folder is the account's digest, so one account's bases never meet
/// another's records. The folder is readable by this user only. The person's choices are also kept apart in
/// `choices.json`, written only when they change, so a damaged `state.json` can't bring back a project kept out.
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

    /// An edit not yet confirmed saved: when it was made, and a digest of what it holds, so reconciling an unchanged
    /// edit again keeps its time rather than making it look newer than an edit another Mac made since.
    struct Pending: Codable, Equatable {
        var editedAt: Date
        /// `SyncDigester.fingerprint` of the record queued, or `nil` for a deletion.
        var fingerprint: String?

        var isDeletion: Bool {
            fingerprint == nil
        }
    }

    struct State: Codable, Equatable {
        var bases: [String: Base] = [:]
        var pending: [String: Pending] = [:]
        /// Projects removed from Reqling on this Mac, which a fetch must not bring back.
        var excluded: Set<ProjectID> = []
        /// Projects still in the library that stopped syncing: their zone vanished without a tombstone, their deletion
        /// elsewhere was declined, or they were kept out of a new account.
        var detached: Set<ProjectID> = []
        /// Whether Global and its current values were kept out of a new account.
        var libraryDetached = false
        /// Projects whose records this version can't read yet, held back until a refetch after an update.
        var deferred: Set<ProjectID> = []
        /// Whether a Global record this version can't read was skipped, likewise.
        var libraryDeferred = false
        /// `SyncBaseStore.versions` when something was last deferred, so only an update fetches it all again.
        var deferredAt: String?
        /// Projects whose fetched changes were skipped while a file of theirs couldn't be read here, to fetch again once
        /// it can: what the copy here lacked would otherwise have read as deleted.
        var unreadProjects: Set<ProjectID> = []
        /// Projects another Mac deleted on purpose.
        var tombstones: Set<ProjectID> = []
        /// Projects deleted here whose tombstone must be saved before their zone is deleted.
        var outgoingTombstones: Set<ProjectID> = []
        /// Projects whose tombstone is saved and whose zone still has to be deleted.
        var outgoingZoneDeletions: Set<ProjectID> = []
        /// Projects another Mac deleted several at once, waiting for the person to confirm.
        var awaitingConfirmation: [ProjectID] = []
        /// Records iCloud refused as too large, by the fingerprint refused, so the same content isn't sent again.
        var tooLarge: [String: String] = [:]
        /// The transport's own state (`CKSyncEngine.State.Serialization`), saved only once what it covers is applied.
        var transportState: Data?
        /// Whether some fetched change couldn't be applied, so everything must be fetched again; cleared only once a whole
        /// fetch is applied.
        var needsRefetch = false
        /// How far this Mac's clock runs ahead of the server's, as the latest save measured it, so a merge weighs this
        /// Mac's edit times on the server's clock, as the server caps another Mac's (`SyncRecord.trustedEditedAt`).
        var clockSkew: TimeInterval = 0
        /// A digest of a fixed text, to tell whether the bases were made with the key in use.
        var keyCheck: String?

        init() {}

        /// Each field on its own, so damage to one, such as the bases, doesn't lose which projects are held back.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
            }
            bases = field(.bases, [:])
            pending = field(.pending, [:])
            excluded = field(.excluded, [])
            detached = field(.detached, [])
            libraryDetached = field(.libraryDetached, false)
            deferred = field(.deferred, [])
            libraryDeferred = field(.libraryDeferred, false)
            deferredAt = field(.deferredAt, nil)
            unreadProjects = field(.unreadProjects, [])
            tombstones = field(.tombstones, [])
            outgoingTombstones = field(.outgoingTombstones, [])
            outgoingZoneDeletions = field(.outgoingZoneDeletions, [])
            awaitingConfirmation = field(.awaitingConfirmation, [])
            tooLarge = field(.tooLarge, [:])
            transportState = field(.transportState, nil)
            needsRefetch = field(.needsRefetch, false)
            clockSkew = field(.clockSkew, 0)
            keyCheck = field(.keyCheck, nil)
        }

        /// Takes every field `choices` keeps from it.
        mutating func adopt(_ choices: State) {
            excluded = choices.excluded
            detached = choices.detached
            libraryDetached = choices.libraryDetached
            tombstones = choices.tombstones
            outgoingTombstones = choices.outgoingTombstones
            outgoingZoneDeletions = choices.outgoingZoneDeletions
            awaitingConfirmation = choices.awaitingConfirmation
        }

        /// The person's choices and promises still to keep, without anything a lost key or a damaged file invalidates.
        var choices: State {
            var kept = State()
            kept.excluded = excluded
            kept.detached = detached
            kept.libraryDetached = libraryDetached
            kept.tombstones = tombstones
            kept.outgoingTombstones = outgoingTombstones
            kept.outgoingZoneDeletions = outgoingZoneDeletions
            kept.awaitingConfirmation = awaitingConfirmation
            return kept
        }
    }

    let directory: URL
    let digester: SyncDigester
    private(set) var state: State
    private var isDirty = false
    /// The choices `choices.json` holds.
    private var savedChoices: State?

    /// This version's project format and sync schema, which a record must not exceed to be read.
    static let versions = "\(ProjectDocument.currentFormatVersion).\(ProjectRecordCoder.schemaVersion)"

    /// Opens `account`'s state under `directory`: empty when there's none, and only the person's choices when it can't be
    /// read, after setting the damaged file aside.
    init(directory: URL, account: String, key: SymmetricKey) {
        self.directory = directory.appendingPathComponent(Self.folderName(for: account), isDirectory: true)
        digester = SyncDigester(key: key)
        let url = self.directory.appendingPathComponent("state.json")
        let choices = (try? Data(contentsOf: self.directory.appendingPathComponent("choices.json")))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) }
        savedChoices = choices?.choices
        if let data = try? Data(contentsOf: url) {
            if var decoded = try? JSONDecoder().decode(State.self, from: data) {
                // The choices file is written first and decoded on its own, so it holds the choices last made.
                if let choices {
                    decoded.adopt(choices.choices)
                }
                state = decoded
            } else {
                UndecodableFileBackup.preserve(url)
                state = choices?.choices ?? State()
                isDirty = true
            }
        } else {
            state = choices?.choices ?? State()
        }
        // Bases made with a lost key match nothing, which would make every field look changed here and this Mac's copy
        // win them all; without bases, a merge keeps both sides' items and takes the server's values instead.
        let check = digester.digest("key-check")
        if state.keyCheck != check {
            state = state.choices
            state.keyCheck = check
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

    /// Every zone with a record synced here.
    var syncedZones: Set<SyncZone> {
        Set(state.bases.keys.compactMap { $0.split(separator: "/").first.flatMap { SyncZone(name: String($0)) } })
    }

    func hasBases(in zone: SyncZone) -> Bool {
        let prefix = zone.name + "/"
        return state.bases.keys.contains { $0.hasPrefix(prefix) }
    }

    func pending(_ id: SyncRecordID) -> Pending? {
        state.pending[id.description]
    }

    func pendingEdit(_ id: SyncRecordID) -> Date? {
        state.pending[id.description]?.editedAt
    }

    // MARK: - Writing

    /// Changes the state. Marked changed without comparing, since comparing the whole state on every record would make
    /// applying a large project quadratic.
    func update(_ body: (inout State) -> Void) {
        body(&state)
        isDirty = true
    }

    /// Records `record` as what this Mac and the server now agree on.
    func setBase(from record: SyncRecord, keepingSecretsIfUnsent: Bool = true) {
        let key = record.id.description
        let previous = state.bases[key]
        let secrets = record.secrets.map(secretDigests) ?? (keepingSecretsIfUnsent ? previous?.secrets ?? [:] : [:])
        state.bases[key] = Base(
            fingerprint: digester.fingerprint(record.payload),
            tree: OrderedJSONCodable(digester.tree(record.payload)),
            secrets: secrets,
            systemFields: record.systemFields ?? previous?.systemFields
        )
        state.tooLarge[key] = nil
        isDirty = true
    }

    func removeBase(_ id: SyncRecordID) {
        state.bases[id.description] = nil
        isDirty = true
    }

    /// Drops everything kept for `zone`'s records.
    func forget(_ zone: SyncZone) {
        let prefix = zone.name + "/"
        state.bases = state.bases.filter { !$0.key.hasPrefix(prefix) }
        state.pending = state.pending.filter { !$0.key.hasPrefix(prefix) }
        state.tooLarge = state.tooLarge.filter { !$0.key.hasPrefix(prefix) }
        isDirty = true
    }

    /// Notes an edit to send: a new time only when what it holds changed since it was queued.
    func notePending(_ id: SyncRecordID, fingerprint: String?, at date: Date) {
        let key = id.description
        if let existing = state.pending[key], existing.fingerprint == fingerprint {
            return
        }
        state.pending[key] = Pending(editedAt: date, fingerprint: fingerprint)
        isDirty = true
    }

    func clearPending(_ id: SyncRecordID) {
        guard state.pending[id.description] != nil else {
            return
        }
        state.pending[id.description] = nil
        isDirty = true
    }

    func secretDigests(_ secrets: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: secrets.map { (digester.digest("secret-key:" + $0.key), digester.digest("secret:" + $0.value)) })
    }

    /// Writes the state if it changed, readable by this user only. A write that fails is retried with the next one;
    /// what's lost meanwhile is redone by the next reconcile against the bases still on disk.
    func save() {
        guard isDirty else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let choices = state.choices
            if choices != savedChoices {
                try write(choices, to: "choices.json")
                savedChoices = choices
            }
            try write(state, to: "state.json")
            isDirty = false
        } catch {
            // Kept dirty, so the next save tries again.
        }
    }

    private func write(_ state: State, to name: String) throws {
        let url = directory.appendingPathComponent(name)
        try JSONEncoder().encode(state).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Drops what this Mac knew of the account's server, as after its data was deleted from iCloud: a cache, so it goes
    /// for good rather than to the Trash. Which projects and whether Global stay out of the account are the person's
    /// choices, so they stay.
    func reset() {
        var kept = State()
        kept.excluded = state.excluded
        kept.detached = state.detached
        kept.libraryDetached = state.libraryDetached
        try? FileManager.default.removeItem(at: directory)
        state = kept
        savedChoices = nil
        isDirty = true
        save()
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
