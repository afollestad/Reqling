import Foundation

/// `RequestRunner`'s path to `ResponseCache`, which takes saves off the main actor.
///
/// Saving JSON-encodes the whole exchange, body included, so a multi-megabyte response held the main actor until its
/// file was written. Only `save` is deferred, onto one serial queue that also keeps the outcome index's
/// read-modify-write from losing an update. Everything else runs synchronously behind any save still queued:
///
/// - `remove` and `removeAll` are on disk by the time they return. `RequestRunner.forget` relies on that, as does code
///   that seeds the cache directly right after it (tests, through their own `ResponseCache`), and a deleted project
///   must leave nothing behind.
/// - `load` and `outcomes` never miss a save that was queued before them, nor see one that was forgotten after.
final class ResponseCacheWriter: Sendable {
    private let cache: ResponseCache
    private let queue = DispatchQueue(label: "com.afollestad.reqling.response-cache", qos: .utility)

    init(cache: ResponseCache) {
        self.cache = cache
    }

    func save(_ exchange: RequestExchange) {
        queue.async { [cache] in
            cache.save(exchange)
        }
    }

    func load(_ request: RequestNodeID, in project: ProjectID) -> RequestExchange? {
        queue.sync { cache.load(request, in: project) }
    }

    func outcomes(in project: ProjectID) -> [RequestNodeID: RunOutcomeKind] {
        queue.sync { cache.outcomes(in: project) }
    }

    func remove(_ request: RequestNodeID, in project: ProjectID) {
        queue.sync { cache.remove(request, in: project) }
    }

    func removeAll(in project: ProjectID) {
        queue.sync { cache.removeAll(in: project) }
    }

    /// Waits for every queued save, as on quit, where the process could otherwise exit mid-write.
    func flush() {
        queue.sync {}
    }
}
