import CloudKit
import Foundation

/// Sync's iCloud side: the private database through `CKSyncEngine`, which keeps change tokens and the send queue in
/// its state, retries what the network drops, and fetches when another Mac's change is pushed.
///
/// The engine runs on its own schedule, so this holds it to `SyncTransport`'s terms:
/// - Each record change goes out only as `shouldSend` allows when the engine asks for a batch; zone saves and
///   deletions, which the engine sends without asking, are handed to it only once allowed (`releaseZoneChanges`).
/// - A zone's fetched records are delivered once its fetch completes, and the engine's state is reported only after a
///   fetch, never while a zone it covers is half delivered.
/// - A fetch from no state is whole only when every zone it named arrived complete; one that fell short asks for a
///   refetch instead, since the engine's tokens may have moved past what was dropped.
@MainActor
final class CloudKitSyncTransport: SyncTransport {
    /// Setting it to `nil` stops the engine, so nothing fetches or sends for a coordinator that stopped.
    weak var delegate: (any SyncTransportDelegate)? {
        didSet {
            if delegate == nil {
                stopEngine()
            }
        }
    }

    private let container: CKContainer
    private var engine: CKSyncEngine?
    /// The engine holds its delegate weakly, so this keeps it alive for as long as the engine runs.
    private var engineDelegate: CloudKitEngineDelegate?
    /// The record and zone changes handed to the engine and not yet reported sent, in order. The engine clears its queue
    /// when it notices an account change, which may be the account it started with; see `accountChanged`.
    private var handedOver: [CKSyncEngine.PendingRecordZoneChange] = []
    private var handedOverZones: [CKSyncEngine.PendingDatabaseChange] = []
    /// The most a batch may carry, kept under the server's per-request limits; halved after a batch is refused as too
    /// large, which an estimate that ran short can cause.
    private var batchBytes = CloudKitRecords.batchByteLimit
    /// Counts engines, so events from one replaced since are dropped.
    private(set) var generation = 0
    /// Whether the engine started from no state and hasn't fetched since: its next fetch is whole.
    var startsFresh = false
    /// The account `accountID()` last read, so the engine announcing it as it starts fresh isn't taken for a change.
    private var account: String?
    /// Zone saves and deletions not yet handed to the engine, in the order queued.
    private var heldZoneChanges: [SyncPendingChange] = []
    /// What the fetch under way has delivered so far.
    var fetch: CloudKitFetchAssembly?
    /// How sync's own fetch ended, held until its call returns: a fetch that fails may still end with nothing delivered,
    /// which taken as whole would read as all of iCloud's data deleted.
    var unconfirmed: (outcome: CloudKitFetchAssembly.Outcome, isWhole: Bool)?
    /// What the engine reported while `unconfirmed` waited, handled once it's settled, so that fetch's end is judged
    /// with only its own zones delivered (`LibrarySync.deliveredZones`), not a later fetch's.
    var waitingEvents: [CKSyncEngine.Event] = []
    /// Whether `shouldSend` refused a change since the last fetch, which the end of the next one offers again.
    var refusedChanges = false
    /// Send results reported during a whole fetch, held until it ends: a zone sync saved meanwhile, which the fetch may
    /// not deliver, would otherwise read as deleted, or with nothing else delivered, as all of iCloud's data gone.
    private var heldResults: [[SyncSendResult]] = []
    private var accountObserver: (any NSObjectProtocol)?

    init(containerIdentifier: String = SyncAvailability.containerIdentifier) {
        container = CKContainer(identifier: containerIdentifier)
        // A running engine reports account changes itself; this covers signing in while none runs, as when signed out.
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in
                if let self, self.engine == nil {
                    self.delegate?.transportAccountDidChange()
                }
            }
        }
    }

    // MARK: - SyncTransport

    /// `nil` when signed out, or when restricted, as by Screen Time, which is as good as signed out; throws when the
    /// account can't be read for now.
    func accountID() async throws -> String? {
        switch try await container.accountStatus() {
        case .available:
            let id = try await container.userRecordID().recordName
            account = id
            return id
        case .noAccount, .restricted:
            account = nil
            return nil
        default:
            throw CKError(.accountTemporarilyUnavailable)
        }
    }

    func start(with state: Data?) {
        let serialization = state.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        heldZoneChanges = []
        replaceEngine(from: serialization, carrying: nil)
    }

    /// With no engine running, signing in comes through as a change (`CKAccountChanged`).
    func stop() {
        heldZoneChanges = []
        stopEngine()
    }

    /// Queues every change in one pass, since the first sync queues the whole library at once: each record's last change
    /// wins and goes after everything already queued, cancelling one of the other kind, as a save cancels a deletion.
    func enqueue(_ changes: [SyncPendingChange]) {
        var records: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in changes {
            switch change {
            case .save(let id):
                records.append(.saveRecord(CloudKitRecords.recordID(id)))
            case .delete(let id):
                records.append(.deleteRecord(CloudKitRecords.recordID(id)))
            case .saveZone(let zone), .deleteZone(let zone):
                // The last word on a zone wins, so a save and a deletion queued together never both go out.
                heldZoneChanges.removeAll { $0.zone == zone }
                let zoneID = CloudKitRecords.zoneID(zone)
                engine?.state.remove(pendingDatabaseChanges: engine?.state.pendingDatabaseChanges.filter { $0.zoneID == zoneID } ?? [])
                handedOverZones.removeAll { $0.zoneID == zoneID }
                heldZoneChanges.append(change)
            }
        }
        if let engine, !records.isEmpty {
            var last: [CKRecord.ID: Int] = [:]
            for (index, change) in records.enumerated() {
                last[change.recordID] = index
            }
            let latest = records.enumerated().filter { last[$0.element.recordID] == $0.offset }.map(\.element)
            engine.state.remove(pendingRecordZoneChanges: latest.flatMap { [.saveRecord($0.recordID), .deleteRecord($0.recordID)] })
            engine.state.add(pendingRecordZoneChanges: latest)
            handedOver.removeAll { last[$0.recordID] != nil }
            handedOver += latest
        }
        releaseZoneChanges()
    }

    func cancelPending(in zone: SyncZone) {
        heldZoneChanges.removeAll { $0.zone == zone }
        guard let engine else {
            return
        }
        let zoneID = CloudKitRecords.zoneID(zone)
        engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges.filter { $0.recordID.zoneID == zoneID })
        engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges.filter { $0.zoneID == zoneID })
        handedOver.removeAll { $0.recordID.zoneID == zoneID }
        handedOverZones.removeAll { $0.zoneID == zoneID }
    }

    /// Fetches now, reporting the end only once the engine says the fetch succeeded (`unconfirmed`).
    func fetchChanges() async {
        guard let engine else {
            return
        }
        let generation = generation
        do {
            try await engine.fetchChanges()
            if generation == self.generation {
                confirmFetch()
            }
        } catch {
            if generation == self.generation {
                failFetch(error)
            }
        }
    }

    func sendChanges() async {
        guard let engine else {
            return
        }
        let generation = generation
        releaseZoneChanges()
        do {
            try await engine.sendChanges()
        } catch {
            if generation == self.generation {
                delegate?.transport(didSend: [.failed(nil, CloudKitRecords.describe(error))])
            }
        }
    }

    /// A new engine from no state, which fetches everything; what's queued moves over to it.
    func resetState() {
        guard let engine else {
            return
        }
        // What was sent during a whole fetch is real, so it's handed over rather than lost with the engine.
        releaseHeldResults()
        replaceEngine(from: nil, carrying: (engine.state.pendingRecordZoneChanges, engine.state.pendingDatabaseChanges))
    }

    // MARK: - Engines

    private func replaceEngine(
        from serialization: CKSyncEngine.State.Serialization?,
        carrying pending: ([CKSyncEngine.PendingRecordZoneChange], [CKSyncEngine.PendingDatabaseChange])?
    ) {
        stopEngine()
        startsFresh = serialization == nil
        let delegate = CloudKitEngineDelegate(transport: self, generation: generation)
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: delegate
        )
        configuration.automaticallySync = true
        let engine = CKSyncEngine(configuration)
        if let (records, zones) = pending {
            engine.state.add(pendingDatabaseChanges: zones)
            engine.state.add(pendingRecordZoneChanges: records)
            handedOver = records
            handedOverZones = zones
        } else {
            // A queue restored with the state could hold a deletion since withdrawn, or one for a project removed
            // since; sync queues afresh what it still owes as it connects (`LibrarySync.resume`), as when the state
            // couldn't be saved at all.
            engine.state.remove(pendingRecordZoneChanges: engine.state.pendingRecordZoneChanges)
            engine.state.remove(pendingDatabaseChanges: engine.state.pendingDatabaseChanges)
        }
        engineDelegate = delegate
        self.engine = engine
    }

    /// Ends the engine in use; anything it still reports is dropped.
    private func stopEngine() {
        generation += 1
        fetch = nil
        refusedChanges = false
        if let engine {
            Task {
                await engine.cancelOperations()
            }
        }
        engine = nil
        engineDelegate = nil
        handedOver = []
        handedOverZones = []
        heldResults = []
        unconfirmed = nil
        waitingEvents = []
    }

    /// Hands the engine the zone changes `shouldSend` allows now; the rest wait for the next send or fetch.
    func releaseZoneChanges() {
        guard let engine, let delegate, !heldZoneChanges.isEmpty, !isFetchingWhole else {
            return
        }
        var released: [CKSyncEngine.PendingDatabaseChange] = []
        heldZoneChanges.removeAll { change in
            guard delegate.shouldSend(change) else {
                return false
            }
            switch change {
            case .saveZone(let zone):
                released.append(.saveZone(CKRecordZone(zoneID: CloudKitRecords.zoneID(zone))))
            case .deleteZone(let zone):
                released.append(.deleteZone(CloudKitRecords.zoneID(zone)))
            case .save, .delete:
                break
            }
            return true
        }
        engine.state.add(pendingDatabaseChanges: released)
        handedOverZones += released
    }

    // MARK: - Sending

    /// The engine's next batch: what `shouldSend` allows of what's pending, in the order queued, up to the server's
    /// per-request limits, which the engine leaves to whoever builds the batch. A change in a zone Reqling never writes is
    /// dropped.
    func nextBatch(
        _ context: CKSyncEngine.SendChangesContext,
        engine: CKSyncEngine,
        from generation: Int
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        guard generation == self.generation, let delegate else {
            return nil
        }
        // Nothing goes out while a whole fetch runs; its end offers what waited (`heldResults`).
        guard !isFetchingWhole else {
            refusedChanges = true
            return nil
        }
        var saves: [CKRecord] = []
        var deletions: [CKRecord.ID] = []
        var bytes = 0
        var foreign: [CKSyncEngine.PendingRecordZoneChange] = []
        for change in engine.state.pendingRecordZoneChanges where context.options.scope.contains(change) {
            guard let id = CloudKitRecords.syncID(change.recordID) else {
                foreign.append(change)
                continue
            }
            guard delegate.shouldSend(change.isDeletion ? .delete(id) : .save(id)) else {
                refusedChanges = true
                continue
            }
            // Deletions are tiny; a save counts its encrypted fields. The first change always goes, however large.
            let record = change.isDeletion ? nil : self.record(for: change.recordID)
            let size = record.map(CloudKitRecords.estimatedSize) ?? CloudKitRecords.deletionSize
            let isFull = saves.count + deletions.count >= CloudKitRecords.batchItemLimit || bytes + size > batchBytes
            if isFull, !saves.isEmpty || !deletions.isEmpty {
                break
            }
            if let record {
                saves.append(record)
            } else if change.isDeletion {
                deletions.append(change.recordID)
            } else {
                continue
            }
            bytes += size
        }
        engine.state.remove(pendingRecordZoneChanges: foreign)
        guard !saves.isEmpty || !deletions.isEmpty else {
            return nil
        }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: saves, recordIDsToDelete: deletions, atomicByZone: false)
    }

    /// The record to save for `recordID`, built now; one this Mac no longer has drops its change.
    private func record(for recordID: CKRecord.ID) -> CKRecord? {
        guard let delegate, let id = CloudKitRecords.syncID(recordID) else {
            return nil
        }
        guard let record = delegate.record(for: id) else {
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            handedOver.removeAll { $0 == .saveRecord(recordID) }
            return nil
        }
        return CloudKitRecords.ckRecord(record)
    }

    // MARK: - Events

    func handle(_ event: CKSyncEngine.Event, from generation: Int) {
        guard generation == self.generation else {
            return
        }
        guard unconfirmed == nil else {
            waitingEvents.append(event)
            return
        }
        switch event {
        case .stateUpdate(let update):
            stateChanged(update.stateSerialization)
        case .accountChange(let change):
            accountChanged(change.changeType)
        case .fetchedDatabaseChanges(let changes):
            fetchedDatabaseChanges(changes)
        case .fetchedRecordZoneChanges(let changes):
            fetchedRecordZoneChanges(changes)
        case .sentDatabaseChanges(let sent):
            let reported = Set(sent.savedZones.map(\.zoneID) + sent.failedZoneSaves.map(\.zone.zoneID)
                + sent.deletedZoneIDs + Array(sent.failedZoneDeletes.keys))
            handedOverZones.removeAll { reported.contains($0.zoneID) }
            reportSent(CloudKitSendResults.results(sent))
        case .sentRecordZoneChanges(let sent):
            sentRecordZoneChanges(sent)
        case .willFetchChanges:
            beginFetch()
        case .willFetchRecordZoneChanges(let zone):
            beginZone(zone.zoneID)
        case .didFetchRecordZoneChanges(let zone):
            finishZone(zone.zoneID, failed: zone.error != nil)
        case .didFetchChanges(let done):
            finishFetch(asked: done.context.reason == .manual)
        case .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    private func stateChanged(_ serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else {
            return
        }
        if fetch != nil {
            fetch?.state = data
        } else {
            delegate?.transport(didUpdateState: data)
        }
    }

    /// Signing in as the account just read is the engine starting fresh, not a change. The engine clears its queue on any
    /// account change, so what was handed to it is handed over again, in order.
    private func accountChanged(_ change: CKSyncEngine.Event.AccountChange.ChangeType) {
        guard case .signIn(let user) = change, user.recordName == account else {
            delegate?.transportAccountDidChange()
            return
        }
        guard let engine else {
            return
        }
        // The engine announces an account only when its state had none, so whatever it fetches next is from the start.
        if fetch == nil {
            startsFresh = true
        }
        let pending = Set(engine.state.pendingRecordZoneChanges)
        engine.state.add(pendingDatabaseChanges: handedOverZones.filter { !engine.state.pendingDatabaseChanges.contains($0) })
        engine.state.add(pendingRecordZoneChanges: handedOver.filter { !pending.contains($0) })
    }

    /// Reports what was sent; a batch refused as too large for the request, not for any one record, makes the next
    /// smaller.
    private func sentRecordZoneChanges(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        let reported = Set(sent.savedRecords.map(\.recordID) + sent.failedRecordSaves.map(\.record.recordID)
            + sent.deletedRecordIDs + Array(sent.failedRecordDeletes.keys))
        handedOver.removeAll { reported.contains($0.recordID) }
        // A record refused alone is too large on its own, whatever its estimate said.
        let alone = sent.failedRecordSaves.count == 1 && sent.savedRecords.isEmpty && sent.deletedRecordIDs.isEmpty
            && sent.failedRecordDeletes.isEmpty
        // Saves refused only because their batch overflowed go again, in smaller batches, unreported: the engine drops them.
        let overflowed = alone ? [] : sent.failedRecordSaves.filter { failure in
            failure.error.code == .limitExceeded && CloudKitRecords.estimatedSize(failure.record) <= CloudKitRecords.recordByteLimit
        }.map(\.record.recordID)
        if !overflowed.isEmpty, let engine {
            batchBytes = max(batchBytes / 2, CloudKitRecords.recordByteLimit / 4)
            let requeued = overflowed.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0) }
            engine.state.add(pendingRecordZoneChanges: requeued)
            handedOver += requeued
        }
        let resent = Set(overflowed.compactMap(CloudKitRecords.syncID))
        reportSent(CloudKitSendResults.results(sent, alone: alone).filter { result in
            guard case .failed(let id?, _) = result else {
                return true
            }
            return !resent.contains(id)
        })
    }

    /// Hands send results to sync, or holds them while a whole fetch runs (`heldResults`).
    private func reportSent(_ results: [SyncSendResult]) {
        if isFetchingWhole {
            heldResults.append(results)
        } else {
            delegate?.transport(didSend: results)
        }
    }

    /// Hands over what was held while a whole fetch ran, now that it ended.
    func releaseHeldResults() {
        let held = heldResults
        heldResults = []
        for results in held {
            delegate?.transport(didSend: results)
        }
    }
}
