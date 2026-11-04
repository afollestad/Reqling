import Foundation

extension Data {
    /// The bytes as UTF-8 text, or `nil` when they are not valid UTF-8.
    var utf8Text: String? {
        String(bytes: self, encoding: .utf8)
    }
}

/// A unique scratch directory per test, removed by `remove()`.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReqlingKitTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }
}
