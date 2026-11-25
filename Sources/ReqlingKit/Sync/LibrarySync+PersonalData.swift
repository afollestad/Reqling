import Foundation

/// Each project's `personal` zone: this person's secret values and current values, kept apart from the project's own
/// zone so sharing the project never shares them, and synced only across this person's Macs.
///
/// Before the zone existed, each environment's record carried its secret values, and the project's zone held its
/// current values. Bringing them over must lose none, and must never let an older Mac read a project half moved, so it
/// goes in order, judged afresh from the bases each time rather than from a flag, and starts again should an older Mac
/// write them back:
/// 1. The personal records go up, built from the Keychain and the current-values store.
/// 2. The project's header goes up at this schema version (`isFenced`), so an older Mac holds the project back from the
///    fetch that brings it on, and never applies what follows, which it would read as deletions of its values.
/// 3. Only then, per environment, once `personal` holds every value its record held, the record goes up with its secrets
///    cleared (`mayClearSecrets`), and the current values left in the project's zone are deleted (`mayDeleteLegacyValues`).
extension LibrarySync {
    /// The schema version that moved secret and current values into `personal`.
    static let personalSchemaVersion = 2

    // MARK: - Records

    /// The `personal` records this Mac holds for `project`, or `nil` when it isn't loaded: each environment's secret
    /// values, for those with a secret variable, and current values (`currentValuesRecords(in:)`). Built fresh each
    /// time, since scripts change current values on every run.
    func personalRecords(of project: ProjectID) -> [SyncRecordID: SyncRecord]? {
        guard let secrets = personalSecretsRecords(of: project) else {
            return nil
        }
        return secrets.merging(currentValuesRecords(in: .personal(project))) { first, _ in first }
    }

    /// Each of `project`'s environments with a secret variable, as a record of the values this Mac holds for them, or
    /// none at all when the Keychain can't be read.
    func personalSecretsRecords(of project: ProjectID) -> [SyncRecordID: SyncRecord]? {
        guard let document = library.document(project) else {
            return nil
        }
        let keychain = try? secretStore.secrets(for: .project(project))
        var records: [SyncRecordID: SyncRecord] = [:]
        for environment in document.allEnvironments where environment.variables.contains(where: \.isSecret) {
            let record = LibraryRecordCoder.secretsRecord(project, environment, secrets: keychain)
            noteWithheld(record, expecting: secretVariableKeys(environment))
            records[record.id] = record
        }
        return records
    }

    /// Queues what differs in `project`'s personal zone, saving the zone first when nothing in it has synced here.
    func reconcilePersonal(_ project: ProjectID, at date: Date, valuesAt valuesDate: Date?) {
        guard let store, let records = personalRecords(of: project) else {
            return
        }
        let zone = SyncZone.personal(project)
        if !records.isEmpty, !store.hasBases(in: zone) {
            transport.enqueue([.saveZone(zone)])
        }
        queueDifferences(records, in: zone, deletingMissing: true, at: date, valuesAt: valuesDate)
    }

    // MARK: - Bringing values over

    /// Whether `project`'s header went up at `personalSchemaVersion` or later, which an older Mac holds it back at.
    func isFenced(_ project: ProjectID) -> Bool {
        let header = SyncRecordID(zone: .project(project), name: SyncRecordID.projectName)
        return (store?.base(header)?.schemaVersion ?? 1) >= Self.personalSchemaVersion
    }

    /// Whether the environment record `id` may go up with its secrets cleared: the server's holds none, or the project is
    /// fenced and `personal` holds a value for each of its variables still secret here, with nothing of this Mac's still
    /// to send there, so clearing loses none. A value this Mac lacks waits for whichever Mac has it to bring it over.
    /// Values left in someone else's project are its owner's, which only their Macs bring over and clear.
    func mayClearSecrets(_ id: SyncRecordID) -> Bool {
        guard let store, case .project(let project) = id.zone, let base = store.base(id), !base.secrets.isEmpty else {
            return true
        }
        guard role == .own, isFenced(project), let environment = EnvironmentID(string: id.name) else {
            return false
        }
        let personal = LibraryRecordCoder.secretsRecordID(project, environment)
        guard !withheld.contains(personal), store.pending(personal) == nil else {
            return false
        }
        let live = Set(secretVariableKeys(library.document(project)?.environment(environment)).map { store.digester.digest("secret-key:" + $0) })
        let held = store.base(personal)?.secrets ?? [:]
        return base.secrets.keys.filter(live.contains).allSatisfy { held[$0] != nil }
    }

    /// Whether the current values `id` left in a project's zone may be deleted: the project is fenced, and `personal`
    /// holds this Mac's for the environment, which merged them in as they arrived, or there are none to hold, with
    /// nothing still to send there.
    func mayDeleteLegacyValues(_ id: SyncRecordID) -> Bool {
        guard let store, case .project(let project) = id.zone, isFenced(project),
              case .environment(_, let environment)? = LibraryRecordCoder.scope(of: id) else {
            return false
        }
        let scope = CurrentValueScope.environment(project, environment)
        let personal = LibraryRecordCoder.currentValuesRecordID(scope)
        guard !withheld.contains(personal), store.pending(personal) == nil else {
            return false
        }
        let isLive = library.document(project)?.environment(environment) != nil
        return store.base(personal) != nil || !isLive || library.currentValues.storedValues(in: scope).isEmpty
    }

    /// The current values left in `project`'s own zone, as its bases know them.
    func legacyValueIDs(in project: ProjectID) -> [SyncRecordID] {
        store?.baseIDs(in: .project(project)).filter { $0.name.hasPrefix(SyncRecordID.currentValuesPrefix) } ?? []
    }

    /// Whether `project`'s own zone still holds anything of this person's: an environment's secret values, or current
    /// values.
    func holdsLegacyData(_ project: ProjectID) -> Bool {
        guard let store else {
            return false
        }
        return store.baseIDs(in: .project(project)).contains { id in
            id.name.hasPrefix(SyncRecordID.currentValuesPrefix)
                || (EnvironmentID(string: id.name) != nil && store.base(id)?.secrets.isEmpty == false)
        }
    }

    /// Takes the next step of bringing `project`'s values over, once a step it waited for is done: the fence or a
    /// personal record saved, or an older Mac's write fetched.
    func advanceBringingOver(_ project: ProjectID) {
        if holdsLegacyData(project) {
            reconcileProject(project)
        }
    }

    /// Takes the next step for each project whose fence or personal records `results` saved, or settled in a conflict
    /// whose merge took: one that couldn't be written would conflict the same way again.
    func advanceBringingOver(after results: [SyncSendResult]) {
        let advancing = results.compactMap { result -> ProjectID? in
            let id: SyncRecordID
            switch result {
            case .saved(let record):
                id = record.id
            case .conflict(let conflicted, let server) where store?.base(conflicted)?.systemFields == server.systemFields:
                id = conflicted
            default:
                return nil
            }
            guard let project = id.zone.project, id.zone == .personal(project) || id.name == SyncRecordID.projectName else {
                return nil
            }
            return project
        }
        Set(advancing).sorted().forEach(advanceBringingOver)
    }

    // MARK: - What older Macs leave

    /// Whether `record`, fetched from a project's zone, holds this person's data where a Mac before `personal` writes it.
    func isLegacyPersonalData(_ record: SyncRecord) -> Bool {
        record.type == .currentValues || (record.type == .environment && record.secrets?.isEmpty == false)
    }

    /// `record` as the project's own, without the secret values an older Mac left in it, so the project merges as this
    /// Mac's own records hold it (`ProjectRecordCoder.records(for:)`).
    func withoutPersonalData(_ record: SyncRecord) -> SyncRecord {
        guard record.type == .environment else {
            return record
        }
        var record = record
        record.secrets = [:]
        return record
    }

    /// Merges what an older Mac left in `project`'s zone into this Mac's personal values, each as a change to the
    /// personal record it now belongs in, over the version of the old record that Mac saw last: its base here, or, once
    /// it was cleared from here, its last (`SyncBaseStore.State.legacyBases`). So a value newer here isn't taken back by
    /// a stale one, and one changed there wins as an edit would. With neither, once the project is `fenced`, `personal`
    /// holds what's current, so the record waits for the fetch's personal zones (`fillLegacyAwaitingFetchEnd`); before
    /// the fence, it's all there is, as on a Mac new to an account no Mac has moved over yet. This Mac's values
    /// come from the Keychain and the current-values store alone, so this works before the project is listed. Nothing is
    /// settled for the personal records: they now differ from their bases, and go up with the next reconcile. `false`
    /// when the Keychain refused, which fetches everything again later.
    func mergeLegacy(_ records: [SyncRecord], of project: ProjectID, fenced: Bool) -> Bool {
        guard let store else {
            return false
        }
        var working: [SyncRecordID: SyncRecord] = [:]
        for record in records {
            guard let personal = personalCounterpart(of: record) else {
                continue
            }
            let held = store.base(record.id).flatMap { record.type == .environment && $0.secrets.isEmpty ? nil : $0 }
            guard let lastSeen = held ?? store.legacyBase(record.id) ?? (fenced ? nil : store.base(personal.id)) else {
                if fenced {
                    legacyAwaitingFetchEnd.append((record, personal))
                } else {
                    working[personal.id] = heldPersonalRecord(personal.id).map { merge($0, with: personal, base: nil) } ?? personal
                }
                continue
            }
            working[personal.id] = heldPersonalRecord(personal.id).map { merge($0, with: personal, base: lastSeen) } ?? personal
        }
        return working.isEmpty || writePersonal(working, of: project, arrived: Set(working.keys), cleared: [])
    }

    /// What older Macs left that no Mac here saw the version before of, now that the fetch's personal zones are
    /// applied (`mergeLegacy`). Where `personal` holds the record it stands for, that wins whole: with no base, a key the
    /// older Mac has and `personal` lacks may be one it added or one removed since, and bringing back a removed value is
    /// the worse mistake, so a value an older Mac adds there before it sees the fence doesn't come over. Where it holds
    /// none, as for an environment's first values, the record fills in what this Mac lacks. Each is taken as agreed
    /// only once written, so a quit before then fetches it again.
    func fillLegacyAwaitingFetchEnd() {
        guard let store else {
            return
        }
        let waiting = Dictionary(grouping: legacyAwaitingFetchEnd) { $0.personal.id.zone.project }
        legacyAwaitingFetchEnd = []
        for case let (project?, entries) in waiting {
            var working: [SyncRecordID: SyncRecord] = [:]
            for entry in entries where store.base(entry.personal.id) == nil {
                let id = entry.personal.id
                working[id] = heldPersonalRecord(id).map { filling($0, from: entry.personal) } ?? entry.personal
            }
            guard working.isEmpty || writePersonal(working, of: project, arrived: Set(working.keys), cleared: []) else {
                continue
            }
            for entry in entries {
                store.setBase(from: entry.original)
            }
            advanceBringingOver(project)
        }
    }

    /// `held` with the values only `remote` has added, whole, keeping each of `held`'s: a merge with no base to say
    /// which side changed, where this Mac's are the ones to trust. A current value goes by key, never field by field,
    /// which would mix a secret marker here with plain text there.
    private func filling(_ held: SyncRecord, from remote: SyncRecord) -> SyncRecord {
        var filled = held
        let theirs = remote.secrets ?? [:]
        var secrets = held.secrets ?? [:]
        if held.type == .currentValues,
           let mine = try? LibraryRecordCoder.currentValues(from: held).values,
           let other = try? LibraryRecordCoder.currentValues(from: remote).values,
           let payload = try? ProjectRecordCoder.json(mine.merging(other) { kept, _ in kept }) {
            filled.payload = payload
            for key in other.keys where mine[key] == nil {
                secrets[key] = theirs[key]
            }
        } else {
            secrets.merge(theirs) { kept, _ in kept }
        }
        filled.secrets = held.secrets == nil && remote.secrets == nil ? nil : secrets
        return filled
    }

    /// The personal record an older Mac's record in a project's zone stands for: an environment's secret values, or
    /// current values.
    private func personalCounterpart(of record: SyncRecord) -> SyncRecord? {
        guard case .project(let project) = record.id.zone else {
            return nil
        }
        let id: SyncRecordID
        let type: SyncRecordType
        switch record.type {
        case .environment:
            guard record.secrets?.isEmpty == false, let environment = EnvironmentID(string: record.id.name) else {
                return nil
            }
            (id, type) = (LibraryRecordCoder.secretsRecordID(project, environment), .personalSecrets)
        case .currentValues:
            guard let scope = LibraryRecordCoder.scope(of: record.id) else {
                return nil
            }
            (id, type) = (LibraryRecordCoder.currentValuesRecordID(scope), .currentValues)
        default:
            return nil
        }
        let payload = type == .personalSecrets ? OrderedJSON.object([]) : record.payload
        return SyncRecord(
            id: id,
            type: type,
            payload: payload,
            secrets: record.secrets,
            editedAt: record.editedAt,
            serverModifiedAt: record.serverModifiedAt
        )
    }

    /// This Mac's version of the personal record `id`, from the Keychain and the current-values store alone, for a
    /// project that may not be listed yet; `nil` when it holds none, or the Keychain can't be read for secret values.
    private func heldPersonalRecord(_ id: SyncRecordID) -> SyncRecord? {
        guard case .personal(let project) = id.zone else {
            return nil
        }
        if let environment = LibraryRecordCoder.secretsEnvironment(id) {
            return (try? secretStore.secrets(for: .project(project))).map {
                LibraryRecordCoder.secretsRecord(project, environment, keychain: $0)
            }
        }
        guard let scope = LibraryRecordCoder.scope(of: id) else {
            return nil
        }
        let values = library.currentValues.storedValues(in: scope)
        guard !values.isEmpty else {
            return nil
        }
        return try? LibraryRecordCoder.currentValuesRecord(scope, values: values, secrets: try? secretStore.secrets(for: scope.account))
    }

    // MARK: - Incoming

    /// Another Mac's changes to `project`'s personal zone: merged with this Mac's values over the bases, as a project's
    /// records are, then stored. One for a project this Mac hasn't listed yet is stored all the same, since the zones
    /// arrive in either order: adopting the project fills its secret values from the Keychain (`adoptSyncedProject`).
    func applyPersonal(_ project: ProjectID, _ fetched: SyncFetchedZone) {
        guard canApplyPersonal(project) else {
            return
        }
        let zone = SyncZone.personal(project)
        if fetched.changed.contains(where: isTooNew) {
            deferProject(project, untilUpdate: true)
            return
        }
        let changed = droppingEchoes(fetched.changed.filter { isAcceptable($0, in: zone) })
        guard !changed.isEmpty || !fetched.deleted.isEmpty else {
            return
        }
        var working = personalRecords(of: project) ?? [:]
        let outcome = merge(changed, deleted: fetched.deleted, into: &working, hasLocal: library.project(project) != nil)
        guard writePersonal(working, of: project, arrived: Set(changed.map(\.id)), cleared: outcome.cleared) else {
            return
        }
        // Values for an environment not here yet, or secret values for one with no secret variable here yet, are stored
        // but not taken as agreed: a reconcile before the project's change arrives would read them as gone, and delete
        // them everywhere. Once it does, they go up again and merge as equal.
        let document = library.document(project)
        settle(changed.filter { record in
            guard let id = personalEnvironment(of: record.id) else {
                return true
            }
            guard let environment = document?.environment(id) else {
                return false
            }
            return record.type != .personalSecrets || environment.variables.contains(where: \.isSecret)
        }, deleted: fetched.deleted, outcome: outcome)
        queue(outcome.resend, from: working)
    }

    /// The environment a personal record belongs to.
    private func personalEnvironment(of id: SyncRecordID) -> EnvironmentID? {
        if let environment = LibraryRecordCoder.secretsEnvironment(id) {
            return environment
        }
        if case .environment(_, let environment)? = LibraryRecordCoder.scope(of: id) {
            return environment
        }
        return nil
    }

    /// Whether `project`'s personal values may take another Mac's changes now: as for its project (`canApply`), and
    /// held back with it while it's from a newer version.
    private func canApplyPersonal(_ project: ProjectID) -> Bool {
        // One deleted elsewhere keeps no values here, as for a Mac that never had it.
        guard let store, !isHeldBack(project), !store.state.tombstones.contains(project) else {
            return false
        }
        guard let local = library.project(project) else {
            return true
        }
        guard isInScope(local) else {
            return false
        }
        if local.isNewerFormat {
            deferProject(project, untilUpdate: true)
            return false
        }
        guard local.document != nil, isReadFully(local) else {
            store.update { $0.unreadProjects.insert(project) }
            return false
        }
        return true
    }

    /// Stores the merged secret values, then the current values. A deleted secrets record deletes no value, so a
    /// deletion stays recoverable. `false` when the Keychain refused, which fetches everything again later.
    private func writePersonal(
        _ working: [SyncRecordID: SyncRecord],
        of project: ProjectID,
        arrived: Set<SyncRecordID>,
        cleared: Set<SyncRecordID>
    ) -> Bool {
        var secrets: [String: String] = [:]
        for record in working.values where record.type == .personalSecrets && arrived.contains(record.id) {
            secrets.merge(LibraryRecordCoder.secretValues(from: record)) { _, new in new }
        }
        do {
            try library.applySyncedSecrets(secrets, in: project)
        } catch {
            refetchAfterFailure()
            report("Secret values for \(name(of: .project(project))) from another Mac couldn't be saved here: \(error.localizedDescription)")
            return false
        }
        let values = working.values.filter { $0.type == .currentValues && arrived.contains($0.id) }
        applyCurrentValues(values, cleared: cleared, in: library.document(project))
        return true
    }
}
