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
            if case .saved = result {} else if let id = result.recordID {
                sentEdits[id] = nil
            }
            switch result {
            case .saved(let record):
                saved(record)
            case .deleted(let id):
                store.removeBase(id)
                store.clearPending(id)
            case .zoneSaved:
                break
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
                if case .project(let project) = id.zone, store.state.tombstones.contains(project) {
                    // Deleted on another Mac; the fetch that brought the tombstone deletes it here.
                    store.clearPending(id)
                } else if !store.hasBases(in: id.zone) {
                    // Sent before its zone was: a first upload.
                    transport.enqueue([.saveZone(id.zone), .save(id)])
                }
                // Otherwise the zone existed and is gone, which only the next fetch can explain: deleted with a
                // tombstone, or vanished, and either way judged there (`judgeDeletion(of:)`), never recreated here.
            case .missingOnServer(let id):
                store.update { $0.bases[id.description]?.systemFields = nil }
                transport.enqueue([.save(id)])
            case .tooLarge(let id):
                refusedAsTooLarge(id)
            case .failed(_, let message):
                status = .failed(message)
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

    /// Takes `record` as agreed, measuring the clock skew from it, and its edit as sent unless edited again since.
    private func saved(_ record: SyncRecord) {
        guard let store else {
            return
        }
        let sent = sentEdits.removeValue(forKey: record.id)
        if let server = record.serverModifiedAt {
            store.update { $0.clockSkew = self.now().timeIntervalSince(server) }
        }
        tombstoneSaved(record.id)
        store.setBase(from: record)
        if let pending = store.pendingEdit(record.id), pending <= sent ?? record.editedAt.addingTimeInterval(clockSkew) {
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

    func name(of zone: SyncZone) -> String {
        switch zone {
        case .library: "Global"
        case .project(let id): library.project(id).map { "“\($0.name)”" } ?? "a project"
        }
    }
}
