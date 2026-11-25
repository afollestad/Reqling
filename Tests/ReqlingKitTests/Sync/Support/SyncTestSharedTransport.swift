import Foundation
@testable import ReqlingKit

/// A participant's shared database over another account's `SyncTestCloud`: the zones its owner shares with this
/// account and it accepted, written through as that owner's, within what each share allows, as CloudKit's shared
/// database does. Losing a zone, however its share ended, arrives as that zone's deletion.
@MainActor
final class SyncTestSharedTransport: SyncTransport {
    weak var delegate: (any SyncTransportDelegate)?
    /// The cloud of the account whose zones are shared.
    let owner: SyncTestCloud
    /// The participant's own cloud, whose account this is.
    let home: SyncTestCloud
    private(set) var pending: [SyncPendingChange] = []
    private var seen = 0
    /// The zones the last fetch reached, so the next can say which it no longer does.
    private var reached: Set<SyncZone> = []
    /// How often this account tried to save or delete a zone, which only its owner may.
    private(set) var zoneWrites = 0
    private(set) var resets = 0
    /// The account sync last started this for.
    private(set) var startedAccount: String?

    init(owner: SyncTestCloud, home: SyncTestCloud) {
        self.owner = owner
        self.home = home
    }

    private var account: String {
        home.account ?? ""
    }

    func accountID() async throws -> String? {
        if let failure = home.accountFailure {
            throw failure
        }
        return home.account
    }

    /// As `CKSyncEngine` does, starts from the persisted state alone.
    func start(with state: Data?, account: String?) {
        startedAccount = account
        let text = state.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
        let parts = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        seen = parts.first.flatMap { Int($0) } ?? 0
        reached = Set((parts.count > 1 ? parts[1] : "").split(separator: ",").compactMap { SyncZone(name: String($0)) })
        pending = []
    }

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

    func sendChanges() async {
        for _ in 0..<10 where !pending.isEmpty {
            let ready = pending.filter { delegate?.shouldSend($0) ?? false }
            guard !ready.isEmpty else {
                return
            }
            pending.removeAll { ready.contains($0) }
            delegate?.transport(didSend: ready.compactMap(send))
        }
    }

    /// What the server says to one change from this account.
    private func send(_ change: SyncPendingChange) -> SyncSendResult? {
        switch change {
        case .saveZone, .deleteZone:
            zoneWrites += 1
            return .failed(nil, "Only a zone's owner changes it.")
        case .save(let id):
            guard owner.reachable(by: account).contains(id.zone) else {
                return .zoneMissing(id)
            }
            guard owner.shares[id.zone]?[account]?.permission == .readWrite else {
                return .permissionDenied(id)
            }
            return delegate?.record(for: id).map(owner.save)
        case .delete(let id):
            guard owner.reachable(by: account).contains(id.zone) else {
                return .deleted(id)
            }
            if id.name == SyncRecordID.shareName {
                owner.leave(id.zone, account: account)
                return .deleted(id)
            }
            guard owner.shares[id.zone]?[account]?.permission == .readWrite else {
                return .permissionDenied(id)
            }
            return owner.delete(id)
        }
    }

    /// As `CKSyncEngine` does, a fetch from no state is whole: what's reachable, and no deletion.
    func fetchChanges() async {
        let isWhole = seen == 0
        let now = owner.reachable(by: account)
        if !isWhole {
            for zone in reached.subtracting(now).sorted(by: { $0.name < $1.name }) {
                delegate?.transport(didDeleteZone: zone, reason: .deleted)
            }
        }
        let sharesChanged = Set(owner.shareLog.filter { $0.sequence > seen }.map(\.zone))
        for zone in now.sorted(by: { $0.name < $1.name }) {
            let isNew = isWhole || !reached.contains(zone)
            if isNew || sharesChanged.contains(zone) {
                delegate?.transport(didUpdateShareOf: zone, to: owner.shareInfo(of: zone, for: account))
            }
            let ids = isNew
                ? Set(owner.records.keys.filter { $0.zone == zone })
                : Set(owner.recordLog.filter { $0.sequence > seen && $0.id.zone == zone }.map(\.id))
            guard isNew || !ids.isEmpty else {
                continue
            }
            let sorted = ids.sorted { $0.description < $1.description }
            delegate?.transport(didFetch: SyncFetchedZone(
                zone: zone,
                changed: sorted.compactMap { owner.record($0) },
                deleted: isNew ? [] : sorted.filter { owner.record($0) == nil },
                isWhole: isWhole
            ))
        }
        reached = now
        seen = owner.sequence
        let state = "\(seen);" + reached.map(\.name).sorted().joined(separator: ",")
        delegate?.transport(didUpdateState: Data(state.utf8))
        delegate?.transportDidFinishFetching(wasWhole: isWhole)
    }

    func resetState() {
        seen = 0
        resets += 1
    }
}
