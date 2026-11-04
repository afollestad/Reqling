import Foundation

/// Reads `afollestad/reqling`'s public GitHub Releases without authentication.
///
/// Requests are conditional (`If-None-Match` with the last `ETag`): GitHub answers an unchanged list with 304, which
/// does not count against the 60-requests-an-hour unauthenticated limit, so checks every few hours never exhaust it.
///
/// Only the release chosen for download (the highest stable version) has to meet the install contract, a
/// `Reqling.app.zip` asset with a SHA-256 digest; older releases contribute notes whatever they carry, so filtering out
/// releases without the asset would silently drop release history.
public actor GitHubAppUpdateReleaseClient: AppUpdateReleaseClient {
    public static let releasesURL = URL(string: "https://api.github.com/repos/afollestad/reqling/releases?per_page=100")!
    public static let expectedAssetName = "Reqling.app.zip"

    private let releasesURL: URL
    private let session: URLSession
    private let userAgent: String
    private var cached: (etag: String, data: Data)?

    public init(
        releasesURL: URL = GitHubAppUpdateReleaseClient.releasesURL,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        userAgent: String
    ) {
        self.releasesURL = releasesURL
        session = URLSession(configuration: sessionConfiguration)
        self.userAgent = userAgent
    }

    public func latestRelease() async -> AppUpdateReleaseLookupResult {
        var request = URLRequest(url: releasesURL)
        // The ETag cache here, not URLCache, decides what is fresh.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let cached {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            let (body, urlResponse) = try await session.data(for: request)
            guard let http = urlResponse as? HTTPURLResponse else {
                return .unavailable(.transportFailed("GitHub sent a response that isn't HTTP."))
            }
            data = body
            response = http
        } catch {
            return .unavailable(.transportFailed(error.localizedDescription))
        }
        switch response.statusCode {
        case 200:
            if let etag = response.value(forHTTPHeaderField: "ETag") {
                cached = (etag, data)
            }
            return Self.decode(data)
        case 304:
            guard let cached else {
                return .unavailable(.requestFailed(statusCode: 304))
            }
            return Self.decode(cached.data)
        case 404:
            return .unavailable(.noRelease)
        case 403 where response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0":
            return .unavailable(.rateLimited(resetDate: Self.rateLimitReset(response)))
        case 429:
            return .unavailable(.rateLimited(resetDate: Self.rateLimitReset(response)))
        default:
            return .unavailable(.requestFailed(statusCode: response.statusCode))
        }
    }

    private static func rateLimitReset(_ response: HTTPURLResponse) -> Date? {
        response.value(forHTTPHeaderField: "x-ratelimit-reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }

    /// The release feed in a releases response; see the type's doc for which releases must meet the asset contract.
    static func decode(_ data: Data) -> AppUpdateReleaseLookupResult {
        let releases: [ReleaseResponse]
        do {
            releases = try JSONDecoder().decode([ReleaseResponse].self, from: data)
        } catch {
            return .unavailable(.decodingFailed(error.localizedDescription))
        }
        var seen = Set<AppUpdateVersion>()
        let stable = releases
            .filter { !$0.draft && !$0.prerelease }
            .compactMap { release in AppUpdateVersion(string: release.tagName).map { (release, $0) } }
            .filter { seen.insert($0.1).inserted }
            .sorted { $0.1 > $1.1 }
        guard let (latest, version) = stable.first else {
            let firstStable = releases.first { !$0.draft && !$0.prerelease }
            return .unavailable(firstStable.map { .malformedVersion($0.tagName) } ?? .noRelease)
        }
        guard let htmlURL = URL(string: latest.htmlURL), htmlURL.scheme == "https" else {
            return .unavailable(.invalidURL(latest.htmlURL))
        }
        guard let asset = latest.assets.first(where: { $0.name == expectedAssetName }) else {
            return .unavailable(.missingAsset(expectedName: expectedAssetName))
        }
        guard let downloadURL = URL(string: asset.browserDownloadURL), downloadURL.scheme == "https" else {
            return .unavailable(.invalidURL(asset.browserDownloadURL))
        }
        guard let digestText = asset.digest, !digestText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .unavailable(.missingAssetDigest(expectedName: expectedAssetName))
        }
        guard let digest = AppUpdateReleaseAssetDigest(gitHubDigest: digestText) else {
            return .unavailable(.invalidAssetDigest(digestText))
        }
        return .installable(AppUpdateReleaseFeed(
            latestRelease: AppUpdateRelease(
                tagName: latest.tagName,
                version: version,
                changelogMarkdown: latest.body ?? "",
                htmlURL: htmlURL,
                asset: AppUpdateReleaseAsset(name: asset.name, downloadURL: downloadURL, size: asset.size, digest: digest)
            ),
            releaseNotes: stable.map { AppUpdateReleaseNote(tagName: $0.0.tagName, version: $0.1, changelogMarkdown: $0.0.body ?? "") }
        ))
    }
}

private struct ReleaseResponse: Decodable {
    let tagName: String
    let body: String?
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool
    let assets: [AssetResponse]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

private struct AssetResponse: Decodable {
    let name: String
    let browserDownloadURL: String
    let size: Int?
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case digest
    }
}
