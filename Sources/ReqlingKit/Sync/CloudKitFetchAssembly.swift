import Foundation

/// One fetch's changes as `CKSyncEngine` reports them, piece by piece, assembled into what `SyncTransport` promises: a
/// zone delivered only once its fetch completed, the engine's state held until the fetch ends, and a fetch from no
/// state counted whole only when every zone it named arrived complete.
///
/// Kept apart from `CloudKitSyncTransport` so it can be tested: the engine's events can't be made outside CloudKit.
struct CloudKitFetchAssembly {
    /// How a fetch ended.
    struct Outcome: Equatable {
        /// A whole fetch's zones, delivered only once all arrived complete, so one that fails, or reports a zone twice,
        /// applies none of them: a whole zone reads what it lacks as deleted.
        var zones: [SyncFetchedZone] = []
        /// The engine's latest state, to report now that what it covers is delivered.
        let state: Data?
        let wasWhole: Bool
        /// Whether changes it fetched were dropped undelivered, which only a fetch from the start brings back, since the
        /// engine's tokens may have moved past them.
        let lostChanges: Bool
    }

    let isWhole: Bool
    /// Each zone fetched but not yet complete.
    private var zones: [SyncZone: SyncFetchedZone] = [:]
    /// The zones the database's changes named, every one of which a whole fetch must deliver.
    private var named: Set<SyncZone> = []
    private var delivered: Set<SyncZone> = []
    /// A whole fetch's completed zones, held for `Outcome.zones`.
    private var completed: [SyncFetchedZone] = []
    private var failed = false
    /// The engine's latest state.
    var state: Data?
    /// How many of the engine's fetches this joins, begun and not yet ended; the SDK promises one end for each begin. A
    /// fresh engine schedules one of its own as it starts, which runs alongside the one sync asks for, so the two are
    /// one fetch, ending when both have.
    private var open = 0
    /// Whether a fetch sync asked for ended among those joined, so this one is sync's whichever ends last. Without one,
    /// it's the engine's own, never taken as whole: ending while sync's call is out doesn't make it that call's.
    private(set) var isAsked = false

    init(isWhole: Bool) {
        self.isWhole = isWhole
    }

    /// A fetch the engine began, joined to this one.
    mutating func join() {
        open += 1
    }

    /// A fetch the engine ended, `asked` when sync asked for it; whether this one ends with it, none it joined still open.
    mutating func leave(asked: Bool) -> Bool {
        open = max(open - 1, 0)
        isAsked = isAsked || asked
        return open == 0
    }

    mutating func name(_ zone: SyncZone) {
        named.insert(zone)
    }

    /// A zone's fetch began; one that ends with no changes still delivers, empty. A whole zone arrives once: a second,
    /// partial delivery would read what it lacks as deleted, so the fetch falls short instead.
    mutating func begin(_ zone: SyncZone) {
        guard zones[zone] == nil else {
            return
        }
        if isWhole, delivered.contains(zone) {
            failed = true
            return
        }
        zones[zone] = SyncFetchedZone(zone: zone, changed: [], deleted: [], isWhole: isWhole)
    }

    /// The latest word on each record wins, should the engine report one twice.
    mutating func changed(_ record: SyncRecord) {
        let zone = record.id.zone
        begin(zone)
        zones[zone]?.deleted.removeAll { $0 == record.id }
        zones[zone]?.changed.removeAll { $0.id == record.id }
        zones[zone]?.changed.append(record)
    }

    mutating func deleted(_ id: SyncRecordID) {
        begin(id.zone)
        zones[id.zone]?.changed.removeAll { $0.id == id }
        zones[id.zone]?.deleted.removeAll { $0 == id }
        zones[id.zone]?.deleted.append(id)
    }

    /// The zone to deliver now that its fetch completed; `nil` when it failed, which drops what it held, or never began
    /// here, as one begun before a failed fetch was dropped, which would arrive incomplete. A whole fetch's zones wait for the
    /// end instead (`Outcome.zones`).
    mutating func finish(_ zone: SyncZone, failed zoneFailed: Bool) -> SyncFetchedZone? {
        guard let fetched = zones.removeValue(forKey: zone) else {
            failed = true
            return nil
        }
        guard !zoneFailed else {
            failed = true
            return nil
        }
        delivered.insert(zone)
        guard !isWhole else {
            completed.append(fetched)
            return nil
        }
        return fetched
    }

    /// Whether ending the fetch here, unfinished, drops changes the engine may be past: a zone's that began, or a whole
    /// fetch's once the account's zones were named. One that ended before either fetches the same next time.
    var dropsChangesIfAbandoned: Bool {
        failed || !zones.isEmpty || !delivered.isEmpty || (isWhole && !named.isEmpty)
    }

    /// The fetch ended. Changes pushed while it ran may wait for the next fetch; a whole one is complete all the same
    /// once each zone it named arrived, since none it leaves out still exists.
    func finish() -> Outcome {
        let lost = failed || !zones.isEmpty
        let complete = !lost && named.isSubset(of: delivered)
        return Outcome(
            zones: complete ? completed : [],
            state: state,
            wasWhole: isWhole && complete,
            lostChanges: lost || (isWhole && !complete)
        )
    }
}
