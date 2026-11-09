import Foundation
@testable import ReqlingKit

/// An in-memory iCloud private database shared by the test Macs: records carry change tags, saves that expected an
/// older tag conflict, a save into a missing zone fails, and every change gets a sequence number fetches read from.
@MainActor
final class SyncTestCloud {
    var account: String? = "account-a"
    /// What reading the account throws, as when iCloud can't be reached.
    var accountFailure: (any Error)?
    private(set) var zones: Set<SyncZone> = []
    private(set) var records: [SyncRecordID: SyncRecord] = [:]
    struct ZoneDeletion {
        let sequence: Int
        let zone: SyncZone
        let reason: SyncZoneDeletionReason
    }

    /// Each record change by sequence, and each zone deletion with its reason.
    private(set) var recordLog: [(sequence: Int, id: SyncRecordID)] = []
    private(set) var zoneLog: [ZoneDeletion] = []
    private(set) var sequence = 0
    /// The server's clock, which is also the true time each test Mac's clock is offset from (`SyncTestMac.clock`).
    var clock = Date(timeIntervalSince1970: 1_000_000)
    /// The largest payload a save accepts, in bytes; larger ones are refused as too large.
    var payloadLimit: Int?
    /// Why every save fails, as a full quota fails them, which drops them from the queue as iCloud does.
    var saveFailure: String?
    private(set) var saveAttempts: [SyncRecordID: Int] = [:]

    func record(_ id: SyncRecordID) -> SyncRecord? {
        records[id]
    }

    func save(_ record: SyncRecord) -> SyncSendResult {
        saveAttempts[record.id, default: 0] += 1
        if let saveFailure {
            return .failed(record.id, saveFailure)
        }
        if let payloadLimit, record.payload.prettyPrinted().utf8.count > payloadLimit {
            return .tooLarge(record.id)
        }
        guard zones.contains(record.id.zone) else {
            return .zoneMissing(record.id)
        }
        if let existing = records[record.id] {
            guard record.systemFields == existing.systemFields else {
                return .conflict(record.id, server: existing)
            }
        } else if record.systemFields != nil {
            return .missingOnServer(record.id)
        }
        sequence += 1
        var saved = record
        // As CloudKit does, a field left out of a save keeps the server's value.
        if saved.secrets == nil {
            saved.secrets = records[record.id]?.secrets
        }
        saved.systemFields = Data("tag-\(sequence)".utf8)
        saved.serverModifiedAt = clock
        records[record.id] = saved
        recordLog.append((sequence, record.id))
        return .saved(saved)
    }

    func delete(_ id: SyncRecordID) -> SyncSendResult {
        records[id] = nil
        sequence += 1
        recordLog.append((sequence, id))
        return .deleted(id)
    }

    func saveZone(_ zone: SyncZone) -> SyncSendResult {
        zones.insert(zone)
        return .zoneSaved(zone)
    }

    func deleteZone(_ zone: SyncZone, reason: SyncZoneDeletionReason = .deleted) -> SyncSendResult {
        zones.remove(zone)
        records = records.filter { $0.key.zone != zone }
        sequence += 1
        zoneLog.append(ZoneDeletion(sequence: sequence, zone: zone, reason: reason))
        return .zoneDeleted(zone)
    }

    /// What deleting Reqling's data in System Settings, or resetting encrypted data, does.
    func wipe(reason: SyncZoneDeletionReason) {
        for zone in zones {
            _ = deleteZone(zone, reason: reason)
        }
    }
}

/// One Mac's connection to `SyncTestCloud`, sending and fetching only when a test says so.
@MainActor
final class SyncTestTransport: SyncTransport {
    weak var delegate: (any SyncTransportDelegate)?
    let cloud: SyncTestCloud
    private(set) var pending: [SyncPendingChange] = []
    private var seen = 0
    /// How often sync asked to fetch over from the start.
    private(set) var resets = 0
    /// Whether a fetch from the start falls short, as one whose zone failed, rather than arriving whole.
    var fallsShort = false
    /// Whether a fetch from the start arrives but isn't reported whole, as when the engine folds it into one of its own.
    var foldsWhole = false
    /// Runs while a batch is out, after the server took it and before its results are reported.
    var whileSending: (() -> Void)?
    /// A zone the next fetch fails to deliver, as when its fetch failed, which drops its changes.
    var dropsZoneOnce: SyncZone?

    init(cloud: SyncTestCloud) {
        self.cloud = cloud
    }

    func accountID() async throws -> String? {
        if let failure = cloud.accountFailure {
            throw failure
        }
        return cloud.account
    }

    /// As `CKSyncEngine` does, starts from the persisted state alone: a queue that wasn't persisted is gone.
    func start(with state: Data?) {
        seen = state.flatMap { String(bytes: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
        pending = []
    }

    /// As `CKSyncEngine` does when it's released, drops the queue.
    func stop() {
        pending = []
    }

    func enqueue(_ changes: [SyncPendingChange]) {
        for change in changes {
            pending.removeAll { $0 == change || $0.isOpposite(of: change) }
            pending.append(change)
        }
    }

    func cancelPending(in zone: SyncZone) {
        pending.removeAll { change in
            switch change {
            case .saveZone(let pendingZone), .deleteZone(let pendingZone): pendingZone == zone
            case .save(let id), .delete(let id): id.zone == zone
            }
        }
    }

    /// Sends until nothing is queued, as `CKSyncEngine` keeps sending what its delegate queues in response.
    func sendChanges() async {
        for _ in 0..<10 where !pending.isEmpty {
            guard sendBatch() else {
                return
            }
        }
    }

    /// Sends up to `limit` of what's ready, in the order queued, as one of `CKSyncEngine`'s batches; `false` when nothing
    /// was ready.
    @discardableResult
    func sendBatch(limit: Int = .max) -> Bool {
        let ready = pending.filter { delegate?.shouldSend($0) ?? false }
        guard !ready.isEmpty else {
            return false
        }
        let batch = Array(ready.enumerated()
            .sorted { ($0.element.sendOrder, $0.offset) < ($1.element.sendOrder, $1.offset) }
            .map(\.element)
            .prefix(limit))
        pending.removeAll { batch.contains($0) }
        var results: [SyncSendResult] = []
        defer {
            // As `CKSyncEngine` does, what was sent leaves the queue as its results come back, with any equal change
            // queued while it was out; what the results handler queues stays.
            pending.removeAll { batch.contains($0) }
            delegate?.transport(didSend: results)
        }
        for change in batch {
            switch change {
            case .saveZone(let zone):
                results.append(cloud.saveZone(zone))
            case .save(let id):
                if let record = delegate?.record(for: id) {
                    results.append(cloud.save(record))
                }
            case .delete(let id):
                results.append(cloud.delete(id))
            case .deleteZone(let zone):
                results.append(cloud.deleteZone(zone))
            }
        }
        whileSending?()
        return true
    }

    /// As `CKSyncEngine` does, a fetch from no state is whole: it returns what exists, and no deletion of a zone or record.
    func fetchChanges() async {
        let isWhole = seen == 0
        if isWhole, fallsShort {
            delegate?.transportFetchFailed("Fell short", lostChanges: true)
            delegate?.transportDidFinishFetching(wasWhole: false)
            return
        }
        for entry in cloud.zoneLog where !isWhole && entry.sequence > seen && !cloud.zones.contains(entry.zone) {
            delegate?.transport(didDeleteZone: entry.zone, reason: entry.reason)
        }
        var changed: [SyncZone: Set<SyncRecordID>] = [:]
        for entry in cloud.recordLog where entry.sequence > seen && cloud.zones.contains(entry.id.zone) {
            if !isWhole || cloud.record(entry.id) != nil {
                changed[entry.id.zone, default: []].insert(entry.id)
            }
        }
        let dropped = dropsZoneOnce
        dropsZoneOnce = nil
        for (zone, ids) in changed.sorted(by: { $0.key.name < $1.key.name }) where zone != dropped {
            let sorted = ids.sorted { $0.description < $1.description }
            delegate?.transport(didFetch: SyncFetchedZone(
                zone: zone,
                changed: sorted.compactMap { cloud.record($0) },
                deleted: sorted.filter { cloud.record($0) == nil },
                isWhole: isWhole
            ))
        }
        // As with `CKSyncEngine`, the tokens move past a zone that failed, so its changes are lost to fetches from here.
        seen = cloud.sequence
        delegate?.transport(didUpdateState: Data(String(seen).utf8))
        if dropped != nil, changed[dropped ?? .library] != nil {
            delegate?.transportFetchFailed("Dropped", lostChanges: true)
            delegate?.transportDidFinishFetching(wasWhole: false)
            return
        }
        delegate?.transportDidFinishFetching(wasWhole: isWhole && !foldsWhole)
    }

    func resetState() {
        seen = 0
        resets += 1
    }
}

private extension SyncPendingChange {
    /// Zones exist before their records are saved, and go only after.
    var sendOrder: Int {
        switch self {
        case .saveZone: 0
        case .save, .delete: 1
        case .deleteZone: 2
        }
    }

    func isOpposite(of other: SyncPendingChange) -> Bool {
        switch (self, other) {
        case (.save(let saved), .delete(let deleted)), (.delete(let deleted), .save(let saved)): saved == deleted
        default: false
        }
    }
}
