import Foundation

/// The release an update would install: the highest stable version, which must carry `Reqling.app.zip` with a
/// GitHub-computed SHA-256 digest.
public struct AppUpdateRelease: Equatable, Sendable {
    public let tagName: String
    public let version: AppUpdateVersion
    public let changelogMarkdown: String
    public let htmlURL: URL
    public let asset: AppUpdateReleaseAsset

    public init(tagName: String, version: AppUpdateVersion, changelogMarkdown: String, htmlURL: URL, asset: AppUpdateReleaseAsset) {
        self.tagName = tagName
        self.version = version
        self.changelogMarkdown = changelogMarkdown
        self.htmlURL = htmlURL
        self.asset = asset
    }

    var releaseNote: AppUpdateReleaseNote {
        AppUpdateReleaseNote(tagName: tagName, version: version, changelogMarkdown: changelogMarkdown)
    }
}

/// One release's notes. Older releases contribute notes whether or not they carry an installable asset.
public struct AppUpdateReleaseNote: Equatable, Sendable {
    public let tagName: String
    public let version: AppUpdateVersion
    public let changelogMarkdown: String

    public init(tagName: String, version: AppUpdateVersion, changelogMarkdown: String) {
        self.tagName = tagName
        self.version = version
        self.changelogMarkdown = changelogMarkdown
    }
}

public struct AppUpdateReleaseAsset: Equatable, Sendable {
    public let name: String
    public let downloadURL: URL
    public let size: Int?
    public let digest: AppUpdateReleaseAssetDigest

    public init(name: String, downloadURL: URL, size: Int?, digest: AppUpdateReleaseAssetDigest) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.digest = digest
    }
}

/// The SHA-256 GitHub computes for an uploaded asset (`sha256:<hex>`), verified against the download before staging.
public struct AppUpdateReleaseAssetDigest: Equatable, Sendable {
    public let sha256HexDigest: String

    public init?(gitHubDigest: String) {
        let parts = gitHubDigest.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "sha256" else {
            return nil
        }
        self.init(sha256HexDigest: String(parts[1]))
    }

    public init?(sha256HexDigest: String) {
        let normalized = sha256HexDigest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else {
            return nil
        }
        self.sha256HexDigest = normalized
    }

    public var gitHubDigest: String {
        "sha256:\(sha256HexDigest)"
    }
}

/// The highest stable release, and every stable release's notes, newest first.
public struct AppUpdateReleaseFeed: Equatable, Sendable {
    public let latestRelease: AppUpdateRelease
    public let releaseNotes: [AppUpdateReleaseNote]

    public init(latestRelease: AppUpdateRelease, releaseNotes: [AppUpdateReleaseNote]) {
        self.latestRelease = latestRelease
        self.releaseNotes = releaseNotes
    }
}

public enum AppUpdateReleaseLookupResult: Equatable, Sendable {
    case installable(AppUpdateReleaseFeed)
    case unavailable(AppUpdateUnavailableReason)
}

/// Why no update can be offered. Settings explains each; automatic checks keep them quiet.
public enum AppUpdateUnavailableReason: Equatable, Sendable {
    case noRelease
    case missingAsset(expectedName: String)
    case missingAssetDigest(expectedName: String)
    case malformedVersion(String)
    case invalidURL(String)
    case invalidAssetDigest(String)
    case requestFailed(statusCode: Int)
    case rateLimited(resetDate: Date?)
    case decodingFailed(String)
    case transportFailed(String)

    public var message: String {
        switch self {
        case .noRelease: "Reqling hasn't published a release yet."
        case .missingAsset(let name): "The latest release has no \(name)."
        case .missingAssetDigest(let name): "The latest release's \(name) has no checksum, so it can't be verified."
        case .malformedVersion(let version): "“\(version)” isn't a version Reqling understands."
        case .invalidURL(let url): "The release lists an invalid URL: \(url)"
        case .invalidAssetDigest(let digest): "The release lists an invalid checksum: \(digest)"
        case .requestFailed(let status): "GitHub answered with HTTP \(status)."
        case .rateLimited(let reset):
            if let reset {
                "GitHub's rate limit was reached; try again after \(reset.formatted(date: .omitted, time: .shortened))."
            } else {
                "GitHub's rate limit was reached; try again later."
            }
        case .decodingFailed(let detail): "GitHub's answer couldn't be read: \(detail)"
        case .transportFailed(let detail): "Couldn't reach GitHub: \(detail)"
        }
    }
}

public enum AppUpdateCheckResult: Equatable, Sendable {
    case updateAvailable(AppUpdateCheckSnapshot)
    case upToDate(AppUpdateCheckSnapshot)
    case unavailable(AppUpdateUnavailableReason)
}

public struct AppUpdateCheckSnapshot: Equatable, Sendable {
    public let latestRelease: AppUpdateRelease
    public let currentVersion: AppUpdateVersion
    /// The notes of every release newer than the running one, newest first; the latest release's alone when up to date.
    public let releaseNotes: [AppUpdateReleaseNote]
}

public struct AppUpdateFailure: Equatable, Sendable, LocalizedError {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }

    static func from(_ error: any Error) -> AppUpdateFailure {
        error as? AppUpdateFailure ?? AppUpdateFailure(message: error.localizedDescription)
    }
}

/// A verified update extracted into Reqling's update storage, waiting for Install & Relaunch.
public struct StagedAppUpdate: Equatable, Identifiable, Sendable {
    public var id: String {
        release.tagName
    }

    public let release: AppUpdateRelease
    public let appBundleURL: URL
    public let stagedAt: Date

    public init(release: AppUpdateRelease, appBundleURL: URL, stagedAt: Date) {
        self.release = release
        self.appBundleURL = appBundleURL
        self.stagedAt = stagedAt
    }
}

public enum AppUpdateDownloadState: Equatable, Sendable {
    case idle
    case checkingLatestRelease
    case downloading(AppUpdateRelease, progress: Double)
    case staging(AppUpdateRelease)
    case readyToInstall(StagedAppUpdate)
    case installing(StagedAppUpdate)
    case failed(AppUpdateFailure)
}

public protocol AppUpdateReleaseClient: Sendable {
    func latestRelease() async -> AppUpdateReleaseLookupResult
}

public protocol AppUpdateDownloading: Sendable {
    /// The verified ZIP's location, in a directory of its own the caller removes.
    func download(release: AppUpdateRelease, progress: @escaping @Sendable (Double) async -> Void) async throws -> URL
}

public protocol AppUpdateStaging: Sendable {
    func stageDownloadedUpdate(release: AppUpdateRelease, downloadedZIPURL: URL) async throws -> StagedAppUpdate
    /// The update staged by an earlier launch, revalidated, or `nil`.
    func loadValidatedStagedUpdate() async throws -> StagedAppUpdate?
}

public protocol AppUpdateInstalling: Sendable {
    /// Hands the staged app to a helper that swaps it in after this process quits, then quits.
    func installAndRelaunch(stagedUpdate: StagedAppUpdate) async throws
}
