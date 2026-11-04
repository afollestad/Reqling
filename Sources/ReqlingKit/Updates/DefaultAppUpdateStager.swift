import Foundation

/// Extracts a verified download and validates it before anything can install it: it must be `Reqling.app` with the
/// running app's bundle identifier, exactly the release's version and newer than this one, pass `codesign` and
/// Gatekeeper, and be signed by the same team and identity. The staged state is metadata in Reqling's update storage,
/// revalidated on every launch.
public struct DefaultAppUpdateStager: AppUpdateStaging {
    private let paths: AppUpdateStoragePaths
    private let target: AppUpdateTarget
    private let commands: any CommandRunning
    private let now: @Sendable () -> Date

    public init(
        updatesDirectory: URL,
        target: AppUpdateTarget,
        commands: any CommandRunning = ProcessCommandRunner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        paths = AppUpdateStoragePaths(updatesDirectory: updatesDirectory)
        self.target = target
        self.commands = commands
        self.now = now
    }

    public func stageDownloadedUpdate(release: AppUpdateRelease, downloadedZIPURL: URL) async throws -> StagedAppUpdate {
        if let problem = target.installLocationProblem() {
            throw AppUpdateFailure(message: problem)
        }
        let working = paths.updatesDirectory
            .appendingPathComponent("Working", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: working)
            try? FileManager.default.removeItem(at: downloadedZIPURL.deletingLastPathComponent())
        }
        try await runRequired("/usr/bin/ditto", ["-x", "-k", downloadedZIPURL.path, working.path], "The update archive couldn't be extracted.")
        let extracted = working.appendingPathComponent(AppUpdateTarget.appName, isDirectory: true)
        try await validate(extracted, release: release)

        let stagedApp = try paths.stagedAppURL(tag: release.tagName)
        let stagedDirectory = stagedApp.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: stagedDirectory)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: extracted, to: stagedApp)
        let staged = StagedAppUpdate(release: release, appBundleURL: stagedApp, stagedAt: now())
        try StagedMetadata(staged).write(to: paths.metadataURL)
        return staged
    }

    /// A staged update from an earlier launch, or `nil`. One no newer than the running app was installed already (its
    /// helper relaunched before cleaning up), so its leftovers go quietly; one that no longer validates is removed and
    /// reported.
    public func loadValidatedStagedUpdate() async throws -> StagedAppUpdate? {
        guard let data = try? Data(contentsOf: paths.metadataURL) else {
            return nil
        }
        do {
            let staged = try StagedMetadata.decode(data).stagedUpdate()
            let stagedDirectory = try paths.validatedStagedDirectory(containing: staged.appBundleURL)
            if let running = target.version, staged.release.version <= running {
                try? FileManager.default.removeItem(at: paths.metadataURL)
                try? FileManager.default.removeItem(at: stagedDirectory)
                return nil
            }
            if let problem = target.installLocationProblem() {
                throw AppUpdateFailure(message: problem)
            }
            try await validate(staged.appBundleURL, release: staged.release)
            return staged
        } catch {
            try? FileManager.default.removeItem(at: paths.metadataURL)
            throw error
        }
    }

    func validate(_ appURL: URL, release: AppUpdateRelease) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppUpdateFailure(message: "The update archive didn't contain \(AppUpdateTarget.appName) at its top level.")
        }
        guard let bundle = Bundle(url: appURL), bundle.bundleIdentifier == target.bundleIdentifier else {
            throw AppUpdateFailure(message: "The update isn't Reqling: its bundle identifier doesn't match.")
        }
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppUpdateVersion.init)
        guard version == release.version else {
            throw AppUpdateFailure(message: "The update's version doesn't match \(release.tagName).")
        }
        if let running = target.version, release.version <= running {
            throw AppUpdateFailure(message: "The update isn't newer than this Reqling.")
        }
        try await runRequired(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "--verbose=2", appURL.path],
            "The update's code signature is invalid."
        )
        try await runRequired("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", appURL.path], "Gatekeeper rejected the update.")
        let running = try await signature(of: target.bundleURL)
        let staged = try await signature(of: appURL)
        guard let team = running.team, team == staged.team else {
            throw AppUpdateFailure(message: "The update isn't signed by the same team as this Reqling.")
        }
        guard !running.authorities.isEmpty, running.authorities == staged.authorities else {
            throw AppUpdateFailure(message: "The update's signing identity doesn't match this Reqling's.")
        }
    }

    private func signature(of appURL: URL) async throws -> (team: String?, authorities: [String]) {
        let result = try await commands.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dv", "--verbose=4", appURL.path],
            currentDirectory: nil,
            timeout: .seconds(30)
        )
        guard result.exitCode == 0 else {
            throw AppUpdateFailure(message: "Reqling couldn't read the app's signing identity.")
        }
        var team: String?
        var authorities: [String] = []
        // codesign prints the details on standard error.
        for line in result.standardErrorText.components(separatedBy: .newlines) {
            if line.hasPrefix("TeamIdentifier=") {
                team = String(line.dropFirst("TeamIdentifier=".count))
            } else if line.hasPrefix("Authority=") {
                authorities.append(String(line.dropFirst("Authority=".count)))
            }
        }
        return (team == "not set" ? nil : team, authorities)
    }

    private func runRequired(_ executable: String, _ arguments: [String], _ message: String) async throws {
        let result = try await commands.run(URL(fileURLWithPath: executable), arguments: arguments, currentDirectory: nil, timeout: .seconds(120))
        guard result.exitCode == 0 else {
            let detail = result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppUpdateFailure(message: detail.isEmpty ? message : "\(message) \(detail)")
        }
    }
}

/// `staged-update.json`: what was staged and where, re-read and revalidated on launch.
struct StagedMetadata: Codable {
    let tagName: String
    let version: String
    let changelogMarkdown: String
    let htmlURL: URL
    let assetName: String
    let assetDownloadURL: URL
    let assetSize: Int?
    let assetDigest: String
    let appBundleURL: URL
    let stagedAt: Date

    init(_ staged: StagedAppUpdate) {
        tagName = staged.release.tagName
        version = staged.release.version.description
        changelogMarkdown = staged.release.changelogMarkdown
        htmlURL = staged.release.htmlURL
        assetName = staged.release.asset.name
        assetDownloadURL = staged.release.asset.downloadURL
        assetSize = staged.release.asset.size
        assetDigest = staged.release.asset.digest.gitHubDigest
        appBundleURL = staged.appBundleURL
        stagedAt = staged.stagedAt
    }

    static func decode(_ data: Data) throws -> StagedMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StagedMetadata.self, from: data)
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    func stagedUpdate() throws -> StagedAppUpdate {
        guard let parsedVersion = AppUpdateVersion(string: version),
              let digest = AppUpdateReleaseAssetDigest(gitHubDigest: assetDigest) else {
            throw AppUpdateFailure(message: "The staged update's details are damaged.")
        }
        return StagedAppUpdate(
            release: AppUpdateRelease(
                tagName: tagName,
                version: parsedVersion,
                changelogMarkdown: changelogMarkdown,
                htmlURL: htmlURL,
                asset: AppUpdateReleaseAsset(name: assetName, downloadURL: assetDownloadURL, size: assetSize, digest: digest)
            ),
            appBundleURL: appBundleURL,
            stagedAt: stagedAt
        )
    }
}
