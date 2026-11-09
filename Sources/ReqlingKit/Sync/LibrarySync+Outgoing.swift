import Foundation

/// This Mac's changes on their way out: each is compared, record by record, against what was last synced, so a change
/// made while Reqling was closed, or sync was off, goes out on the next reconcile just as one made a moment ago does.
extension LibrarySync {
    func libraryChanged(_ change: LibraryChange) {
        guard let store, canSync else {
            return
        }
        switch change {
        case .project(let id):
            encoded[.project(id)] = nil
            // A project removed here comes back only by being added again.
            if store.state.excluded.contains(id) {
                store.update { $0.excluded.remove(id) }
            }
            reconcileProject(id)
        case .removed(let id):
            encoded[.project(id)] = nil
            store.update { state in
                state.excluded.insert(id)
                state.pending = state.pending.filter { !$0.key.hasPrefix(SyncZone.project(id).name + "/") }
            }
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

    func reconcileEverything() {
        encoded = [:]
        for project in library.projects {
            reconcileProject(project.id)
        }
        reconcileLibrary()
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

    func reconcileProject(_ id: ProjectID) {
        guard let store, let project = library.project(id), isSyncable(project) else {
            return
        }
        let zone = SyncZone.project(id)
        if !store.hasBases(in: zone) {
            // A project's first upload states every ID the reader derived, which a rename elsewhere would change.
            try? library.persistSettledIDs(id)
            encoded[zone] = nil
            transport.enqueue([.saveZone(zone)])
        }
        guard let records = localRecords(in: zone) else {
            return
        }
        // A file that couldn't be read drops out of the document, which mustn't read as its deletion.
        let readFully = !project.issues.contains { $0.message != ProjectLibrary.unreadableSecretsMessage }
        queueDifferences(records, in: zone, deletingMissing: readFully)
    }

    /// The records this Mac holds for `zone`, or `nil` when it holds none to compare.
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
            guard var built = try? ProjectRecordCoder.records(for: document, secrets: keychain) else {
                return nil
            }
            for (recordID, record) in built where record.type == .environment {
                built[recordID]?.secrets = guardedSecrets(record, environment: EnvironmentID(string: recordID.name).flatMap(document.environment))
            }
            records = built
            for scope in library.currentValues.storedScopes {
                guard case .environment(id, let environment) = scope, document.environment(environment) != nil else {
                    continue
                }
                if let record = try? currentValuesRecord(scope) {
                    records[record.id] = record
                }
            }
        case .library:
            if let global = try? LibraryRecordCoder.globalRecord(library.globalEnvironment, secrets: try? secretStore.secrets(for: .global)) {
                records[global.id] = global
            }
            if library.currentValues.storedScopes.contains(.global), let record = try? currentValuesRecord(.global) {
                records[record.id] = record
            }
        }
        encoded[zone] = records
        return records
    }

    /// `record`'s secrets, or `nil` to leave the server's alone when the base says the server holds a value for a secret
    /// this Mac has none for: the field is replaced whole, so sending the rest would erase that one.
    private func guardedSecrets(_ record: SyncRecord, environment: RequestEnvironment?) -> [String: String]? {
        guard let secrets = record.secrets, let store, let base = store.base(record.id), let environment else {
            return record.secrets
        }
        let digester = store.digester
        let held = Set(secrets.keys.map { digester.digest("secret-key:" + $0) })
        let lacking = environment.variables.filter(\.isSecret).map { digester.digest("secret-key:" + $0.id.description) }
            .filter { !held.contains($0) }
        return lacking.contains(where: { base.secrets[$0] != nil }) ? nil : secrets
    }

    func currentValuesRecord(_ scope: CurrentValueScope) throws -> SyncRecord {
        try LibraryRecordCoder.currentValuesRecord(
            scope,
            values: library.currentValues.storedValues(in: scope),
            secrets: try? secretStore.secrets(for: scope.account)
        )
    }

    // MARK: - Global and current values

    func reconcileLibrary() {
        guard let records = localRecords(in: .library) else {
            return
        }
        queueDifferences(records, in: .library, deletingMissing: false)
        reconcileCurrentValues()
    }

    /// Only current-values records, since scripts change them on every run.
    func reconcileCurrentValues() {
        guard let store else {
            return
        }
        var zones: [SyncZone] = [.library]
        zones += library.projects.filter(isSyncable).map { .project($0.id) }
        for zone in zones {
            encoded[zone] = nil
            let records = (localRecords(in: zone) ?? [:]).filter { $0.value.type == .currentValues }
            queueDifferences(records, in: zone, deletingMissing: false)
            for id in store.baseIDs(in: zone) where id.name.hasPrefix(SyncRecordID.currentValuesPrefix) && records[id] == nil {
                guard let scope = LibraryRecordCoder.scope(of: id), isLiveScope(scope) else {
                    continue
                }
                store.setPending(id, at: store.pendingEdit(id) ?? now())
                transport.enqueue([.delete(id)])
            }
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

    /// Queues each record that differs from what was last synced, and, with `deletingMissing`, the deletion of each
    /// synced record this Mac no longer has.
    func queueDifferences(_ records: [SyncRecordID: SyncRecord], in zone: SyncZone, deletingMissing: Bool) {
        guard let store else {
            return
        }
        var changes: [SyncPendingChange] = []
        for (id, record) in records where differs(record, from: store.base(id)) {
            store.setPending(id, at: now())
            changes.append(.save(id))
        }
        if deletingMissing {
            for id in store.baseIDs(in: zone) where records[id] == nil {
                store.setPending(id, at: store.pendingEdit(id) ?? now())
                changes.append(.delete(id))
            }
        }
        transport.enqueue(changes)
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

    // MARK: - Deletions

    /// A project deleted here: its tombstone goes first, and its zone only once that's saved, so another Mac never sees
    /// the zone vanish without knowing someone deleted it.
    private func sendTombstone(for id: ProjectID) {
        guard let store else {
            return
        }
        let zone = SyncZone.project(id)
        guard store.hasBases(in: zone) else {
            store.forget(zone)
            return
        }
        store.forget(zone)
        store.update { $0.outgoingTombstones.insert(id) }
        transport.enqueue([.save(LibraryRecordCoder.tombstoneRecordID(id))])
    }

    // MARK: - Sending

    func outgoingRecord(for id: SyncRecordID) -> SyncRecord? {
        guard let store else {
            return nil
        }
        var record: SyncRecord
        if let project = LibraryRecordCoder.tombstonedProject(id) {
            guard store.state.outgoingTombstones.contains(project), let tombstone = try? LibraryRecordCoder.tombstoneRecord(project) else {
                return nil
            }
            record = tombstone
        } else {
            guard let local = localRecords(in: id.zone)?[id] else {
                return nil
            }
            record = local
        }
        record.editedAt = store.pendingEdit(id) ?? now()
        record.systemFields = store.base(id)?.systemFields
        return record
    }

    func handleSent(_ results: [SyncSendResult]) {
        guard let store else {
            return
        }
        for result in results {
            switch result {
            case .saved(let record):
                if let project = LibraryRecordCoder.tombstonedProject(record.id), store.state.outgoingTombstones.contains(project) {
                    store.update { $0.outgoingTombstones.remove(project) }
                    transport.enqueue([.deleteZone(.project(project))])
                }
                store.setBase(from: record)
                if let pending = store.pendingEdit(record.id), pending <= record.editedAt {
                    store.setPending(record.id, at: nil)
                }
            case .deleted(let id):
                store.removeBase(id)
                store.setPending(id, at: nil)
            case .zoneSaved:
                break
            case .zoneDeleted(let zone):
                store.forget(zone)
            case .conflict(_, let server):
                apply(SyncFetchedZone(zone: server.id.zone, changed: [server], deleted: []))
            case .zoneMissing(let id):
                if case .project(let project) = id.zone, store.state.tombstones.contains(project) {
                    // Deleted on another Mac; the fetch that brought the tombstone deletes it here.
                    store.setPending(id, at: nil)
                } else {
                    transport.enqueue([.saveZone(id.zone), .save(id)])
                }
            case .missingOnServer(let id):
                store.update { $0.bases[id.description]?.systemFields = nil }
                transport.enqueue([.save(id)])
            case .tooLarge(let id):
                store.setPending(id, at: nil)
                report("An item in \(name(of: id.zone)) is too large for iCloud, so it stays on this Mac.")
            case .failed(_, let message):
                status = .failed(message)
            }
        }
    }

    func name(of zone: SyncZone) -> String {
        switch zone {
        case .library: "Global"
        case .project(let id): library.project(id).map { "“\($0.name)”" } ?? "a project"
        }
    }
}
