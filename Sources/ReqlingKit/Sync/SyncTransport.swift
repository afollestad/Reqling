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
    /// Saved; the record carries the `editedAt` sent, and the server's new version, modification time, and whole
    /// secrets field, or `nil` when this save left that field as it was.
    case saved(SyncRecord)
    /// Deleted, or already gone.
    case deleted(SyncRecordID)
    case zoneSaved(SyncZone)
    /// Refused for a reason the transport won't retry, as a full quota: its records wait too, rather than each
    /// queuing the zone again.
    case zoneSaveFailed(SyncZone, String)
    /// Deleted, or already gone; otherwise the deletion would be queued again on every connection.
    case zoneDeleted(SyncZone)
    /// Another Mac saved first; this is the server's record.
    case conflict(SyncRecordID, server: SyncRecord)
    case zoneMissing(SyncRecordID)
    /// The server no longer has the record this save expected.
    case missingOnServer(SyncRecordID)
    case tooLarge(SyncRecordID)
    /// Worth trying again later: the network, a quota, a busy server.
    case failed(SyncRecordID?, String)

    /// The record this result is about, if one.
    var recordID: SyncRecordID? {
        switch self {
        case .saved(let record): record.id
        case .deleted(let id), .conflict(let id, _), .zoneMissing(let id), .missingOnServer(let id), .tooLarge(let id): id
        case .failed(let id, _): id
        case .zoneSaved, .zoneDeleted, .zoneSaveFailed: nil
        }
    }
}

/// Changes fetched for one zone, delivered once its fetch completes.
struct SyncFetchedZone: Equatable, Sendable {
    let zone: SyncZone
    var changed: [SyncRecord]
    var deleted: [SyncRecordID]
    /// Whether this came from a fetch from the start, so `changed` is every record the zone holds and `deleted` is empty:
    /// such a fetch reports no deletions, so whatever this Mac synced that's missing from it was deleted. A whole fetch
    /// delivers each zone that exists once, with all its records, from a snapshot no older than any save already
    /// reported, or what it leaves out is deleted here.
    var isWhole = false
}

/// The iCloud side of sync: `CloudKitSyncTransport` in the app, an in-memory server in tests. Records reach the server
/// with every field encrypted, a `nil` `secrets` left out rather than written empty; a fetched record whose type or
/// fields this version can't read arrives as one from a newer version (`SyncRecord.schemaVersion`), never dropped.
@MainActor
protocol SyncTransport: AnyObject {
    /// Told nothing once set to `nil`, which stopping does.
    var delegate: (any SyncTransportDelegate)? { get set }
    /// The signed-in account's stable identifier, or `nil` when no account is signed in; throws when it can't be read.
    func accountID() async throws -> String?
    /// Begins syncing the signed-in account from `state`, what `transport(didUpdateState:)` last reported, replacing
    /// whatever ran for a previous account, whose results are never reported after.
    func start(with state: Data?)
    /// Ends whatever runs, its queue included, so nothing syncs for an account until `start(with:)` is called again.
    func stop()
    /// Queues `changes`, sending each zone's in the order queued, across batches too. Saving a record cancels a queued
    /// deletion of it, and the reverse.
    func enqueue(_ changes: [SyncPendingChange])
    /// Drops whatever is queued for `zone`, for a project gone before it was sent.
    func cancelPending(in zone: SyncZone)
    func fetchChanges() async
    func sendChanges() async
    /// Fetches over from the start, so the next fetch is whole: everything that exists, and no deletion; what's queued to
    /// send stays queued.
    func resetState()
}

@MainActor
protocol SyncTransportDelegate: AnyObject {
    /// The record to send for `id` as this Mac holds it now, or `nil` when it no longer exists, which drops the change.
    func record(for id: SyncRecordID) -> SyncRecord?
    /// Whether `change` may go out now. The transport asks before sending each change, whoever started the send, keeps
    /// one refused queued, and offers it again once a fetch finishes.
    func shouldSend(_ change: SyncPendingChange) -> Bool
    func transport(didFetch zone: SyncFetchedZone)
    func transport(didDeleteZone zone: SyncZone, reason: SyncZoneDeletionReason)
    /// A fetch finished: every zone it touched has been delivered. `wasWhole` when it fetched from the start, as after
    /// `resetState`, or as the server can require, so its zones are complete and any other zone synced before is gone.
    func transportDidFinishFetching(wasWhole: Bool)
    func transport(didSend results: [SyncSendResult])
    /// A fetch failed, as when the network dropped. With `lostChanges`, changes it fetched were dropped undelivered,
    /// which the next incremental fetch won't bring again, so everything must be fetched again.
    func transportFetchFailed(_ message: String, lostChanges: Bool)
    /// The transport's state changed; persist it once what it covers is applied. Reported only between fetches, never
    /// while a zone it covers is still being delivered.
    func transport(didUpdateState state: Data)
    func transportAccountDidChange()
}
