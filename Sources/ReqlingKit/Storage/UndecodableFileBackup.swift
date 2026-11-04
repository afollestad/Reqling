import Foundation

/// Moves a file Reqling could not decode aside as `<name>.corrupt-<timestamp>.<ext>`, beside it.
///
/// The library registry and workspace state fall back to empty when their file does not decode, and the next change
/// rewrites the file; without this, that write would destroy whatever it held (a hand edit worth repairing, or a
/// newer version's format). Moving rather than copying means a later launch does not back the same file up again.
enum UndecodableFileBackup {
    @discardableResult
    static func preserve(_ url: URL, now: Date = Date()) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        let directory = url.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent("\(stem).corrupt-\(stamp)\(suffix)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem).corrupt-\(stamp)-\(counter)\(suffix)")
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: candidate)
            return candidate
        } catch {
            return nil
        }
    }
}
