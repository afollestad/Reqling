import Foundation

/// What sync asks the transport to send. Records are built only when the transport is ready to send them
/// (`SyncTransportDelegate.record(for:)`), from what this Mac holds then.
enum SyncPendingChange: Hashable, Sendable {
    case saveZone(SyncZone)
    case save(SyncRecordID)
    case delete(SyncRecordID)
    case deleteZone(SyncZone)
}

/// Why a zone disappeared from the server.
enum SyncZoneDeletionReason: Hashable, Sendable {
    /// Reqling deleted it, on some Mac.
    case deleted
    /// The account's owner deleted Reqling's data in System Settings.
    case purged
    /// The account's owner reset their end-to-end encrypted data.
    case encryptedDataReset
}

/// How sending one record went.
enum SyncSendResult: Sendable {
    /// Saved; the record carries the server's new version.
    case saved(SyncRecord)
    case deleted(SyncRecordID)
    case zoneSaved(SyncZone)
    case zoneDeleted(SyncZone)
    /// Another Mac saved first; this is the server's record.
    case conflict(SyncRecordID, server: SyncRecord)
    case zoneMissing(SyncRecordID)
    /// The server no longer has the record this save expected.
    case missingOnServer(SyncRecordID)
    case tooLarge(SyncRecordID)
    /// Worth trying again later: the network, a quota, a busy server.
    case failed(SyncRecordID?, String)
}

/// Changes fetched for one zone, delivered once its fetch completes.
struct SyncFetchedZone: Sendable {
    let zone: SyncZone
    var changed: [SyncRecord]
    var deleted: [SyncRecordID]
}

/// The iCloud side of sync: `CloudKitSyncTransport` in the app, an in-memory server in tests.
@MainActor
protocol SyncTransport: AnyObject {
    var delegate: (any SyncTransportDelegate)? { get set }
    /// The signed-in account's stable identifier, or `nil` when no account is signed in.
    func accountID() async throws -> String?
    /// Begins syncing the signed-in account from `state`, what `transport(didUpdateState:)` last reported.
    func start(with state: Data?)
    func enqueue(_ changes: [SyncPendingChange])
    func fetchChanges() async
    func sendChanges() async
    /// Starts over from no saved state, so the next fetch returns everything.
    func resetState()
}

@MainActor
protocol SyncTransportDelegate: AnyObject {
    /// The record to send for `id` as this Mac holds it now, or `nil` when it no longer exists.
    func record(for id: SyncRecordID) -> SyncRecord?
    func transport(didFetch zone: SyncFetchedZone)
    func transport(didDeleteZone zone: SyncZone, reason: SyncZoneDeletionReason)
    /// A fetch finished: every zone it touched has been delivered.
    func transportDidFinishFetching()
    func transport(didSend results: [SyncSendResult])
    /// The transport's state changed; persist it once what it covers is applied.
    func transport(didUpdateState state: Data)
    func transportAccountDidChange()
}
