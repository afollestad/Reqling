import Foundation

/// This Mac's queued changes as they go out, and what the server said about each.
extension LibrarySync {
    /// The record to send for `id`, or `nil` to drop the change: one in a project whose copy here can't be trusted
    /// (`isReadFully`), or one holding only what the server has, as a save queued before a merge settled it, which would
    /// otherwise go out as a newer edit. Its `editedAt` reads on the server's clock (`clockSkew`).
    func outgoingRecord(for id: SyncRecordID) -> SyncRecord? {
        guard let store else {
            return nil
        }
        if case .project(let project) = id.zone, let local = library.project(project), !isReadFully(local) {
            return nil
        }
        var record: SyncRecord
        if let project = LibraryRecordCoder.tombstonedProject(id) {
            guard store.state.outgoingTombstones.contains(project), let tombstone = try? LibraryRecordCoder.tombstoneRecord(project) else {
                return nil
            }
            record = tombstone
        } else if id.name.hasPrefix(SyncRecordID.currentValuesPrefix) {
            guard let values = currentValuesRecords(in: id.zone)[id] else {
                return nil
            }
            record = sendable(values)
        } else {
            guard let local = localRecords(in: id.zone)?[id] else {
                return nil
            }
            record = sendable(local)
        }
        let base = store.base(id)
        if let base, base.systemFields != nil, store.pending(id) == nil, !differs(record, from: base) {
            return nil
        }
        let edited = store.pendingEdit(id) ?? now()
        sentEdits[id] = edited
        record.editedAt = edited.addingTimeInterval(-clockSkew)
        record.systemFields = base?.systemFields
        return record
    }

    func handleSent(_ results: [SyncSendResult]) {
        guard let store else {
            return
        }
        var conflicts: [SyncZone: [SyncRecord]] = [:]
        for result in results {
            noteOutcome(of: result)
            switch result {
            case .saved(let record):
                saved(record)
            case .deleted(let id):
                store.removeBase(id)
                store.clearPending(id)
            case .zoneSaved(let zone):
                failingZones.remove(zone)
            case .zoneSaveFailed(let zone, let message):
                reportFailure(message)
                failingZones.insert(zone)
            case .zoneDeleted(let zone):
                store.forget(zone)
                if case .project(let project) = zone {
                    store.update { $0.outgoingZoneDeletions.remove(project) }
                }
            case .conflict(let id, let server):
                // The server already holds a tombstone for it: as good as saved.
                guard LibraryRecordCoder.tombstonedProject(id) == nil else {
                    tombstoneSaved(id)
                    store.setBase(from: server)
                    continue
                }
                conflicts[id.zone, default: []].append(server)
            case .zoneMissing(let id):
                zoneMissing(for: id, in: store)
            case .missingOnServer(let id):
                store.update { $0.bases[id.description]?.systemFields = nil }
                transport.enqueue([.save(id)])
            case .tooLarge(let id):
                refusedAsTooLarge(id)
            case .failed(let id, let message):
                reportFailure(message)
                if id == nil {
                    zoneChangeFailed = true
                }
            }
        }
        // Each zone's conflicts merge and write once, not once per record. An edit here that the merge didn't settle, as
        // when the server's record was what this Mac last synced, goes out again on the server's version; but only once
        // the merge took, since one that couldn't be written would conflict the same way again.
        for (zone, records) in conflicts {
            apply(SyncFetchedZone(zone: zone, changed: records, deleted: []))
            let settled = records.filter { store.base($0.id)?.systemFields == $0.systemFields }
            transport.enqueue(settled.filter { store.pending($0.id).map { !$0.isDeletion } == true }.map { .save($0.id) })
        }
    }

    /// Forgets the edit time sent with a record that wasn't saved, and keeps one that failed to send for the next sync.
    private func noteOutcome(of result: SyncSendResult) {
        guard let id = result.recordID else {
            return
        }
        switch result {
        case .saved:
            failedSends.remove(id)
        case .failed:
            sentEdits[id] = nil
            failedSends.insert(id)
        default:
            sentEdits[id] = nil
            failedSends.remove(id)
        }
    }

    /// Queues again what merely failed to send, as a deletion when that's what this Mac has pending: iCloud drops such a
    /// change rather than retrying it, as for a full quota. Only Sync Now does, and a relaunch rebuilds the rest, so a
    /// change that keeps failing isn't sent again after every edit.
    func resendFailures() {
        guard let store else {
            return
        }
        transport.enqueue(failedSends.sorted { $0.description < $1.description }.map { id in
            store.pending(id)?.isDeletion == true ? .delete(id) : .save(id)
        })
        failedSends = []
        failingZones = []
        if zoneChangeFailed {
            zoneChangeFailed = false
            transport.enqueue(store.state.outgoingTombstones.map { .save(LibraryRecordCoder.tombstoneRecordID($0)) })
            transport.enqueue(store.state.outgoingZoneDeletions.map { .deleteZone(.project($0)) })
        }
    }

    /// Takes `record` as agreed, measuring the clock skew from it, and its edit as sent unless this Mac's copy differs
    /// from it still.
    private func saved(_ record: SyncRecord) {
        guard let store else {
            return
        }
        sentEdits[record.id] = nil
        if let server = record.serverModifiedAt {
            store.update { $0.clockSkew = self.now().timeIntervalSince(server) }
        }
        if case .project(let project) = record.id.zone,
           store.state.outgoingTombstones.contains(project) || store.state.outgoingZoneDeletions.contains(project) {
            // Saved as the project was deleted here: its zone goes, so nothing of it is kept.
            return
        }
        tombstoneSaved(record.id)
        store.setBase(from: record)
        guard let pending = store.pending(record.id), !pending.isDeletion else {
            return
        }
        // Judged by content, not by edit times, which two quick edits can share. A copy here that still differs was
        // edited while this save was out, and iCloud drops a save queued meanwhile with the one it took, so it goes again.
        let isValues = record.id.name.hasPrefix(SyncRecordID.currentValuesPrefix)
        let held = isValues ? currentValuesRecords(in: record.id.zone)[record.id] : localRecords(in: record.id.zone)?[record.id]
        if let held, differs(sendable(held), from: store.base(record.id)) {
            transport.enqueue([.save(record.id)])
        } else {
            store.clearPending(record.id)
        }
    }

    /// Notes what iCloud refused as too large, so the same content isn't sent again.
    private func refusedAsTooLarge(_ id: SyncRecordID) {
        guard let store else {
            return
        }
        if let record = outgoingRecord(for: id) {
            store.update { $0.tooLarge[id.description] = self.contentFingerprint(record) }
        }
        sentEdits[id] = nil
        // Its pending entry stays: the edit is still this Mac's alone, and must beat a deletion from another Mac.
        report("An item in \(name(of: id.zone)) is too large for iCloud, so it stays on this Mac.")
    }

    /// A saved tombstone lets its zone be deleted, and that deletion is kept in the state until it's done.
    private func tombstoneSaved(_ id: SyncRecordID) {
        guard let store, let project = LibraryRecordCoder.tombstonedProject(id), store.state.outgoingTombstones.contains(project) else {
            return
        }
        store.update { state in
            state.outgoingTombstones.remove(project)
            state.outgoingZoneDeletions.insert(project)
        }
        transport.enqueue([.deleteZone(.project(project))])
    }

    /// A save refused because its zone is gone. Sent before its zone was, as in a first upload, it goes again with the
    /// zone; a zone that failed to save holds it until Sync Now (`failingZones`). Otherwise the zone existed and is gone,
    /// which only the next fetch can explain: deleted with a tombstone, or vanished, and either way judged there
    /// (`judgeDeletion(of:)`), never recreated here.
    private func zoneMissing(for id: SyncRecordID, in store: SyncBaseStore) {
        if case .project(let project) = id.zone, store.state.tombstones.contains(project) {
            // Deleted on another Mac; the fetch that brought the tombstone deletes it here.
            store.clearPending(id)
        } else if failingZones.contains(id.zone) {
            failedSends.insert(id)
        } else if !store.hasBases(in: id.zone), isStillSyncing(id.zone) {
            transport.enqueue([.saveZone(id.zone), .save(id)])
        }
    }

    /// Whether `zone` is still one to sync into: Global's, or a project's that's here and syncs.
    private func isStillSyncing(_ zone: SyncZone) -> Bool {
        guard case .project(let project) = zone else {
            return true
        }
        return library.project(project).map(isSyncable) ?? false
    }

    /// Shows a failure in Settings, unless sync is paused for a choice that saying so would hide.
    func reportFailure(_ message: String) {
        switch status {
        case .accountChanged, .confirmingDeletions, .stopped, .off, .unavailable, .signedOut:
            break
        case .syncing, .upToDate, .failed:
            status = .failed(message)
        }
    }

    func name(of zone: SyncZone) -> String {
        switch zone {
        case .library: "Global"
        case .project(let id): library.project(id).map { "“\($0.name)”" } ?? "a project"
        }
    }
}
