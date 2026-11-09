import Foundation

/// Reads what an import needs from a URL: a document, the documents its references name, and its examples' external
/// values. Injected, so tests answer through a stub instead of the network.
public protocol ImportFetching: Sendable {
    /// The bytes at `url`, and the URL they came from after any redirects, which relative references resolve against.
    func data(from url: URL) async throws(ImportError) -> (data: Data, url: URL)
}

/// Fetches over the network with an ephemeral session that keeps no cookies or cache, so an import never carries the
/// app's state to a server or leaves any behind, and reads `file:` URLs from disk. Stops reading past `maximumBytes`.
public struct LiveImportFetcher: ImportFetching {
    public static let maximumBytes = 32 * 1024 * 1024

    private let session: URLSession

    /// Takes a copy of `configuration`, a stub's in tests, with cookies and caching turned off.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = (configuration.copy() as? URLSessionConfiguration) ?? configuration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    public func data(from url: URL) async throws(ImportError) -> (data: Data, url: URL) {
        let name = ImportError.displayName(of: url)
        if url.isFileURL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maximumBytes else {
                throw .tooLarge(name)
            }
            guard let data = try? Data(contentsOf: url) else {
                throw .unreadable(name)
            }
            return (data, url)
        }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ImportError.fetch(name, "The server answered \(http.statusCode).")
            }
            guard response.expectedContentLength <= Int64(Self.maximumBytes) else {
                throw ImportError.tooLarge(name)
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= Self.maximumBytes else {
                    throw ImportError.tooLarge(name)
                }
            }
            return (data, response.url ?? url)
        } catch let error as ImportError {
            throw error
        } catch {
            throw .fetch(name, error.localizedDescription)
        }
    }
}
