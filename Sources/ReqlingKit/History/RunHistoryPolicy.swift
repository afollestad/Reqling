import Foundation

/// How long runs stay in a request's history. Each request's latest run outlasts it, so a response still shows after
/// a relaunch however old it is; only `HistorySizeLimit` takes that one.
public enum HistoryRetention: String, Hashable, Sendable, Codable, CaseIterable {
    case day
    case week
    case month
    case quarter
    case forever

    /// `nil` keeps runs until the size limit needs the space.
    public var interval: TimeInterval? {
        let day: TimeInterval = 24 * 60 * 60
        return switch self {
        case .day: day
        case .week: 7 * day
        case .month: 30 * day
        case .quarter: 90 * day
        case .forever: nil
        }
    }
}

/// The most disk space every request's history may take together.
public enum HistorySizeLimit: String, Hashable, Sendable, Codable, CaseIterable {
    case megabytes100 = "100MB"
    case megabytes250 = "250MB"
    case megabytes500 = "500MB"
    case gigabytes1 = "1GB"
    case gigabytes2 = "2GB"
    case gigabytes5 = "5GB"

    /// Decimal units, as `ByteCountFormatter`'s file style shows sizes, so "Using 500 MB" means the limit is reached.
    public var bytes: Int {
        let megabyte = 1_000_000
        return switch self {
        case .megabytes100: 100 * megabyte
        case .megabytes250: 250 * megabyte
        case .megabytes500: 500 * megabyte
        case .gigabytes1: 1_000 * megabyte
        case .gigabytes2: 2_000 * megabyte
        case .gigabytes5: 5_000 * megabyte
        }
    }
}

/// What pruning keeps, taken from `AppSettings` when a run is recorded or the settings change.
struct RunHistoryPolicy: Hashable, Sendable {
    var retention: TimeInterval?
    var sizeLimit: Int

    init(retention: HistoryRetention, sizeLimit: HistorySizeLimit) {
        self.retention = retention.interval
        self.sizeLimit = sizeLimit.bytes
    }

    init(retention: TimeInterval?, sizeLimit: Int) {
        self.retention = retention
        self.sizeLimit = sizeLimit
    }
}
