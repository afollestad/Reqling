import Foundation
import ReqlingKit
import Synchronization

/// Answers the import sheet's web requests from documents the test serves, by URL, and reads files as the live fetcher
/// does, so app tests never reach the network.
final class ImportFetcherStub: ImportFetching {
    private let served = Mutex<[URL: Data]>([:])

    func serve(_ text: String, at url: URL) {
        served.withLock { $0[url] = Data(text.utf8) }
    }

    func data(from url: URL) async throws(ImportError) -> (data: Data, url: URL) {
        if url.isFileURL {
            return try await LiveImportFetcher().data(from: url)
        }
        guard let data = served.withLock({ $0[url] }) else {
            throw .fetch(url.absoluteString, "The server answered 404.")
        }
        return (data, url)
    }
}
