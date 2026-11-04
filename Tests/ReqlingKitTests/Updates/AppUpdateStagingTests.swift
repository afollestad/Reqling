import Foundation
@testable import ReqlingKit
import Synchronization
import XCTest

/// Staging and installing against fake bundles in a temporary folder, with every `ditto`, `codesign`, and `spctl`
/// answered by `StubCommands`, so no real app is ever extracted, verified, or replaced.
final class AppUpdateStagingTests: XCTestCase {
    private var root: URL!
    private var updates: URL!
    private var commands: StubCommands!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rq-updates-\(UUID().uuidString)", isDirectory: true)
        updates = root.appendingPathComponent("Updates", isDirectory: true)
        commands = StubCommands()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    /// A `Reqling.app` with just enough Info.plist for `Bundle` to read.
    private func makeApp(in folder: URL, identifier: String = "com.afollestad.reqling", version: String) throws -> URL {
        let app = folder.appendingPathComponent("Reqling.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func target(version: String = "0.1.0", folder: String = "Applications") throws -> AppUpdateTarget {
        let installed = try makeApp(in: root.appendingPathComponent(folder, isDirectory: true), version: version)
        return AppUpdateTarget(bundleURL: installed, bundleIdentifier: "com.afollestad.reqling", version: AppUpdateVersion(string: version))
    }

    /// A download whose "archive" `ditto` turns into `extracted`.
    private func download(extracting extracted: URL) throws -> URL {
        let folder = root.appendingPathComponent("Download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("Reqling.app.zip")
        try Data("zip".utf8).write(to: zip)
        commands.extracts = extracted
        return zip
    }

    private func stager(_ target: AppUpdateTarget) -> DefaultAppUpdateStager {
        DefaultAppUpdateStager(updatesDirectory: updates, target: target, commands: commands, now: { Date(timeIntervalSince1970: 1_000) })
    }

    private func update(_ version: String) -> AppUpdateRelease {
        stubRelease(version, servedFrom: "example.test", bytes: Data())
    }

    private func stage(_ target: AppUpdateTarget, _ version: String, extracting app: URL) async throws {
        _ = try await stager(target).stageDownloadedUpdate(release: update(version), downloadedZIPURL: try download(extracting: app))
    }

    private func stagingFailure(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            return "no error"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Staging

    func testAValidUpdateIsStagedAndRestoredOnTheNextLaunch() async throws {
        let target = try target()
        let zip = try download(extracting: try makeApp(in: root.appendingPathComponent("Built"), version: "0.2.0"))

        let staged = try await stager(target).stageDownloadedUpdate(release: update("0.2.0"), downloadedZIPURL: zip)
        let restored = try await stager(target).loadValidatedStagedUpdate()

        XCTAssertEqual(staged.appBundleURL.standardizedFileURL, updates.appendingPathComponent("Staged/v0.2.0/Reqling.app").standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appBundleURL.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertEqual(restored, staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.deletingLastPathComponent().path), "The download is removed once staged")
        let tools = commands.invocations.map(\.tool)
        XCTAssertTrue(tools.contains("ditto") && tools.contains("spctl") && tools.contains("codesign"), "\(tools)")
    }

    func testAnUpdateThatIsntThisAppOrThisVersionIsRejected() async throws {
        let target = try target()
        let foreign = try makeApp(in: root.appendingPathComponent("Foreign"), identifier: "com.example.other", version: "0.2.0")
        let wrongVersion = try makeApp(in: root.appendingPathComponent("Wrong"), version: "0.3.0")
        let older = try makeApp(in: root.appendingPathComponent("Older"), version: "0.1.0")

        let foreignMessage = await stagingFailure {
            try await self.stage(target, "0.2.0", extracting: foreign)
        }
        let versionMessage = await stagingFailure {
            try await self.stage(target, "0.2.0", extracting: wrongVersion)
        }
        let olderMessage = await stagingFailure {
            try await self.stage(target, "0.1.0", extracting: older)
        }

        XCTAssertTrue(foreignMessage.contains("bundle identifier"), foreignMessage)
        XCTAssertTrue(versionMessage.contains("doesn't match v0.2.0"), versionMessage)
        XCTAssertTrue(olderMessage.contains("isn't newer"), olderMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: updates.appendingPathComponent("staged-update.json").path))
    }

    func testABadSignatureOrAnotherTeamIsRejected() async throws {
        let target = try target()
        let built = try makeApp(in: root.appendingPathComponent("Built"), version: "0.2.0")

        commands.verifyFails = true
        let unsigned = await stagingFailure {
            try await self.stage(target, "0.2.0", extracting: built)
        }
        commands.verifyFails = false
        commands.updateTeam = "OTHERTEAM"
        let otherTeam = await stagingFailure {
            try await self.stage(target, "0.2.0", extracting: built)
        }

        XCTAssertTrue(unsigned.contains("code signature is invalid"), unsigned)
        XCTAssertTrue(otherTeam.contains("same team"), otherTeam)
    }

    func testADevelopmentBuildCantBeUpdated() async throws {
        let target = try target(folder: "repo/.build/app/release")
        let message = await stagingFailure {
            _ = try await self.stager(target).stageDownloadedUpdate(
                release: self.update("0.2.0"),
                downloadedZIPURL: try self.download(extracting: try self.makeApp(in: self.root.appendingPathComponent("Built"), version: "0.2.0"))
            )
        }

        XCTAssertTrue(message.contains("development build"), message)
    }

    /// The install helper relaunches before it cleans up, so an update no newer than the running app was installed.
    func testAnAlreadyInstalledStagedUpdateIsCleanedUpQuietly() async throws {
        let zip = try download(extracting: try makeApp(in: root.appendingPathComponent("Built"), version: "0.2.0"))
        let staged = try await stager(try target()).stageDownloadedUpdate(release: update("0.2.0"), downloadedZIPURL: zip)

        let afterInstall = try await stager(try target(version: "0.2.0", folder: "Installed")).loadValidatedStagedUpdate()

        XCTAssertNil(afterInstall)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appBundleURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: updates.appendingPathComponent("staged-update.json").path))
    }

    /// Cleanup deletes only inside update storage, so tampered metadata can't aim it anywhere else.
    func testMetadataPointingOutsideUpdateStorageIsRefused() async throws {
        let zip = try download(extracting: try makeApp(in: root.appendingPathComponent("Built"), version: "0.2.0"))
        _ = try await stager(try target()).stageDownloadedUpdate(release: update("0.2.0"), downloadedZIPURL: zip)
        let metadataURL = updates.appendingPathComponent("staged-update.json")
        let victim = try makeApp(in: root.appendingPathComponent("Victim"), version: "0.2.0")
        var metadata = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata["appBundleURL"] = victim.absoluteString
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)

        let message = await stagingFailure { _ = try await self.stager(try self.target(folder: "Apps2")).loadValidatedStagedUpdate() }

        XCTAssertTrue(message.contains("outside Reqling's update storage"), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path), "Nothing outside storage is deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    // MARK: - Installing

    func testInstallingHandsEveryPathToTheHelperThenQuits() async throws {
        let target = try target()
        let zip = try download(extracting: try makeApp(in: root.appendingPathComponent("Built"), version: "0.2.0"))
        let staged = try await stager(target).stageDownloadedUpdate(release: update("0.2.0"), downloadedZIPURL: zip)
        let launches = Mutex<[(URL, [String])]>([])
        let quits = Mutex(0)
        let installer = DefaultAppUpdateInstaller(
            updatesDirectory: updates,
            target: target,
            commands: commands,
            processIdentifier: { 4242 },
            launchHelper: { script, arguments in launches.withLock { $0.append((script, arguments)) } },
            terminate: { quits.withLock { $0 += 1 } }
        )

        try await installer.installAndRelaunch(stagedUpdate: staged)

        let (script, arguments) = try XCTUnwrap(launches.withLock { $0.first })
        XCTAssertEqual(quits.withLock { $0 }, 1)
        XCTAssertEqual(arguments.count, 12)
        XCTAssertEqual(arguments[0], "4242")
        XCTAssertEqual(arguments[1], staged.appBundleURL.path)
        XCTAssertEqual(arguments[3], target.bundleURL.standardizedFileURL.path)
        XCTAssertTrue(arguments[4].contains("/.Reqling.app.backup-"), arguments[4])
        XCTAssertEqual(arguments[6], updates.appendingPathComponent("staged-update.json").path)
        XCTAssertEqual(Array(arguments[9...11]), ["/usr/bin/ditto", "/usr/bin/open", "3.0"])
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("rollback \"Failed to copy staged app; restoring backup\""))
        XCTAssertTrue(text.contains("mv \"$METADATA_FILE\" \"$QUARANTINED_METADATA_FILE\""), "The metadata is quarantined during the swap")
        XCTAssertFalse(text.contains(root.path), "Paths arrive as arguments, never in the script text")
    }

    func testAnInstallWithoutItsStagedAppLaunchesNothing() async throws {
        let target = try target()
        let zip = try download(extracting: try makeApp(in: root.appendingPathComponent("Built"), version: "0.2.0"))
        let staged = try await stager(target).stageDownloadedUpdate(release: update("0.2.0"), downloadedZIPURL: zip)
        try FileManager.default.removeItem(at: staged.appBundleURL)
        let launched = Mutex(false)
        let installer = DefaultAppUpdateInstaller(
            updatesDirectory: updates,
            target: target,
            commands: commands,
            launchHelper: { _, _ in launched.withLock { $0 = true } },
            terminate: {}
        )

        let message = await stagingFailure { try await installer.installAndRelaunch(stagedUpdate: staged) }

        XCTAssertTrue(message.contains("no longer there"), message)
        XCTAssertFalse(launched.withLock { $0 })
    }
}

/// Answers the tools staging and installing run: `ditto -x` copies `extracts` into its destination, `codesign -dv`
/// reports `updateTeam` for an app inside update storage and `"TEAM"` otherwise, with one authority, and verification
/// fails only when `verifyFails` is set.
final class StubCommands: CommandRunning, @unchecked Sendable {
    struct Invocation {
        let tool: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []
    var extracts: URL?
    var verifyFails = false
    var updateTeam = "TEAM"

    var invocations: [Invocation] {
        lock.withLock { recorded }
    }

    func run(_ executable: URL, arguments: [String], currentDirectory: URL?, timeout: Duration) async throws -> CommandResult {
        let tool = executable.lastPathComponent
        lock.withLock { recorded.append(Invocation(tool: tool, arguments: arguments)) }
        switch (tool, arguments.first) {
        case ("ditto", _):
            guard let extracts, let destination = arguments.last else {
                return CommandResult(exitCode: 1)
            }
            try FileManager.default.copyItem(at: extracts, to: URL(fileURLWithPath: destination).appendingPathComponent(extracts.lastPathComponent))
            return CommandResult(exitCode: 0)
        case ("codesign", "-dv"):
            let isUpdate = (arguments.last ?? "").contains("/Updates/")
            let team = isUpdate ? lock.withLock { updateTeam } : "TEAM"
            return CommandResult(exitCode: 0, standardError: Data("TeamIdentifier=\(team)\nAuthority=Developer ID Application: Test\n".utf8))
        case ("codesign", _), ("spctl", _):
            return CommandResult(exitCode: lock.withLock { verifyFails } ? 1 : 0, standardError: Data())
        default:
            return CommandResult(exitCode: 0)
        }
    }
}
