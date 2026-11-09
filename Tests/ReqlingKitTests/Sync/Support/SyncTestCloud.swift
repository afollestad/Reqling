import Foundation
@testable import ReqlingKit

/// An in-memory iCloud private database shared by the test Macs: records carry change tags, saves that expected an
/// older tag conflict, a save into a missing zone fails, and every change gets a sequence number fetches read from.
@MainActor
final class SyncTestCloud {
    var account: String? = "account-a"
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
    var clock = Date(timeIntervalSince1970: 1_000_000)

    func record(_ id: SyncRecordID) -> SyncRecord? {
        records[id]
    }

    func save(_ record: SyncRecord) -> SyncSendResult {
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
        // A server clock at least as late as the edit, as a real one would be.
        clock = max(clock, record.editedAt)
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

    init(cloud: SyncTestCloud) {
        self.cloud = cloud
    }

    func accountID() async throws -> String? {
        cloud.account
    }

    func start(with state: Data?) {
        seen = state.flatMap { String(bytes: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
    }

    func enqueue(_ changes: [SyncPendingChange]) {
        for change in changes {
            pending.removeAll { $0 == change || $0.isOpposite(of: change) }
            pending.append(change)
        }
    }

    /// Sends until nothing is queued, as `CKSyncEngine` keeps sending what its delegate queues in response.
    func sendChanges() async {
        for _ in 0..<10 where !pending.isEmpty {
            let batch = pending.sorted { $0.sendOrder < $1.sendOrder }
            pending = []
            var results: [SyncSendResult] = []
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
            delegate?.transport(didSend: results)
        }
    }

    func fetchChanges() async {
        for entry in cloud.zoneLog where entry.sequence > seen && !cloud.zones.contains(entry.zone) {
            delegate?.transport(didDeleteZone: entry.zone, reason: entry.reason)
        }
        var changed: [SyncZone: Set<SyncRecordID>] = [:]
        for entry in cloud.recordLog where entry.sequence > seen && cloud.zones.contains(entry.id.zone) {
            changed[entry.id.zone, default: []].insert(entry.id)
        }
        for (zone, ids) in changed.sorted(by: { $0.key.name < $1.key.name }) {
            let sorted = ids.sorted { $0.description < $1.description }
            delegate?.transport(didFetch: SyncFetchedZone(
                zone: zone,
                changed: sorted.compactMap { cloud.record($0) },
                deleted: sorted.filter { cloud.record($0) == nil }
            ))
        }
        seen = cloud.sequence
        delegate?.transport(didUpdateState: Data(String(seen).utf8))
        delegate?.transportDidFinishFetching()
    }

    func resetState() {
        seen = 0
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
