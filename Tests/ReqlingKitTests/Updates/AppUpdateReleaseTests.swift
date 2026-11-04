import Foundation
@testable import ReqlingKit
import XCTest

final class AppUpdateReleaseTests: XCTestCase {
    func testVersionsParseTagsAndCompareNumerically() {
        XCTAssertEqual(AppUpdateVersion(string: "v1.2.3")?.description, "1.2.3")
        XCTAssertNil(AppUpdateVersion(string: "1.2"))
        XCTAssertNil(AppUpdateVersion(string: "1.2.3-beta"))
        XCTAssertLessThan(AppUpdateVersion(string: "0.9.10")!, AppUpdateVersion(string: "0.10.0")!)
    }

    /// Only the newest stable release must carry the asset; older ones still contribute notes.
    func testTheHighestStableReleaseIsChosenAndOlderOnesContributeNotes() throws {
        let data = ReleaseJSON.data([
            ReleaseJSON.release("v0.3.0", prerelease: true),
            ReleaseJSON.release("v0.4.0", draft: true),
            ReleaseJSON.release("v0.1.0", asset: nil),
            ReleaseJSON.release("v0.2.0"),
            ReleaseJSON.release("nightly")
        ])

        guard case .installable(let feed) = GitHubAppUpdateReleaseClient.decode(data) else {
            return XCTFail("Expected a release")
        }

        XCTAssertEqual(feed.latestRelease.tagName, "v0.2.0")
        XCTAssertEqual(feed.releaseNotes.map(\.tagName), ["v0.2.0", "v0.1.0"])
        XCTAssertEqual(feed.latestRelease.asset.digest.sha256HexDigest, String(repeating: "ab", count: 32))
    }

    func testTheChosenReleaseMustCarryAVerifiableAsset() {
        func reason(_ release: [String: Any]) -> AppUpdateUnavailableReason? {
            if case .unavailable(let reason) = GitHubAppUpdateReleaseClient.decode(ReleaseJSON.data([release])) {
                return reason
            }
            return nil
        }

        XCTAssertEqual(reason(ReleaseJSON.release("v1.0.0", asset: "Other.zip")), .missingAsset(expectedName: "Reqling.app.zip"))
        XCTAssertEqual(reason(ReleaseJSON.release("v1.0.0", digest: nil)), .missingAssetDigest(expectedName: "Reqling.app.zip"))
        XCTAssertEqual(reason(ReleaseJSON.release("v1.0.0", digest: "md5:abc")), .invalidAssetDigest("md5:abc"))
        XCTAssertEqual(reason(ReleaseJSON.release("nightly")), .malformedVersion("nightly"))
        XCTAssertEqual(GitHubAppUpdateReleaseClient.decode(ReleaseJSON.data([])), .unavailable(.noRelease))
    }

    /// An unchanged list comes back 304 against the last ETag, which GitHub doesn't count against the rate limit.
    func testRepeatChecksAreConditionalOnTheLastETag() async throws {
        let host = StubURLProtocol.register { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" {
                return .response(status: 304)
            }
            return .response(status: 200, headers: ["ETag": "\"v1\""], body: ReleaseJSON.data([ReleaseJSON.release("v1.0.0")]))
        }
        let client = GitHubAppUpdateReleaseClient(
            releasesURL: try XCTUnwrap(URL(string: "https://\(host)/releases")),
            sessionConfiguration: StubURLProtocol.configuration(),
            userAgent: "Reqling/0.1.0"
        )

        let first = await client.latestRelease()
        let second = await client.latestRelease()

        XCTAssertEqual(first, second)
        guard case .installable(let feed) = second else {
            return XCTFail("Expected the cached release, got \(second)")
        }
        XCTAssertEqual(feed.latestRelease.tagName, "v1.0.0")
        let requests = StubURLProtocol.requests(to: host)
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "If-None-Match") }, [nil, "\"v1\""])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "User-Agent"), "Reqling/0.1.0")
    }

    func testRateLimitsAndMissingRepositoriesAreReported() async throws {
        let reset = Date(timeIntervalSince1970: 2_000_000_000)
        let limited = StubURLProtocol.register { _ in
            .response(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "2000000000"])
        }
        let missing = StubURLProtocol.register { _ in .response(status: 404) }
        func check(_ host: String) async throws -> AppUpdateReleaseLookupResult {
            await GitHubAppUpdateReleaseClient(
                releasesURL: try XCTUnwrap(URL(string: "https://\(host)/releases")),
                sessionConfiguration: StubURLProtocol.configuration(),
                userAgent: "Reqling"
            ).latestRelease()
        }

        let limitedResult = try await check(limited)
        let missingResult = try await check(missing)
        XCTAssertEqual(limitedResult, .unavailable(.rateLimited(resetDate: reset)))
        XCTAssertEqual(missingResult, .unavailable(.noRelease))
    }

    // MARK: - Downloading

    func testADownloadIsVerifiedAndNeverCachedEvenAcrossTheRedirect() async throws {
        let bytes = Data("the update".utf8)
        let cdn = StubURLProtocol.register { _ in .response(status: 200, body: bytes) }
        let origin = StubURLProtocol.register { _ in .redirect(location: URL(string: "https://\(cdn)/asset")!) }
        let downloader = URLSessionAppUpdateDownloader(
            temporaryDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            sessionConfiguration: StubURLProtocol.configuration(),
            userAgent: "Reqling"
        )
        let progress = ProgressLog()

        let zip = try await downloader.download(release: stubRelease("1.0.0", servedFrom: origin, bytes: bytes)) { await progress.append($0) }
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }

        XCTAssertEqual(try Data(contentsOf: zip), bytes)
        let progressValues = await progress.values
        XCTAssertEqual(progressValues.first, 0)
        XCTAssertEqual(progressValues.last, 1)
        for request in StubURLProtocol.requests(to: origin) + StubURLProtocol.requests(to: cdn) {
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData, "\(request)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache", "\(request)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Pragma"), "no-cache", "\(request)")
        }
        XCTAssertEqual(StubURLProtocol.requests(to: cdn).count, 1)
    }

    func testADigestMismatchIsRejectedAndLeavesNothingBehind() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let host = StubURLProtocol.register { _ in .response(status: 200, body: Data("tampered!!".utf8)) }
        let downloader = URLSessionAppUpdateDownloader(
            temporaryDirectory: temporary,
            sessionConfiguration: StubURLProtocol.configuration(),
            userAgent: "Reqling"
        )

        do {
            _ = try await downloader.download(release: stubRelease("1.0.0", servedFrom: host, bytes: Data("the update".utf8))) { _ in }
            XCTFail("A tampered download must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SHA-256"), error.localizedDescription)
        }
        let leftovers = try FileManager.default.subpathsOfDirectory(atPath: temporary.appendingPathComponent("ReqlingUpdates").path)
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testAnHTTPErrorFailsTheDownload() async throws {
        let host = StubURLProtocol.register { _ in .response(status: 500) }
        let downloader = URLSessionAppUpdateDownloader(sessionConfiguration: StubURLProtocol.configuration(), userAgent: "Reqling")

        do {
            _ = try await downloader.download(release: stubRelease("1.0.0", servedFrom: host, bytes: Data("x".utf8))) { _ in }
            XCTFail("Expected HTTP 500 to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 500"), error.localizedDescription)
        }
    }
}

private actor ProgressLog {
    private(set) var values: [Double] = []

    func append(_ value: Double) {
        values.append(value)
    }
}
