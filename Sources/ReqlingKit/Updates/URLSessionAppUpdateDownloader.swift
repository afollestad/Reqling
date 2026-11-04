import CryptoKit
import Foundation

/// Streams the release asset to `<temporary>/ReqlingUpdates/<uuid>/` and verifies its size and SHA-256 against what
/// GitHub reported, deleting it on any failure.
///
/// The download is never cached, in all four places: the ephemeral configuration, the request's `cachePolicy`, the
/// `no-cache`/`Pragma` headers, and the same headers re-applied to the redirected request (GitHub redirects asset
/// downloads to a CDN). The redirect site is the one a simplification drops first; a cached response would make the
/// digest check fail on a stale file or progress report a download that never happened.
public struct URLSessionAppUpdateDownloader: AppUpdateDownloading {
    private let temporaryDirectory: URL
    private let sessionConfiguration: URLSessionConfiguration
    private let userAgent: String

    public init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        userAgent: String
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.sessionConfiguration = sessionConfiguration
        self.userAgent = userAgent
    }

    public func download(release: AppUpdateRelease, progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        let directory = temporaryDirectory
            .appendingPathComponent("ReqlingUpdates", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let zipURL = directory.appendingPathComponent(release.asset.name.sanitizedForPathComponent)
        do {
            await progress(0)
            try await stream(request(for: release.asset.downloadURL), to: zipURL, expectedSize: release.asset.size, progress: progress)
            try Self.verify(zipURL, size: release.asset.size, digest: release.asset.digest)
            await progress(1)
            return zipURL
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 600
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func stream(
        _ request: URLRequest,
        to destination: URL,
        expectedSize: Int?,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let delegate = AssetDownloadDelegate(destination: destination, expectedSize: expectedSize, progress: progress)
        let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        do {
            try await withTaskCancellationHandler {
                try await delegate.run(task)
            } onCancel: {
                task.cancel()
            }
            await delegate.waitForProgressReports()
        } catch {
            await delegate.waitForProgressReports()
            throw error
        }
    }

    static func verify(_ zipURL: URL, size: Int?, digest: AppUpdateReleaseAssetDigest) throws {
        if let size {
            let downloaded = (try FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard downloaded == size else {
                throw AppUpdateFailure(message: "Downloaded \(downloaded) bytes, but GitHub reported \(size).")
            }
        }
        let handle = try FileHandle(forReadingFrom: zipURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == digest.sha256HexDigest else {
            throw AppUpdateFailure(message: "The downloaded update failed its SHA-256 check, so it wasn't installed.")
        }
    }
}

/// Writes a data task's body to a file as it arrives, reporting progress in 1% steps, and resumes `run` once.
private final class AssetDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedSize: Int?
    private let progress: @Sendable (Double) async -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var failure: (any Error)?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var responseLength: Int64 = 0
    private var createdFile = false
    private var lastReported = 0.0
    private var reports: [Task<Void, Never>] = []

    init(destination: URL, expectedSize: Int?, progress: @escaping @Sendable (Double) async -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func run(_ task: URLSessionDataTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            task.resume()
        }
    }

    func waitForProgressReports() async {
        for report in lock.withLock({ reports }) {
            await report.value
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let error = Self.httpError(response) {
            lock.withLock { failure = error }
            completionHandler(.cancel)
            return
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let fileHandle = try? FileHandle(forWritingTo: destination) else {
            lock.withLock { failure = AppUpdateFailure(message: "Reqling couldn't create the update download file.") }
            completionHandler(.cancel)
            return
        }
        lock.withLock {
            handle = fileHandle
            responseLength = response.expectedContentLength
            createdFile = true
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let fraction: Double?
        do {
            fraction = try lock.withLock {
                guard let handle else {
                    throw AppUpdateFailure(message: "Reqling couldn't write the update download.")
                }
                try handle.write(contentsOf: data)
                received += Int64(data.count)
                let expected = expectedSize.map(Int64.init) ?? (responseLength > 0 ? responseLength : 0)
                return expected > 0 ? min(Double(received) / Double(expected), 1) : nil
            }
        } catch {
            lock.withLock { failure = error }
            dataTask.cancel()
            return
        }
        guard let fraction else {
            return
        }
        lock.withLock {
            guard fraction >= 1 || fraction - lastReported >= 0.01 else {
                return
            }
            lastReported = fraction
            // Each report waits for the one before it; unstructured tasks alone could land out of order and step the
            // bar backwards.
            let previous = reports.last
            reports.append(Task { [progress] in
                await previous?.value
                await progress(fraction)
            })
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.uncached(request))
    }

    /// The redirected request with the no-cache policy and headers re-applied; see `URLSessionAppUpdateDownloader`.
    static func uncached(_ request: URLRequest) -> URLRequest {
        var redirected = request
        redirected.cachePolicy = .reloadIgnoringLocalCacheData
        redirected.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        redirected.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return redirected
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (stored, created, fileHandle) = lock.withLock {
            defer { handle = nil }
            return (failure, createdFile, handle)
        }
        try? fileHandle?.close()
        var completion = stored ?? Self.httpError(task.response)
        if completion == nil, let error {
            completion = (error as? URLError)?.code == .cancelled ? CancellationError() : error
        }
        if completion == nil, !created {
            completion = AppUpdateFailure(message: "GitHub didn't send the update.")
        }
        if completion != nil {
            try? FileManager.default.removeItem(at: destination)
        }
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        if let completion {
            continuation?.resume(throwing: completion)
        } else {
            continuation?.resume()
        }
    }

    private static func httpError(_ response: URLResponse?) -> (any Error)? {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else {
            return nil
        }
        return AppUpdateFailure(message: "GitHub couldn't send the update (HTTP \(http.statusCode)).")
    }
}
