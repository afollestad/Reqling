import Foundation
import ReqlingTemplating

/// Other Macs' changes on their way in. A zone applies only once its fetch completes and only while Reqling is in
/// front; a record this version can't read holds its whole project back, rather than leaving gaps that would read as
/// deletions; and nothing a merge resolves is written before the secrets it needs are in the Keychain.
extension LibrarySync {
    func apply(_ fetched: SyncFetchedZone) {
        guard store != nil else {
            return
        }
        guard isActive else {
            heldZones.append(fetched)
            return
        }
        switch fetched.zone {
        case .library:
            applyLibrary(fetched)
        case .project(let id):
            applyProject(id, fetched)
        }
    }

    func applyHeldChanges() {
        let zones = heldZones
        heldZones = []
        zones.forEach(apply)
        if heldFinish {
            heldFinish = false
            finishFetching()
        }
    }

    // MARK: - Projects

    private func applyProject(_ id: ProjectID, _ fetched: SyncFetchedZone) {
        guard let store, !store.state.excluded.contains(id), !store.state.detached.contains(id) else {
            return
        }
        let zone = SyncZone.project(id)
        let local = library.project(id)
        // A copy outside Reqling's folder (a repository), or one that couldn't load, is left alone.
        if let local, !isInScope(local) || local.document == nil {
            return
        }
        let changed = fetched.changed.filter { isAcceptable($0, in: zone) }
        if changed.contains(where: isTooNew) || (local?.isReadOnly ?? false) {
            store.update { $0.deferred.insert(id) }
            return
        }
        store.update { $0.deferred.remove(id) }
        var working: [SyncRecordID: SyncRecord] = [:]
        if local != nil {
            // Applying only the server's records over a project this Mac couldn't encode would drop its own items.
            guard let held = localRecords(in: zone) else {
                return
            }
            working = held
        }
        let outcome = merge(changed, deleted: fetched.deleted, into: &working, hasLocal: local != nil)
        let arrived = Set(changed.map(\.id))
        guard write(working, to: id, replacing: local?.document, arrived: arrived, deleted: fetched.deleted) else {
            return
        }
        encoded[zone] = nil
        for record in changed {
            store.setBase(from: record)
        }
        for recordID in fetched.deleted {
            store.removeBase(recordID)
            if !outcome.kept.contains(recordID) {
                store.setPending(recordID, at: nil)
            }
        }
        queue(outcome.resend)
    }

    /// Folds the server's changes into what this Mac holds, returning what to send back and which deleted records an
    /// edit here keeps.
    private func merge(
        _ changed: [SyncRecord],
        deleted: [SyncRecordID],
        into working: inout [SyncRecordID: SyncRecord],
        hasLocal: Bool
    ) -> (resend: [SyncPendingChange], kept: Set<SyncRecordID>) {
        guard let store else {
            return ([], [])
        }
        var resend: [SyncPendingChange] = []
        for record in changed {
            let base = store.base(record.id)
            if let held = working[record.id] {
                let merged = merge(held, with: record, base: base)
                working[record.id] = merged
                if merged.payload != record.payload || merged.secrets != record.secrets {
                    resend.append(.save(record.id))
                }
            } else if base != nil, hasLocal, store.digester.fingerprint(record.payload) == base?.fingerprint {
                // Deleted here but not sent yet, and untouched there: it stays deleted.
                resend.append(.delete(record.id))
            } else {
                // New, or deleted here while edited there: the edit beats the deletion, whose queued send a save replaces.
                working[record.id] = record
                if base != nil, hasLocal {
                    resend.append(.save(record.id))
                }
            }
        }
        var kept: Set<SyncRecordID> = []
        for recordID in deleted {
            if let held = working[recordID], let base = store.base(recordID), store.digester.fingerprint(held.payload) != base.fingerprint {
                kept.insert(recordID)
                resend.append(.save(recordID))
            } else {
                working[recordID] = nil
            }
        }
        return (resend, kept)
    }

    /// Writes the merged project and its current values, first its secrets. `false` when nothing could be written.
    private func write(
        _ working: [SyncRecordID: SyncRecord],
        to id: ProjectID,
        replacing previous: ProjectDocument?,
        arrived: Set<SyncRecordID>,
        deleted: [SyncRecordID]
    ) -> Bool {
        guard let store else {
            return false
        }
        do {
            let decoded = try ProjectRecordCoder.document(id, from: working.values.filter { $0.type != .currentValues }, local: previous)
            if previous == nil {
                try library.adoptSyncedProject(decoded.document, storingSecrets: decoded.secrets)
            } else {
                try library.applySynced(decoded.document, storingSecrets: decoded.secrets)
            }
            // Only the scopes that changed, so each fetch doesn't rewrite every secret current value in the Keychain.
            applyCurrentValues(working.values.filter { $0.type == .currentValues && arrived.contains($0.id) }, deleted: deleted, in: decoded.document)
            noteChanges(from: previous, to: decoded.document)
            return true
        } catch SyncRecordError.missingProject where previous == nil {
            // A zone whose project record hasn't arrived yet waits for the fetch that brings it.
            return false
        } catch is SyncRecordError {
            store.update { $0.deferred.insert(id) }
            return false
        } catch {
            // The Keychain or the disk refused: nothing changed here, so fetch it all again later.
            store.update { $0.needsRefetch = true }
            report("Changes to \(name(of: .project(id))) from another Mac couldn't be saved here: \(error.localizedDescription)")
            return false
        }
    }

    /// Whether `record` is a kind this zone may hold, under a name Reqling writes for it; anything else is ignored.
    private func isAcceptable(_ record: SyncRecord, in zone: SyncZone) -> Bool {
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

    private func isTooNew(_ record: SyncRecord) -> Bool {
        record.formatVersion > ProjectDocument.currentFormatVersion || record.schemaVersion > ProjectRecordCoder.schemaVersion
    }

    /// `held` and `remote` merged field by field over `base`; a field both changed takes the later edit.
    func merge(_ held: SyncRecord, with remote: SyncRecord, base: SyncBaseStore.Base?) -> SyncRecord {
        guard let store else {
            return remote
        }
        let localIsNewer = (store.pendingEdit(remote.id) ?? .distantPast) > remote.trustedEditedAt
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

    /// Writes each changed scope's current values, forcing secret any value this Mac knows to be one.
    private func applyCurrentValues(_ records: [SyncRecord], deleted: [SyncRecordID], in document: ProjectDocument) {
        for record in records {
            guard let scope = LibraryRecordCoder.scope(of: record.id), let decoded = try? LibraryRecordCoder.currentValues(from: record) else {
                continue
            }
            if case .environment(_, let environment) = scope, document.environment(environment) == nil {
                continue
            }
            let (values, secrets) = secured(decoded.values, decoded.secrets, in: scope, document: document)
            library.currentValues.applySynced(values, secrets: secrets, in: scope)
        }
        for id in deleted {
            let isGone = !records.contains { $0.id == id }
            if let scope = LibraryRecordCoder.scope(of: id), isGone {
                library.currentValues.applySynced([:], secrets: [:], in: scope)
            }
        }
    }

    /// A plain value under a key this Mac holds as secret, or holding one of its secrets, becomes secret here.
    func secured(
        _ values: [String: StoredCurrentValue],
        _ secrets: [String: String],
        in scope: CurrentValueScope,
        document: ProjectDocument?
    ) -> ([String: StoredCurrentValue], [String: String]) {
        var environments = [library.globalEnvironment]
        if case .environment(_, let id) = scope, let environment = document?.environment(id) {
            environments.append(environment)
        }
        let secretVariables = environments.flatMap(\.variables).filter(\.isSecret)
        let secretKeys = Set(secretVariables.map(\.key))
        let secretValues = Set(secretVariables.map(\.value)).union(secrets.values)
        var values = values
        var secrets = secrets
        for (key, value) in values {
            if case .plain(let text) = value, secretKeys.contains(key) || VariableLayers.contains(text, anyOf: secretValues) {
                values[key] = .secret
                secrets[key] = text
            }
        }
        return (values, secrets)
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

    func queue(_ changes: [SyncPendingChange]) {
        guard let store, !changes.isEmpty else {
            return
        }
        for change in changes {
            if case .save(let id) = change, store.pendingEdit(id) == nil {
                store.setPending(id, at: now())
            }
        }
        transport.enqueue(changes)
    }

    // MARK: - Global and tombstones

    private func applyLibrary(_ fetched: SyncFetchedZone) {
        guard let store else {
            return
        }
        let held = localRecords(in: .library) ?? [:]
        var resend: [SyncPendingChange] = []
        for record in fetched.changed where isAcceptable(record, in: .library) {
            if isTooNew(record) {
                continue
            }
            let merged = held[record.id].map { merge($0, with: record, base: store.base(record.id)) } ?? record
            do {
                switch record.type {
                case .projectTombstone:
                    if let project = LibraryRecordCoder.tombstonedProject(record.id) {
                        store.update { $0.tombstones.insert(project) }
                    }
                case .globalEnvironment:
                    let global = try LibraryRecordCoder.global(from: merged, local: library.globalEnvironment)
                    try library.applySyncedGlobalEnvironment(global.variables, storingSecrets: global.secrets)
                case .currentValues:
                    let decoded = try LibraryRecordCoder.currentValues(from: merged)
                    let (values, secrets) = secured(decoded.values, decoded.secrets, in: .global, document: nil)
                    library.currentValues.applySynced(values, secrets: secrets, in: .global)
                case .project, .folder, .request, .environment:
                    continue
                }
            } catch {
                store.update { $0.needsRefetch = true }
                report("Global's changes from another Mac couldn't be saved here: \(error.localizedDescription)")
                continue
            }
            store.setBase(from: record)
            if merged.payload != record.payload || merged.secrets != record.secrets {
                resend.append(.save(record.id))
            }
        }
        for id in fetched.deleted {
            // Only a reset deletes Global's records; this Mac keeps its own.
            store.removeBase(id)
        }
        encoded[.library] = nil
        queue(resend)
    }

    // MARK: - Zone deletions

    func zoneDeleted(_ zone: SyncZone, reason: SyncZoneDeletionReason) {
        heldZoneDeletions.append((zone, reason))
    }

    /// Runs once a fetch has delivered every zone, so tombstones are known before any deletion is judged.
    func finishFetching() {
        guard let store else {
            return
        }
        guard isActive else {
            heldFinish = true
            return
        }
        let deletions = heldZoneDeletions
        heldZoneDeletions = []
        var candidates: [ProjectID] = []
        for (zone, reason) in deletions {
            switch reason {
            case .purged:
                stopAfterServerReset(.dataDeleted)
                return
            case .encryptedDataReset:
                stopAfterServerReset(.encryptionReset)
                return
            case .deleted:
                guard case .project(let id) = zone, store.hasBases(in: zone), library.project(id) != nil else {
                    // Nothing here to keep: a project this Mac never had, or one removed from it.
                    store.forget(zone)
                    continue
                }
                if store.state.tombstones.contains(id), let project = library.project(id), isInScope(project) {
                    candidates.append(id)
                } else {
                    // Gone without anyone deleting it: keep this Mac's copy, and stop syncing it.
                    store.forget(zone)
                    store.update { $0.detached.insert(id) }
                    report("\(name(of: zone)) disappeared from iCloud, so it stays on this Mac and no longer syncs.")
                }
            }
        }
        if candidates.count > 1 {
            awaitingConfirmation = candidates
            status = .confirmingDeletions(candidates)
        } else {
            candidates.forEach(deleteRemotelyDeleted)
        }
        moveOrForgetHistory()
        if let state = unsavedTransportState {
            store.update { $0.transportState = state }
            unsavedTransportState = nil
        }
        store.save()
    }

    func deleteRemotelyDeleted(_ id: ProjectID) {
        try? lifecycle.deleteSyncedProject(id)
        store?.forget(.project(id))
        encoded[.project(id)] = nil
    }

    /// A request that left one project and arrived in another in one fetch was moved, so its history goes with it.
    private func moveOrForgetHistory() {
        for (project, requests) in removedRequests {
            for request in requests {
                if let destination = addedRequests.first(where: { $0.value.contains(request) })?.key, library.project(destination) != nil {
                    lifecycle.runner.moveHistory(of: [request], from: project, to: destination)
                } else {
                    lifecycle.runner.forget(request, in: project)
                }
            }
        }
        removedRequests = [:]
        addedRequests = [:]
    }
}

extension LibrarySync: SyncTransportDelegate {
    func record(for id: SyncRecordID) -> SyncRecord? {
        outgoingRecord(for: id)
    }

    func transport(didFetch zone: SyncFetchedZone) {
        apply(zone)
    }

    func transport(didDeleteZone zone: SyncZone, reason: SyncZoneDeletionReason) {
        zoneDeleted(zone, reason: reason)
    }

    func transportDidFinishFetching() {
        finishFetching()
    }

    func transport(didSend results: [SyncSendResult]) {
        handleSent(results)
        store?.save()
    }

    func transport(didUpdateState state: Data) {
        unsavedTransportState = state
    }

    func transportAccountDidChange() {
        Task { await connect() }
    }
}
