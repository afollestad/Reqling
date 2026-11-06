import Foundation

/// The newest entries of a live gRPC call or event stream, bounded by count and by bytes, so neither memory nor each
/// published record grows with the stream's length; the byte bound matters because the count alone allows thousands
/// of multi-megabyte messages.
///
/// Up to half again `limit` entries accumulate before a trim, so trimming (which shifts the array) happens once per many
/// entries rather than on each; `newest` always cuts to `limit`.
struct LiveWindow<Entry> {
    let limit: Int
    let byteLimit: Int
    /// What an entry holds in memory, which `byteLimit` bounds.
    private let size: (Entry) -> Int
    private var entries: [Entry] = []
    private var bytes = 0
    /// Oldest entries trimmed away.
    private var trimmed = 0

    init(limit: Int, byteLimit: Int, size: @escaping (Entry) -> Int) {
        self.limit = limit
        self.byteLimit = byteLimit
        self.size = size
    }

    mutating func append(_ entry: Entry) {
        entries.append(entry)
        bytes += size(entry)
        guard entries.count > limit + limit / 2 || bytes > byteLimit else {
            return
        }
        // Down to the count limit, then to three quarters of the byte budget, so the next trim is far off either way.
        var drop = max(0, entries.count - limit)
        var kept = entries[drop...].reduce(0) { $0 + size($1) }
        while kept > byteLimit * 3 / 4, drop < entries.count - 1 {
            kept -= size(entries[drop])
            drop += 1
        }
        entries.removeFirst(drop)
        bytes = kept
        trimmed += drop
    }

    /// The newest `limit` entries, oldest first, and how many older ones were left out.
    var newest: (entries: [Entry], trimmedCount: Int) {
        let kept = entries.suffix(limit)
        return (Array(kept), trimmed + entries.count - kept.count)
    }
}
