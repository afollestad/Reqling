import Foundation

/// Zones that vanished from the server, judged once a fetch has delivered everything, so tombstones are known first.
extension LibrarySync {
    func zoneDeleted(_ zone: SyncZone, reason: SyncZoneDeletionReason) {
        if isActive {
            heldZoneDeletions.append((zone, reason))
        } else {
            heldEvents.append(.zoneDeletion(zone, reason))
        }
    }

    /// A fetch finished. In the background its judging waits in line behind its zones, with, for a whole fetch, the
    /// zones it delivered: a later fetch's zones say nothing of what this one left out.
    func finishFetching(wasWhole: Bool) {
        let delivered = wasWhole ? deliveredZones : nil
        deliveredZones = []
        guard isActive else {
            heldEvents.append(.finish(wholeDelivery: delivered, finishedAt: now()))
            return
        }
        finish(wholeDelivery: delivered, fetchedAt: now())
    }

    /// Judges what the fetches applied deleted. `wholeDelivery`, the zones a whole fetch delivered, reports no zone
    /// deletions (`transportDidFinishFetching(wasWhole:)`), so each project zone synced here outside it is judged as
    /// deleted, and none delivered at all means the account's data is gone; and a refetch asked for is done, unless this
    /// one left something again. `fetchedAt` is when the fetch finished, which a deletion queued since must wait out.
    func finish(wholeDelivery: Set<SyncZone>?, fetchedAt: Date) {
        guard let store else {
            return
        }
        lastFetchFinished = fetchedAt
        var deletions = heldZoneDeletions
        heldZoneDeletions = []
        if refetchRaised, wholeDelivery == nil {
            // The tombstone saying a zone went on purpose may be among what this fetch dropped, so a deletion waits for
            // the refetch, which knows them all; a reset of the account's data can't wait.
            heldZoneDeletions = deletions.filter { $0.1 == .deleted }
            deletions = deletions.filter { $0.1 != .deleted }
        }
        if let wholeDelivery {
            // A zone this fetch delivered exists, whatever an earlier fetch said of it.
            deletions = deletions.filter { !wholeDelivery.contains($0.0) || $0.1 != .deleted }
            deletions += finishWholeFetch(delivering: wholeDelivery, judging: Set(deletions.map(\.0)))
        }
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
                if let id = judgeDeletion(of: zone), !candidates.contains(id) {
                    candidates.append(id)
                }
            }
        }
        let awaiting = store.state.awaitingConfirmation
        let asking = awaiting + candidates.filter { !awaiting.contains($0) }
        if asking.count > 1 {
            store.update { $0.awaitingConfirmation = asking }
            status = .confirmingDeletions(asking)
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

    /// The project zones synced here that a whole fetch didn't deliver, and weren't already reported deleted, as deleted;
    /// with nothing delivered at all, the account's data as deleted, as only a reset leaves no Global or tombstone; and
    /// the refetch done, unless this fetch asked for another. Global's zone is never judged gone this way.
    private func finishWholeFetch(
        delivering delivered: Set<SyncZone>,
        judging judged: Set<SyncZone>
    ) -> [(SyncZone, SyncZoneDeletionReason)] {
        guard let store else {
            return []
        }
        let synced = store.syncedZones
        if delivered.isEmpty, !synced.isEmpty {
            return [(.library, .purged)]
        }
        if refetchRaised {
            wholeFetchFellShort = true
        } else {
            store.update { $0.needsRefetch = false }
        }
        return synced.subtracting(delivered).subtracting(judged).filter { $0 != .library }.map { ($0, .deleted) }
    }

    /// The project whose zone another Mac deleted on purpose, to move to the Trash here; `nil` when there's none, after
    /// keeping whatever this Mac has.
    private func judgeDeletion(of zone: SyncZone) -> ProjectID? {
        guard let store else {
            return nil
        }
        guard case .project(let id) = zone else {
            // Global's zone goes only with a reset; this Mac's copy goes up again.
            store.forget(zone)
            return nil
        }
        if store.state.outgoingZoneDeletions.contains(id) || store.state.outgoingTombstones.contains(id) {
            // Deleted here already.
            store.forget(zone)
            store.update { $0.outgoingZoneDeletions.remove(id) }
            return nil
        }
        guard store.hasBases(in: zone), let project = library.project(id), !store.state.detached.contains(id) else {
            // Nothing here that syncs: a project this Mac never had, one removed from it, or one already detached.
            store.forget(zone)
            return nil
        }
        if store.state.tombstones.contains(id), isInScope(project) {
            return id
        }
        // Gone without anyone deleting it: keep this Mac's copy, and stop syncing it.
        store.forget(zone)
        store.update { $0.detached.insert(id) }
        report("\(name(of: zone)) disappeared from iCloud, so it stays on this Mac and no longer syncs.")
        return nil
    }

    /// A project that can't go to the Trash stays here, detached, rather than being uploaded again as new.
    func deleteRemotelyDeleted(_ id: ProjectID) {
        store?.forget(.project(id))
        transport.cancelPending(in: .project(id))
        encoded[.project(id)] = nil
        do {
            try lifecycle.deleteSyncedProject(id)
        } catch {
            store?.update { $0.detached.insert(id) }
            report("\(name(of: .project(id))) was deleted on another Mac but couldn't be moved to the Trash here, so it stays and no longer syncs.")
        }
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

    /// Nothing goes out in the background, while fetched changes wait, or while sync is paused. A deletion also waits for
    /// a fetch made since it and within `deletionFetchWindow`, which brings any edit another Mac made meanwhile to beat
    /// it, since the server deletes whatever version it holds; and nothing recreates a project another Mac deleted.
    func shouldSend(_ change: SyncPendingChange) -> Bool {
        guard let store, isActive, canSync, !isHoldingFetchedChanges else {
            return false
        }
        switch change {
        case .saveZone(let zone):
            return !isTombstoned(zone)
        case .save(let id):
            return !isTombstoned(id.zone) && !isHeldBackFromSending(id)
        case .delete(let id):
            if let pending = store.pending(id), pending.isDeletion,
               pending.editedAt > lastFetchFinished || now().timeIntervalSince(lastFetchFinished) > Self.deletionFetchWindow {
                return false
            }
            return !isHeldBackFromSending(id)
        case .deleteZone:
            return true
        }
    }

    static let deletionFetchWindow: TimeInterval = 60

    private func isTombstoned(_ zone: SyncZone) -> Bool {
        guard case .project(let id) = zone, let store else {
            return false
        }
        return store.state.tombstones.contains(id)
    }

    /// Whether `id` belongs to something held back from syncing since it was queued. Tombstones always go.
    private func isHeldBackFromSending(_ id: SyncRecordID) -> Bool {
        guard let store else {
            return true
        }
        switch id.zone {
        case .project(let project):
            return store.state.deferred.contains(project) || store.state.detached.contains(project)
        case .library:
            return LibraryRecordCoder.tombstonedProject(id) == nil && (store.state.libraryDeferred || store.state.libraryDetached)
        }
    }

    func transport(didFetch zone: SyncFetchedZone) {
        deliveredZones.insert(zone.zone)
        apply(zone)
    }

    func transport(didDeleteZone zone: SyncZone, reason: SyncZoneDeletionReason) {
        zoneDeleted(zone, reason: reason)
    }

    func transportDidFinishFetching(wasWhole: Bool) {
        finishFetching(wasWhole: wasWhole)
    }

    /// Results that arrive while fetched changes wait in the background wait with them, in order (`HeldFetchEvent.sent`).
    func transport(didSend results: [SyncSendResult]) {
        guard heldEvents.isEmpty else {
            heldEvents.append(.sent(results))
            return
        }
        handleSent(results)
        store?.save()
    }

    /// Kept at once when nothing fetched waits to be applied, so what was sent isn't sent again after a quit; otherwise
    /// once the waiting changes are applied (`finishFetching`).
    func transport(didUpdateState state: Data) {
        guard let store else {
            return
        }
        if isHoldingFetchedChanges {
            unsavedTransportState = state
        } else {
            store.update { $0.transportState = state }
            unsavedTransportState = nil
        }
    }

    /// Changes dropped undelivered are fetched again whole (`syncNow`); a fetch that merely failed says so in Settings.
    func transportFetchFailed(_ message: String, lostChanges: Bool) {
        if lostChanges {
            refetchAfterFailure()
        } else {
            reportFailure(message)
        }
    }

    func transportAccountDidChange() {
        Task { await connect() }
    }
}
