import CloudKit
import Foundation

/// Hands the engine's calls to the transport on the main actor, tagged with the engine they came from.
final class CloudKitEngineDelegate: CKSyncEngineDelegate {
    let transport: CloudKitSyncTransport
    let generation: Int

    init(transport: CloudKitSyncTransport, generation: Int) {
        self.transport = transport
        self.generation = generation
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await transport.handle(event, from: generation)
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await transport.nextBatch(context, engine: syncEngine, from: generation)
    }
}

extension SyncPendingChange {
    var zone: SyncZone {
        switch self {
        case .saveZone(let zone), .deleteZone(let zone): zone
        case .save(let id), .delete(let id): id.zone
        }
    }
}

extension CKSyncEngine.PendingRecordZoneChange {
    var recordID: CKRecord.ID {
        switch self {
        case .saveRecord(let id), .deleteRecord(let id): id
        @unknown default: CKRecord.ID(recordName: "")
        }
    }

    var isDeletion: Bool {
        if case .deleteRecord = self {
            return true
        }
        return false
    }
}

extension CKSyncEngine.PendingDatabaseChange {
    var zoneID: CKRecordZone.ID {
        switch self {
        case .saveZone(let zone): zone.zoneID
        case .deleteZone(let id): id
        @unknown default: CKRecordZone.ID()
        }
    }
}
