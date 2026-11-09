import Foundation

/// This Mac's changes on their way out: each is compared, record by record, against what was last synced, so a change
/// made while Reqling was closed, or sync was off, goes out on the next reconcile just as one made a moment ago does.
///
/// Four checks hold things back, each at its own step: `isSyncable` decides what's compared and queued here,
/// `isReadFully` whether a project's copy here can be trusted either way, `isHeldBack` what a fetch may change
/// (`+Incoming.swift`), and `shouldSend` what may leave now (`+ZoneDeletions.swift`).
extension LibrarySync {
    /// Changes are compared as they're made even while sync is paused, so each keeps the time it was made; `shouldSend`
    /// holds them until sync resumes. With no account connected, the reconcile that connecting runs finds edits, and
    /// counts a project gone meanwhile as removed, even one deleted (`reconcileListedProjects`).
    func libraryChanged(_ change: LibraryChange) {
        guard let store else {
            return
        }
        switch change {
        case .project(let id):
            encoded[.project(id)] = nil
            if isReturning(id) {
                readd(id)
                // What its folder holds differently dates from when its files last changed, not from its return.
                reconcileProject(id, editedAt: library.project(id).flatMap { lastModified($0.url) })
            } else {
                reconcileProject(id)
            }
        case .removed(let id):
            encoded[.project(id)] = nil
            store.update { state in
                state.excluded.insert(id)
                state.detached.remove(id)
                state.pending = state.pending.filter { !$0.key.hasPrefix(SyncZone.project(id).name + "/") }
            }
            transport.cancelPending(in: .project(id))
            store.save()
        case .deleted(let id):
            encoded[.project(id)] = nil
            sendTombstone(for: id)
        case .global:
            encoded[.library] = nil
            reconcileLibrary()
        case .currentValues:
            reconcileCurrentValues()
        }
    }

    /// Whether `id`, listed again, comes back after this Mac removed or deleted it, or after another Mac deleted it: an
    /// edit to a project still syncing would find bases, and one held back as deleted elsewhere is detached.
    private func isReturning(_ id: ProjectID) -> Bool {
        guard let store else {
            return false
        }
        let state = store.state
        if state.excluded.contains(id) {
            return true
        }
        guard !state.detached.contains(id), !store.hasBases(in: .project(id)) else {
            return false
        }
        return state.tombstones.contains(id) || state.outgoingTombstones.contains(id) || state.outgoingZoneDeletions.contains(id)
            || store.base(LibraryRecordCoder.tombstoneRecordID(id)) != nil
    }

    /// A project added back after leaving. Changes made elsewhere meanwhile were skipped, so everything is fetched
    /// again whole, which merges them over the bases kept from before, deletions included. Only the bases of records
    /// its folder holds as last synced stay: a record an older copy lacks arrives as new rather than going out as
    /// deleted, and one it holds differently merges as with no base, the server's values winning, rather than going out
    /// as an edit. A record another Mac deleted before the project left, which an older copy still holds, comes back:
    /// restoring a copy keeps what it holds rather than trashing it. A deletion of the project, here or by another Mac,
    /// is withdrawn, so it isn't trashed anywhere again.
    private func readd(_ id: ProjectID) {
        guard let store else {
            return
        }
        let tombstone = LibraryRecordCoder.tombstoneRecordID(id)
        let state = store.state
        let wasDeleted = state.tombstones.contains(id) || state.outgoingTombstones.contains(id)
            || state.outgoingZoneDeletions.contains(id) || store.base(tombstone) != nil
        let zone = SyncZone.project(id)
        encoded[zone] = nil
        let here = (localRecords(in: zone) ?? [:]).merging(currentValuesRecords(in: zone)) { first, _ in first }
        for recordID in store.baseIDs(in: zone) where here[recordID].map({ differs(sendable($0), from: store.base(recordID)) }) ?? true {
            store.removeBase(recordID)
        }
        // A deletion of its zone still queued.
        transport.cancelPending(in: zone)
        store.update { state in
            state.excluded.remove(id)
            state.tombstones.remove(id)
            state.outgoingTombstones.remove(id)
            state.outgoingZoneDeletions.remove(id)
        }
        requestRefetch()
        if wasDeleted {
            // Pending, so the refetch doesn't learn the tombstone again before its deletion goes out; and replacing any
            // queued save of it.
            store.notePending(tombstone, fingerprint: nil, at: now())
            transport.enqueue([.delete(tombstone)])
        }
    }

    /// Compares everything with what was last synced. `stampingFromFiles`, as on connecting, dates what it finds changed
    /// by when its files last changed, since those edits were made while sync wasn't looking.
    func reconcileEverything(stampingFromFiles: Bool = false) {
        encoded = [:]
        let configuration = library.configuration
        let valuesChanged = stampingFromFiles ? lastModified(configuration.currentValuesURL) : nil
        for project in library.projects {
            let edited = stampingFromFiles ? lastModified(project.url) : nil
            reconcileProject(project.id, editedAt: edited, valuesEditedAt: valuesChanged)
        }
        let globalChanged = stampingFromFiles ? lastModified(configuration.globalEnvironmentURL) : nil
        reconcileLibrary(editedAt: globalChanged, valuesEditedAt: valuesChanged)
    }

    /// When anything at `url`, or inside it, last changed, but never later than now.
    private func lastModified(_ url: URL) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var urls = [url]
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            urls += enumerator.compactMap { $0 as? URL }
        }
        let latest = urls.compactMap { try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate }.max()
        return latest.map { min($0, now()) }
    }

    // MARK: - Projects

    /// Whether `project` syncs now: in scope, loaded, writable, and not held back.
    func isSyncable(_ project: LibraryProject) -> Bool {
        guard let store, project.document != nil, !project.isReadOnly, isInScope(project) else {
            return false
        }
        let id = project.id
        return !store.state.excluded.contains(id) && !store.state.detached.contains(id) && !store.state.deferred.contains(id)
    }

    func isInScope(_ project: LibraryProject) -> Bool {
        SyncScope.contains(project.url, projectsDirectory: projectsDirectory)
    }

    /// Whether `project`'s copy here holds what its files do: a file that couldn't be read drops out of the document or
    /// leaves a stand-in, which would read as a deletion or an edit, going out or coming in.
    func isReadFully(_ project: LibraryProject) -> Bool {
        !project.issues.contains(where: \.losesContent)
    }

    func reconcileProject(_ id: ProjectID, editedAt: Date? = nil, valuesEditedAt: Date? = nil) {
        guard let store, let project = library.project(id), isSyncable(project) else {
            return
        }
        let zone = SyncZone.project(id)
        guard isReadFully(project) else {
            report("\(name(of: zone)) has files Reqling couldn't read, so it doesn't sync until they're fixed.")
            return
        }
        if store.state.unreadProjects.contains(id) {
            // Changes that waited for its files to read again arrive with a refetch.
            store.update { $0.unreadProjects.remove(id) }
            requestRefetch()
        }
        if !store.hasBases(in: zone) {
            if store.state.tombstones.contains(id) {
                // Deleted on another Mac, while this one can't tell it synced it, as after losing its key: kept here, and
                // not sent back to undo the deletion.
                store.update { $0.detached.insert(id) }
                report("\(name(of: zone)) was deleted on another Mac, so it stays on this Mac and no longer syncs.")
                return
            }
            // A project's first upload states every ID the reader derived, which a rename elsewhere would change.
            try? library.persistSettledIDs(id)
            encoded[zone] = nil
            transport.enqueue([.saveZone(zone)])
        }
        guard let records = localRecords(in: zone) else {
            return
        }
        let all = records.merging(currentValuesRecords(in: zone)) { first, _ in first }
        queueDifferences(all, in: zone, deletingMissing: true, at: editedAt ?? now(), valuesAt: valuesEditedAt)
    }

    /// The project's, folders', requests', and environments' records this Mac holds for `zone`, or Global's; `nil` when it
    /// holds none to compare. Current values are apart (`currentValuesRecords(in:)`). Each carries every secret value
    /// this Mac has, for merging; what may be sent is `sendable(_:)`.
    func localRecords(in zone: SyncZone) -> [SyncRecordID: SyncRecord]? {
        if let cached = encoded[zone] {
            return cached
        }
        var records: [SyncRecordID: SyncRecord] = [:]
        switch zone {
        case .project(let id):
            guard let document = library.document(id) else {
                return nil
            }
            let keychain = try? secretStore.secrets(for: .project(id))
            guard let built = try? ProjectRecordCoder.records(for: document, secrets: keychain) else {
                return nil
            }
            for (recordID, record) in built where record.type == .environment {
                let environment = EnvironmentID(string: recordID.name).flatMap(document.environment)
                noteWithheld(record, expecting: secretVariableKeys(environment))
            }
            records = built
        case .library:
            let global = library.globalEnvironment
            if let record = try? LibraryRecordCoder.globalRecord(global, secrets: try? secretStore.secrets(for: .global)) {
                noteWithheld(record, expecting: secretVariableKeys(global))
                records[record.id] = record
            }
        }
        encoded[zone] = records
        return records
    }

    /// `zone`'s current-values records, built from what scripts stored, without encoding any project.
    func currentValuesRecords(in zone: SyncZone) -> [SyncRecordID: SyncRecord] {
        var records: [SyncRecordID: SyncRecord] = [:]
        for scope in library.currentValues.storedScopes {
            switch (zone, scope) {
            case (.library, .global):
                break
            case let (.project(id), .environment(project, environment)) where project == id && library.document(id)?.environment(environment) != nil:
                break
            default:
                continue
            }
            let values = library.currentValues.storedValues(in: scope)
            let keychain = try? secretStore.secrets(for: scope.account)
            if let record = try? LibraryRecordCoder.currentValuesRecord(scope, values: values, secrets: keychain) {
                noteWithheld(record, expecting: Set(values.filter { $0.value == .secret }.keys))
                records[record.id] = record
            }
        }
        return records
    }

    private func secretVariableKeys(_ environment: RequestEnvironment?) -> Set<String> {
        Set((environment?.variables ?? []).filter(\.isSecret).map(\.id.description))
    }

    /// Notes whether `record`'s secrets must stay unsent: the base says the server holds a value for one of `expected`
    /// that this Mac has none for, and the field is replaced whole, so sending the rest would erase that one. Such a
    /// record is fetched whole again, so the merge fills in the missing value and the rest can go out with it.
    private func noteWithheld(_ record: SyncRecord, expecting expected: Set<String>) {
        guard let store else {
            return
        }
        let held = record.secrets.map { Set($0.keys) } ?? []
        let lacking = expected.subtracting(held).map { store.digester.digest("secret-key:" + $0) }
        let base = store.base(record.id)
        guard record.secrets != nil, lacking.contains(where: { base?.secrets[$0] != nil }) else {
            withheld.remove(record.id)
            return
        }
        if withheld.insert(record.id).inserted {
            requestRefetch()
            report("Some secret values in \(name(of: record.id.zone)) aren't on this Mac, so its own secret changes wait for them from iCloud.")
        }
    }

    /// `record` as it may be sent: without its secrets while some are withheld.
    func sendable(_ record: SyncRecord) -> SyncRecord {
        guard withheld.contains(record.id) else {
            return record
        }
        var sendable = record
        sendable.secrets = nil
        return sendable
    }

    // MARK: - Global and current values

    func reconcileLibrary(editedAt: Date? = nil, valuesEditedAt: Date? = nil) {
        guard let store, !store.state.libraryDetached, !store.state.libraryDeferred, let records = localRecords(in: .library) else {
            return
        }
        queueDifferences(records, in: .library, deletingMissing: false, at: editedAt ?? now())
        reconcileCurrentValues(editedAt: valuesEditedAt)
    }

    /// Only current-values records, since scripts change them on every run.
    func reconcileCurrentValues(editedAt: Date? = nil) {
        guard let store else {
            return
        }
        var zones: [SyncZone] = store.state.libraryDetached || store.state.libraryDeferred ? [] : [.library]
        zones += library.projects.filter { isSyncable($0) && isReadFully($0) }.map { .project($0.id) }
        for zone in zones {
            let records = currentValuesRecords(in: zone)
            queueDifferences(records, in: zone, deletingMissing: false, at: editedAt ?? now())
            var deletions: [SyncPendingChange] = []
            for id in store.baseIDs(in: zone) where id.name.hasPrefix(SyncRecordID.currentValuesPrefix) && records[id] == nil {
                guard let scope = LibraryRecordCoder.scope(of: id), isLiveScope(scope) else {
                    continue
                }
                store.notePending(id, fingerprint: nil, at: editedAt ?? now())
                deletions.append(.delete(id))
            }
            transport.enqueue(deletions)
        }
    }

    /// Whether `scope`'s environment still exists here, so its values going is a reset rather than a deletion.
    private func isLiveScope(_ scope: CurrentValueScope) -> Bool {
        switch scope {
        case .global: true
        case .environment(let project, let environment): library.document(project)?.environment(environment) != nil
        }
    }

    // MARK: - Queueing

    /// Queues each record that differs from what was last synced, made `at` (current values `valuesAt`, when given), and,
    /// with `deletingMissing`, the deletion of each synced record this Mac no longer has. Saves go parents first and
    /// deletions children first, so a fetch between two batches never finds a request without its folder, which it
    /// would move to the top level and so keep. An edit already queued keeps its time unless what it holds changed again.
    func queueDifferences(
        _ records: [SyncRecordID: SyncRecord],
        in zone: SyncZone,
        deletingMissing: Bool,
        at date: Date,
        valuesAt valuesDate: Date? = nil
    ) {
        guard let store else {
            return
        }
        var saves: [SyncRecordID] = []
        for (id, local) in records {
            let record = sendable(local)
            guard differs(record, from: store.base(id)) else {
                continue
            }
            let fingerprint = contentFingerprint(record)
            // Refused as too large before, and no smaller since.
            if store.state.tooLarge[id.description] == fingerprint {
                continue
            }
            store.notePending(id, fingerprint: fingerprint, at: record.type == .currentValues ? valuesDate ?? date : date)
            saves.append(id)
        }
        let rank = sendRank(in: zone)
        var changes: [SyncPendingChange] = saves.sorted { (rank[$0] ?? .max, $0.name) < (rank[$1] ?? .max, $1.name) }.map { .save($0) }
        if deletingMissing {
            for id in deletionOrder(store.baseIDs(in: zone).filter { records[$0] == nil }) {
                store.notePending(id, fingerprint: nil, at: date)
                changes.append(.delete(id))
            }
        }
        transport.enqueue(changes)
    }

    /// `ids` with each before its parent among them. The bases hold a parent only as a digest, so each is matched
    /// against the digests of the other records' names.
    private func deletionOrder(_ ids: [SyncRecordID]) -> [SyncRecordID] {
        guard let store, ids.count > 1 else {
            return ids
        }
        let parentKey = store.digester.digest("key:parentID")
        let byDigest = Dictionary(ids.map { (store.digester.tree(.string($0.name)).prettyPrinted(), $0) }) { first, _ in first }
        var parents: [SyncRecordID: SyncRecordID] = [:]
        for id in ids {
            if case .object(let members)? = store.base(id)?.tree.json, let parent = members.first(where: { $0.key == parentKey }) {
                parents[id] = byDigest[parent.value.prettyPrinted()]
            }
        }
        func depth(_ id: SyncRecordID) -> Int {
            var depth = 0
            var seen: Set<SyncRecordID> = [id]
            var current = id
            while let parent = parents[current], seen.insert(parent).inserted {
                depth += 1
                current = parent
            }
            return depth
        }
        let depths = Dictionary(uniqueKeysWithValues: ids.map { ($0, depth($0)) })
        return ids.sorted { (depths[$0] ?? 0, $1.name) > (depths[$1] ?? 0, $0.name) }
    }

    /// Each record's place in a first upload: the project, its environments, then its folders and requests in tree order.
    private func sendRank(in zone: SyncZone) -> [SyncRecordID: Int] {
        guard case .project(let id) = zone, let document = library.document(id) else {
            return [:]
        }
        var rank: [SyncRecordID: Int] = [SyncRecordID(zone: zone, name: SyncRecordID.projectName): 0]
        for environment in document.allEnvironments {
            rank[SyncRecordID(zone: zone, name: environment.id.description)] = 1
        }
        var next = 2
        func visit(_ nodes: [RequestNode]) {
            for node in nodes {
                rank[SyncRecordID(zone: zone, name: node.id.description)] = next
                next += 1
                if case .folder(let folder) = node {
                    visit(folder.children)
                }
            }
        }
        visit(document.items)
        return rank
    }

    /// Whether `record` holds anything its base doesn't. A secret this Mac has no value for counts as unchanged.
    func differs(_ record: SyncRecord, from base: SyncBaseStore.Base?) -> Bool {
        guard let store, let base else {
            return true
        }
        if store.digester.fingerprint(record.payload) != base.fingerprint {
            return true
        }
        guard let secrets = record.secrets else {
            return false
        }
        return store.secretDigests(secrets).contains { base.secrets[$0.key] != $0.value }
    }

    /// A digest of everything `record` would send, secrets included, to tell whether a queued edit changed again.
    func contentFingerprint(_ record: SyncRecord) -> String {
        guard let store else {
            return ""
        }
        let secrets = store.secretDigests(record.secrets ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return store.digester.digest(store.digester.fingerprint(record.payload) + "|" + secrets.joined(separator: ","))
    }

    // MARK: - Deletions

    /// A project deleted here: its tombstone goes first, and its zone only once that's saved, so another Mac never sees
    /// the zone vanish without knowing someone deleted it. Both are kept in the state until done, outliving a quit.
    private func sendTombstone(for id: ProjectID) {
        guard let store else {
            return
        }
        let zone = SyncZone.project(id)
        transport.cancelPending(in: zone)
        guard store.hasBases(in: zone) else {
            // Never sent, as with an import rolled back: nothing on the server to delete or leave behind.
            store.forget(zone)
            return
        }
        store.forget(zone)
        store.update { $0.outgoingTombstones.insert(id) }
        // Kept at once, so a quit before it's sent can't lose it.
        store.save()
        transport.enqueue([.save(LibraryRecordCoder.tombstoneRecordID(id))])
    }
}
