import CloudKit
import Foundation

/// A fetch as the engine reports it, piece by piece, assembled (`CloudKitFetchAssembly`) and delivered on the terms
/// `SyncTransport` sets: each zone once complete, the engine's state once the fetch ends, whole only when nothing fell
/// short, and what was sent meanwhile only after a whole fetch ends.
extension CloudKitSyncTransport {
    func beginFetch() {
        if fetch != nil {
            // The last fetch never finished, so what it held back from delivery is lost to this engine.
            abandonFetch()
        }
        fetch = CloudKitFetchAssembly(isWhole: startsFresh)
    }

    /// The fetch under way, begun here should the engine report changes without announcing one first.
    func ensureFetch() {
        if fetch == nil {
            fetch = CloudKitFetchAssembly(isWhole: startsFresh)
        }
    }

    func fetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
        ensureFetch()
        for zone in changes.modifications.compactMap({ SyncZone(name: $0.zoneID.zoneName) }) {
            fetch?.name(zone)
        }
        for deletion in changes.deletions {
            if let zone = SyncZone(name: deletion.zoneID.zoneName) {
                delegate?.transport(didDeleteZone: zone, reason: CloudKitSendResults.reason(deletion.reason))
            }
        }
    }

    func beginZone(_ zoneID: CKRecordZone.ID) {
        ensureFetch()
        if let zone = SyncZone(name: zoneID.zoneName) {
            fetch?.begin(zone)
        }
    }

    func fetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        ensureFetch()
        for record in changes.modifications.compactMap({ CloudKitRecords.syncRecord($0.record) }) {
            fetch?.changed(record)
        }
        for id in changes.deletions.compactMap({ CloudKitRecords.syncID($0.recordID) }) {
            fetch?.deleted(id)
        }
    }

    /// Delivers a zone whose fetch completed; one that failed is dropped, and the fetch falls short.
    func finishZone(_ zoneID: CKRecordZone.ID, failed: Bool) {
        guard let zone = SyncZone(name: zoneID.zoneName), let fetched = fetch?.finish(zone, failed: failed) else {
            return
        }
        delegate?.transport(didFetch: fetched)
    }

    /// Whether a whole fetch is under way or awaiting its call's return, during which nothing is sent and what was sent
    /// waits (`heldResults`): a zone saved meanwhile, which the fetch may not deliver, would read as deleted.
    var isFetchingWhole: Bool {
        fetch?.isWhole == true || unconfirmed?.isWhole == true
    }

    /// The end of a fetch. One sync asked for waits for its call to return; one the engine ran on its own can't be known
    /// to have succeeded, so it's never taken as whole.
    func finishFetch(asked: Bool) {
        guard let finished = fetch else {
            return
        }
        fetch = nil
        startsFresh = false
        let outcome = finished.finish()
        guard asked else {
            report(outcome, asWhole: false)
            return
        }
        if let earlier = unconfirmed {
            report(earlier.outcome, asWhole: false)
        }
        unconfirmed = (outcome, finished.isWhole)
    }

    /// Sync's fetch succeeded: its end is reported as it came, or, should it have delivered nothing at all, as a fetch
    /// that found nothing new, which a deletion waiting for one may go after.
    func confirmFetch() {
        guard let confirmed = unconfirmed else {
            if fetch == nil {
                delegate?.transportDidFinishFetching(wasWhole: false)
            }
            return
        }
        unconfirmed = nil
        report(confirmed.outcome, asWhole: true)
        handleWaitingEvents()
    }

    /// Handles what the engine reported while a fetch's end waited, in order.
    func handleWaitingEvents() {
        let waiting = waitingEvents
        waitingEvents = []
        for (index, event) in waiting.enumerated() {
            handle(event, from: generation)
            if unconfirmed != nil {
                // Another fetch of sync's own ended among them; the rest wait for it in turn.
                waitingEvents = Array(waiting[(index + 1)...]) + waitingEvents
                return
            }
        }
    }

    /// Sync's fetch failed. Nothing it ended is reported, so a deletion waits for one that succeeds; what it held back,
    /// or failed to bring, is fetched again whole.
    func failFetch(_ error: any Error) {
        var lost = unconfirmed.map { $0.outcome.lostChanges || $0.isWhole } ?? false
        unconfirmed = nil
        if let fetch {
            self.fetch = nil
            // One that failed before reaching anything, as with no network, starts over as it was.
            if fetch.dropsChangesIfAbandoned {
                lost = true
                startsFresh = false
            }
        }
        delegate?.transportFetchFailed(lost ? Self.fellShort : CloudKitRecords.describe(error), lostChanges: lost)
        releaseHeldResults()
        releaseZoneChanges()
        handleWaitingEvents()
    }

    /// Reports the engine's state now that what it covers is delivered, then the end of the fetch, whole only when
    /// `asWhole` and nothing fell short.
    func report(_ outcome: CloudKitFetchAssembly.Outcome, asWhole: Bool) {
        for zone in outcome.zones {
            delegate?.transport(didFetch: zone)
        }
        if let state = outcome.state {
            delegate?.transport(didUpdateState: state)
        }
        if outcome.lostChanges {
            delegate?.transportFetchFailed(Self.fellShort, lostChanges: true)
        }
        delegate?.transportDidFinishFetching(wasWhole: asWhole && outcome.wasWhole)
        releaseHeldResults()
        releaseZoneChanges()
        if refusedChanges {
            refusedChanges = false
            Task {
                await sendChanges()
            }
        }
    }

    /// Drops a fetch that won't finish. What it held back may be behind the engine's tokens now, so everything is
    /// fetched again, unless nothing was.
    func abandonFetch() {
        let dropsChanges = fetch?.dropsChangesIfAbandoned ?? false
        fetch = nil
        startsFresh = false
        if dropsChanges {
            delegate?.transportFetchFailed(Self.fellShort, lostChanges: true)
        }
        releaseHeldResults()
    }

    static let fellShort = "Some changes from iCloud couldn't be fetched. Reqling fetches everything again."
}
