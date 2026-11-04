import CryptoKit
import Foundation

/// Streams a release archive to disk, hashing it on the way.
///
/// The session is ephemeral with no URL cache: a multi-megabyte archive has no place in a shared cache, and the
/// digest check must see the bytes the server sent now, never a stored copy.
public struct ProtocDownloader: Sendable {
    private static let chunkSize = 64 * 1024

    private let session: URLSession

    /// `configuration` lets tests route the download through a `URLProtocol`; caching is turned off regardless.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        // A copy, so the caller's configuration keeps its own cache settings.
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? .ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration)
    }

    /// Writes `url`'s body to `destination` and returns its lowercase hex SHA-256.
    ///
    /// `progress` gets the bytes received so far and the expected total, when the server sent one. Cancelling the
    /// task stops the transfer and throws `CancellationError`.
    func download(
        _ url: URL,
        to destination: URL,
        progress: @Sendable (_ received: Int64, _ expected: Int64?) -> Void
    ) async throws -> String {
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw ProtocInstallError.httpStatus(status)
        }
        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw ProtocInstallError.writeFailed(destination.path)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var hasher = SHA256()
        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(Self.chunkSize)
        func flush() throws {
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            progress(received, expected)
        }
        progress(0, expected)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= Self.chunkSize {
                try Task.checkCancellation()
                try flush()
            }
        }
        try Task.checkCancellation()
        if !buffer.isEmpty {
            try flush()
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
