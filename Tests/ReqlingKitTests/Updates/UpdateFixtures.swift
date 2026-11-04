import CryptoKit
import Foundation
@testable import ReqlingKit
import Synchronization

/// Answers requests through per-host responders and records each request it sees, redirects included. Every test
/// registers its own random host, so suites can run in parallel.
final class StubURLProtocol: URLProtocol {
    enum Reply {
        case response(status: Int, headers: [String: String] = [:], body: Data = Data())
        case redirect(location: URL)
        case failure(URLError)
    }

    private static let responders = Mutex<[String: @Sendable (URLRequest) -> Reply]>([:])
    private static let requests = Mutex<[String: [URLRequest]]>([:])

    /// A fresh host whose requests `respond` answers.
    static func register(_ respond: @escaping @Sendable (URLRequest) -> Reply) -> String {
        let host = "\(UUID().uuidString.lowercased()).test"
        responders.withLock { $0[host] = respond }
        return host
    }

    static func requests(to host: String) -> [URLRequest] {
        requests.withLock { $0[host] ?? [] }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host.map { host in responders.withLock { $0[host] != nil } } ?? false
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let respond = Self.responders.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.requests.withLock { $0[host, default: []].append(request) }
        switch respond(request) {
        case .response(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(location: let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            // A plain request, as URLSession builds one: the delegate has to put the no-cache headers back.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Release JSON as GitHub's API returns it.
enum ReleaseJSON {
    static func release(
        _ tag: String,
        body: String? = nil,
        draft: Bool = false,
        prerelease: Bool = false,
        asset: String? = GitHubAppUpdateReleaseClient.expectedAssetName,
        digest: String? = "sha256:" + String(repeating: "ab", count: 32)
    ) -> [String: Any] {
        var release: [String: Any] = [
            "tag_name": tag,
            "body": body ?? "Notes for \(tag)",
            "html_url": "https://github.com/afollestad/reqling/releases/tag/\(tag)",
            "draft": draft,
            "prerelease": prerelease,
            "assets": [] as [Any]
        ]
        if let asset {
            var entry: [String: Any] = ["name": asset, "browser_download_url": "https://example.test/\(tag)/\(asset)", "size": 10]
            entry["digest"] = digest
            release["assets"] = [entry]
        }
        return release
    }

    static func data(_ releases: [[String: Any]]) -> Data {
        // Only JSON-compatible values go in, so serialization can't fail.
        (try? JSONSerialization.data(withJSONObject: releases)) ?? Data()
    }
}

/// A release whose asset is served from `host` with the given bytes' real digest.
func stubRelease(_ version: String, servedFrom host: String, bytes: Data) -> AppUpdateRelease {
    AppUpdateRelease(
        tagName: "v\(version)",
        version: AppUpdateVersion(string: version)!,
        changelogMarkdown: "",
        htmlURL: URL(string: "https://github.com/afollestad/reqling/releases/tag/v\(version)")!,
        asset: AppUpdateReleaseAsset(
            name: "Reqling.app.zip",
            downloadURL: URL(string: "https://\(host)/Reqling.app.zip")!,
            size: bytes.count,
            digest: AppUpdateReleaseAssetDigest(sha256HexDigest: sha256(bytes))!
        )
    )
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
