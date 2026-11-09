import Foundation

/// Other Macs' changes to projects on their way in. A zone applies only once its fetch completes and only while Reqling
/// is in front; a record this version can't read holds its whole project back, rather than leaving gaps that would read
/// as deletions; and nothing a merge resolves is written before the secrets it needs are in the Keychain.
extension LibrarySync {
    func apply(_ fetched: SyncFetchedZone) {
        guard let store else {
            return
        }
        guard isActive else {
            heldEvents.append(.zone(fetched))
            return
        }
        var fetched = fetched
        if fetched.isWhole {
            // A whole fetch reports no deletions: what synced before and is missing from it is gone.
            let present = Set(fetched.changed.map(\.id))
            fetched.deleted = store.baseIDs(in: fetched.zone).filter { !present.contains($0) }
        }
        switch fetched.zone {
        case .library:
            applyLibrary(fetched)
        case .project(let id):
            applyProject(id, fetched)
        }
    }

    func applyHeldChanges() {
        let events = heldEvents
        heldEvents = []
        for event in events {
            switch event {
            case .zone(let fetched):
                apply(fetched)
            case .zoneDeletion(let zone, let reason):
                heldZoneDeletions.append((zone, reason))
            case .finish(let wholeDelivery, let date):
                finish(wholeDelivery: wholeDelivery, fetchedAt: date)
            }
        }
    }

    /// Whether anything fetched waits to be applied or judged. Nothing is sent meanwhile, since what's queued may be
    /// about to merge with it.
    var isHoldingFetchedChanges: Bool {
        !heldEvents.isEmpty || !heldZoneDeletions.isEmpty
    }

    /// Whether nothing fetched for `id` may land here: removed here, held back, or deleted here with its deletion still on
    /// its way out.
    func isHeldBack(_ id: ProjectID) -> Bool {
        guard let state = store?.state else {
            return true
        }
        return state.excluded.contains(id) || state.detached.contains(id) || state.deferred.contains(id)
            || state.outgoingTombstones.contains(id) || state.outgoingZoneDeletions.contains(id)
    }

    // MARK: - Projects

    /// Whether this Mac's copy of `id`, if any, may take another Mac's changes now.
    private func canApply(to id: ProjectID, local: LibraryProject?) -> Bool {
        guard let store, !isHeldBack(id) else {
            return false
        }
        guard let local else {
            if store.hasBases(in: .project(id)) {
                // Synced here before but gone from the list: what changed alone would rebuild it partly, and the next
                // reconcile would then delete the rest everywhere. Fetched whole instead.
                store.forget(.project(id))
                refetchAfterFailure()
                return false
            }
            return true
        }
        // A copy outside Reqling's folder (a repository) is left alone.
        guard isInScope(local) else {
            return false
        }
        // One whose files couldn't all be read waits for them, since what it lacks would merge as deleted here.
        guard local.document != nil, isReadFully(local) else {
            store.update { $0.unreadProjects.insert(id) }
            return false
        }
        return true
    }

    private func applyProject(_ id: ProjectID, _ fetched: SyncFetchedZone) {
        let local = library.project(id)
        guard canApply(to: id, local: local) else {
            return
        }
        let zone = SyncZone.project(id)
        var changed = fetched.changed.filter { isAcceptable($0, in: zone) }
        if changed.contains(where: isTooNew) || local?.isReadOnly == true {
            deferProject(id, untilUpdate: true)
            return
        }
        if local != nil {
            changed = droppingEchoes(changed)
        }
        guard !changed.isEmpty || !fetched.deleted.isEmpty else {
            return
        }
        var working: [SyncRecordID: SyncRecord] = [:]
        if local != nil {
            // Applying only the server's records over a project this Mac couldn't encode would drop its own items.
            guard let held = localRecords(in: zone) else {
                return
            }
            working = held.merging(currentValuesRecords(in: zone)) { first, _ in first }
        }
        let outcome = merge(changed, deleted: fetched.deleted, into: &working, hasLocal: local != nil)
        guard write(working, to: id, replacing: local?.document, arrived: Set(changed.map(\.id)), cleared: outcome.cleared) else {
            return
        }
        encoded[zone] = nil
        settle(changed, deleted: fetched.deleted, outcome: outcome)
        queue(outcome.resend, from: working)
    }

    /// Records what was written as agreed with the server. A merge with nothing left to send holds this Mac's edit, if
    /// any, so its pending entry goes; so does one for a record deleted on both sides.
    private func settle(_ changed: [SyncRecord], deleted: [SyncRecordID], outcome: MergeOutcome) {
        guard let store else {
            return
        }
        for record in changed {
            store.setBase(from: record)
            if !outcome.resend.contains(.save(record.id)) {
                store.clearPending(record.id)
            }
        }
        for recordID in deleted {
            store.removeBase(recordID)
            if !outcome.kept.contains(recordID) {
                store.clearPending(recordID)
            }
        }
    }

    /// `changed` without what this Mac already agrees with, such as its own saves coming back, whose only news, the
    /// server's version, goes into the bases. One carrying secret values this Mac lacks is kept, to fill them in.
    private func droppingEchoes(_ changed: [SyncRecord]) -> [SyncRecord] {
        guard let store else {
            return changed
        }
        return changed.filter { record in
            guard differs(record, from: store.base(record.id)) || withheld.contains(record.id) else {
                store.setBase(from: record)
                return false
            }
            return true
        }
    }

    /// Folds the server's changes into what this Mac holds.
    private func merge(
        _ changed: [SyncRecord],
        deleted: [SyncRecordID],
        into working: inout [SyncRecordID: SyncRecord],
        hasLocal: Bool
    ) -> MergeOutcome {
        guard let store else {
            return MergeOutcome()
        }
        var outcome = MergeOutcome()
        for record in changed {
            if let held = working[record.id] {
                let merged = merge(held, with: record, base: store.base(record.id))
                working[record.id] = merged
                if merged.payload != record.payload || merged.secrets != record.secrets {
                    outcome.resend.append(.save(record.id))
                }
            } else {
                // New here, or deleted here while edited there: the edit beats the deletion, whose queued send a save
                // replaces. Only a deletion actually queued counts; a record merely missing here is taken as new.
                working[record.id] = record
                if hasLocal, store.pending(record.id)?.isDeletion == true {
                    outcome.resend.append(.save(record.id))
                }
            }
        }
        for recordID in deleted {
            if let held = working[recordID], isEditedHere(held) {
                outcome.kept.insert(recordID)
                outcome.resend.append(.save(recordID))
            } else {
                working[recordID] = nil
                outcome.cleared.insert(recordID)
            }
        }
        return outcome
    }

    /// Whether this Mac's `held` copy of a record deleted elsewhere beats the deletion: never synced, or edited here since
    /// it last did, secrets included. An edit is one this Mac queued, not any difference from the base: an earlier fetch
    /// can change a record here, as removing a request changes its folder's order, which mustn't keep it.
    func isEditedHere(_ held: SyncRecord) -> Bool {
        guard let store, let base = store.base(held.id) else {
            return true
        }
        return store.pending(held.id).map { !$0.isDeletion } == true && differs(held, from: base)
    }

    /// Writes the merged project and its current values, first its secrets. `false` when nothing could be written.
    private func write(
        _ working: [SyncRecordID: SyncRecord],
        to id: ProjectID,
        replacing previous: ProjectDocument?,
        arrived: Set<SyncRecordID>,
        cleared: Set<SyncRecordID>
    ) -> Bool {
        guard store != nil else {
            return false
        }
        do {
            let decoded = try ProjectRecordCoder.document(id, from: working.values.filter { $0.type != .currentValues }, local: previous)
            // Before another Mac's change lands, every file this Mac reads a client identity from is marked, so one that
            // change moves into a request can't be read there (`ProjectWorkspaceState.identityFiles`).
            if let previous {
                lifecycle.markIdentityFiles(of: previous)
            }
            if previous == nil {
                try library.adoptSyncedProject(decoded.document, storingSecrets: decoded.secrets)
            } else {
                try library.applySynced(decoded.document, storingSecrets: decoded.secrets)
            }
            // Only the scopes that changed, so each fetch doesn't rewrite every secret current value in the Keychain.
            let values = working.values.filter { $0.type == .currentValues && arrived.contains($0.id) }
            applyCurrentValues(values, cleared: cleared, in: decoded.document)
            noteChanges(from: previous, to: decoded.document)
            return true
        } catch let error as SyncRecordError where previous == nil && [.missingProject, .missingDefaultEnvironment].contains(error) {
            // A project whose own records haven't all arrived, as when only some changed since the last fetch: fetched
            // whole again later, so what came meanwhile isn't lost.
            refetchAfterFailure()
            return false
        } catch is SyncRecordError {
            deferProject(id, untilUpdate: false)
            return false
        } catch {
            // The Keychain or the disk refused: nothing changed here, so fetch it all again later.
            refetchAfterFailure()
            report("Changes to \(name(of: .project(id))) from another Mac couldn't be saved here: \(error.localizedDescription)")
            return false
        }
    }

    /// Whether `record` is a kind this zone may hold, under a name Reqling writes for it; anything else is ignored.
    func isAcceptable(_ record: SyncRecord, in zone: SyncZone) -> Bool {
        guard record.id.zone == zone, record.type.belongs(in: zone) else {
            return false
        }
        switch record.type {
        case .project: return record.id.name == SyncRecordID.projectName
        case .folder, .request: return RequestNodeID(string: record.id.name)?.description == record.id.name
        case .environment: return EnvironmentID(string: record.id.name)?.description == record.id.name
        case .currentValues: return LibraryRecordCoder.scope(of: record.id) != nil
        case .globalEnvironment: return record.id == LibraryRecordCoder.globalRecordID
        case .projectTombstone: return LibraryRecordCoder.tombstonedProject(record.id) != nil
        }
    }

    /// Holds `id` back: `untilUpdate` for records from a newer version, which an update fetches again; otherwise, as for
    /// a record that wouldn't decode, until the next launch (`SyncBaseStore.State.deferredAt`).
    func deferProject(_ id: ProjectID, untilUpdate: Bool) {
        store?.update { state in
            Self.noteDeferral(untilUpdate: untilUpdate, in: &state)
            state.deferred.insert(id)
        }
    }

    /// `deferredAt` names the versions only while every deferral waits for an update; any other is judged each launch.
    static func noteDeferral(untilUpdate: Bool, in state: inout SyncBaseStore.State) {
        let wasDeferring = !state.deferred.isEmpty || state.libraryDeferred
        let allWaitForUpdate = untilUpdate && (!wasDeferring || state.deferredAt != nil)
        state.deferredAt = allWaitForUpdate ? SyncBaseStore.versions : nil
    }

    func isTooNew(_ record: SyncRecord) -> Bool {
        record.formatVersion > ProjectDocument.currentFormatVersion || record.schemaVersion > ProjectRecordCoder.schemaVersion
    }

    /// `held` and `remote` merged field by field over `base`; a field both changed takes the later edit, both edits'
    /// times read on the server's clock.
    func merge(_ held: SyncRecord, with remote: SyncRecord, base: SyncBaseStore.Base?) -> SyncRecord {
        guard let store else {
            return remote
        }
        let localEdit = store.pendingEdit(remote.id).map { $0.addingTimeInterval(-clockSkew) } ?? .distantPast
        let localIsNewer = localEdit > remote.trustedEditedAt
        var merged = remote
        let merger = SyncJSONMerge(digester: store.digester, localIsNewer: localIsNewer)
        merged.payload = merger.merge(base: base?.tree.json, local: held.payload, remote: remote.payload)
        merged.secrets = mergeSecrets(held.secrets, remote.secrets, base: base?.secrets ?? [:], localIsNewer: localIsNewer)
        return merged
    }

    /// Secrets merge key by key. A missing value means this side has none, never that it was deleted: a secret goes away
    /// with its variable, in the payload.
    private func mergeSecrets(
        _ local: [String: String]?,
        _ remote: [String: String]?,
        base: [String: String],
        localIsNewer: Bool
    ) -> [String: String]? {
        guard let local, let remote, let store else {
            return remote ?? local
        }
        var merged: [String: String] = [:]
        for key in Set(local.keys).union(remote.keys) {
            guard let mine = local[key] else {
                merged[key] = remote[key]
                continue
            }
            guard let theirs = remote[key], theirs != mine else {
                merged[key] = mine
                continue
            }
            let was = base[store.digester.digest("secret-key:" + key)]
            if store.digester.digest("secret:" + mine) == was {
                merged[key] = theirs
            } else if store.digester.digest("secret:" + theirs) == was {
                merged[key] = mine
            } else {
                merged[key] = localIsNewer ? mine : theirs
            }
        }
        return merged
    }

    /// Asks about trust again when another Mac changed the scripts, and notes requests that left or arrived. A folder
    /// adopted again may carry trust from before it fell off the list, which covered scripts that may since have changed.
    private func noteChanges(from previous: ProjectDocument?, to document: ProjectDocument) {
        let id = document.id
        let scripts = scriptSignature(document)
        let changedScripts = previous.map { scriptSignature($0) != scripts } ?? !scripts.isEmpty
        if changedScripts, lifecycle.workspace.projectState(id).scriptTrust == .trusted {
            lifecycle.workspace.updateProject(id) { $0.scriptTrust = .unknown }
        }
        // A certificate entry whose host another Mac changed no longer presents the Keychain identity chosen here.
        let hosts = Dictionary((previous?.tls.clientCertificates ?? []).map { ($0.id, $0.hostPattern) }) { first, _ in first }
        for entry in document.tls.clientCertificates where hosts[entry.id].map({ $0 != entry.hostPattern }) ?? false {
            lifecycle.workspace.setKeychainIdentity(nil, for: entry.id)
        }
        let before = Set(previous?.allRequests.map(\.0.id) ?? [])
        let after = Set(document.allRequests.map(\.0.id))
        removedRequests[id, default: []].formUnion(before.subtracting(after))
        addedRequests[id, default: []].formUnion(after.subtracting(before))
    }

    private func scriptSignature(_ document: ProjectDocument) -> [String: ScriptSet] {
        var scripts: [String: ScriptSet] = ["project": document.scripts]
        func visit(_ nodes: [RequestNode]) {
            for node in nodes {
                switch node {
                case .folder(let folder):
                    scripts[folder.id.description] = folder.scripts
                    visit(folder.children)
                case .request(let request):
                    scripts[request.id.description] = request.scripts
                }
            }
        }
        visit(document.items)
        return scripts.filter { !$0.value.isEmpty }
    }

    /// Queues what a merge sends back. A merged edit keeps the time of the edit here it carries, so it doesn't look newer
    /// than an edit another Mac made since.
    func queue(_ changes: [SyncPendingChange], from records: [SyncRecordID: SyncRecord]) {
        guard let store, !changes.isEmpty else {
            return
        }
        for case .save(let id) in changes {
            store.notePending(id, fingerprint: records[id].map(contentFingerprint), at: store.pendingEdit(id) ?? now())
        }
        transport.enqueue(changes)
    }
}

/// What merging a fetched zone decided beyond the records it wrote.
struct MergeOutcome {
    /// Changes to send back: merged records the server lacks, and edits that beat a deletion.
    var resend: [SyncPendingChange] = []
    /// Records deleted elsewhere that an edit here keeps.
    var kept: Set<SyncRecordID> = []
    /// Records deleted elsewhere that go here too: unchanged here since they last synced, or deleted here as well.
    var cleared: Set<SyncRecordID> = []
}
