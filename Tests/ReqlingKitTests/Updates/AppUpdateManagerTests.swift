import Foundation
@testable import ReqlingKit
import Synchronization
import XCTest

@MainActor
final class AppUpdateManagerTests: XCTestCase {
    private func feed(_ versions: String...) -> AppUpdateReleaseLookupResult {
        let notes = versions.map { AppUpdateReleaseNote(tagName: "v\($0)", version: AppUpdateVersion(string: $0)!, changelogMarkdown: "Notes \($0)") }
        return .installable(AppUpdateReleaseFeed(latestRelease: release(versions[0]), releaseNotes: notes))
    }

    private func release(_ version: String) -> AppUpdateRelease {
        stubRelease(version, servedFrom: "example.test", bytes: Data())
    }

    private func manager(
        _ client: StubReleaseClient,
        gate: ScheduleGate = ScheduleGate(),
        stager: StubStager? = nil
    ) -> AppUpdateManager {
        AppUpdateManager(
            releaseClient: client,
            currentVersion: "0.1.0",
            downloader: stager.map { _ in StubDownloader() },
            stager: stager,
            scheduleTiming: AppUpdateScheduleTiming(
                automaticCheckInterval: .seconds(21_600),
                now: { Date(timeIntervalSince1970: 1_000) },
                sleep: { try await gate.sleep($0) }
            )
        )
    }

    func testAutomaticChecksRunAtStartAndEverySixHours() async {
        let client = StubReleaseClient([feed("0.1.0"), feed("0.2.0", "0.1.0")])
        let gate = ScheduleGate()
        let updates = manager(client, gate: gate)

        updates.startAutomaticChecks()
        await gate.waitForSleeps(1)
        XCTAssertEqual(updates.status, .upToDate(release("0.1.0"), currentVersion: AppUpdateVersion(string: "0.1.0")!))
        XCTAssertEqual(updates.badgeState, .none)
        XCTAssertEqual(updates.lastCheckedAt, Date(timeIntervalSince1970: 1_000))

        gate.wakeAll()
        await gate.waitForSleeps(2)

        let requested = gate.requested
        XCTAssertEqual(requested, [.seconds(21_600), .seconds(21_600)])
        let calls = await client.calls
        XCTAssertEqual(calls, 2)
        guard case .updateAvailable(let release, _) = updates.status else {
            return XCTFail("Expected an update, got \(updates.status)")
        }
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(updates.badgeState, .updateAvailable)
        XCTAssertEqual(updates.releaseNotes.map(\.tagName), ["v0.2.0"], "Only notes newer than the running version")
        updates.stopAutomaticChecks()
    }

    func testStoppingCancelsThePendingCheck() async {
        let client = StubReleaseClient([feed("0.1.0")])
        let gate = ScheduleGate()
        let updates = manager(client, gate: gate)
        updates.startAutomaticChecks()
        await gate.waitForSleeps(1)

        updates.stopAutomaticChecks()
        await gate.waitForCancellations(1)

        let calls = await client.calls
        XCTAssertEqual(calls, 1)
    }

    /// Being offline isn't news: only a check the user asked for reports a failure.
    func testOnlyManualChecksReportFailures() async {
        let client = StubReleaseClient([.unavailable(.transportFailed("offline"))])
        let gate = ScheduleGate()
        let updates = manager(client, gate: gate)

        updates.startAutomaticChecks()
        await gate.waitForSleeps(1)
        XCTAssertEqual(updates.status, .idle)
        XCTAssertNil(updates.lastCheckedAt, "A failed check never counts as checked")

        await updates.forceCheck()
        XCTAssertEqual(updates.status, .unavailable(.transportFailed("offline")))
        XCTAssertEqual(updates.lastManualFailure, .transportFailed("offline"))
        updates.stopAutomaticChecks()
    }

    func testADownloadStagesTheUpdateAndOffersARestart() async throws {
        let stager = StubStager()
        let updates = manager(StubReleaseClient([feed("0.2.0")]), stager: stager)

        let downloaded = await updates.downloadLatestUpdate()
        let staged = try XCTUnwrap(downloaded)

        XCTAssertEqual(staged.release.tagName, "v0.2.0")
        XCTAssertEqual(updates.downloadState, .readyToInstall(staged))
        XCTAssertEqual(updates.stagedUpdate, staged)
        XCTAssertEqual(updates.restartPrompt, staged)
        XCTAssertEqual(updates.badgeState, .readyToInstall)
        updates.dismissRestartPrompt()
        XCTAssertNil(updates.restartPrompt)
        XCTAssertEqual(updates.badgeState, .readyToInstall, "Dismissing the prompt keeps the update ready")
    }

    func testDownloadingWithNothingNewerFails() async {
        let updates = manager(StubReleaseClient([feed("0.1.0")]), stager: StubStager())

        let staged = await updates.downloadLatestUpdate()

        XCTAssertNil(staged)
        guard case .failed(let failure) = updates.downloadState else {
            return XCTFail("Expected a failure, got \(updates.downloadState)")
        }
        XCTAssertTrue(failure.message.contains("No newer version"), failure.message)
    }

    func testACheckOnlyBuildCantDownload() async {
        let updates = manager(StubReleaseClient([feed("0.2.0")]))

        _ = await updates.downloadLatestUpdate()

        XCTAssertEqual(updates.downloadState, .failed(AppUpdateFailure(message: "This build of Reqling can't download updates.")))
    }

    func testAnUpdateStagedByAnEarlierLaunchIsRestored() async {
        let stager = StubStager()
        let staged = StagedAppUpdate(
            release: stubRelease("0.2.0", servedFrom: "example.test", bytes: Data()),
            appBundleURL: URL(fileURLWithPath: "/tmp/Staged/v0.2.0/Reqling.app"),
            stagedAt: Date(timeIntervalSince1970: 0)
        )
        stager.restored = staged
        let updates = manager(StubReleaseClient([feed("0.2.0")]), stager: stager)

        await updates.loadStagedUpdateIfAvailable()

        XCTAssertEqual(updates.stagedUpdate, staged)
        XCTAssertEqual(updates.badgeState, .readyToInstall)
        XCTAssertEqual(updates.restartPrompt, staged)
    }
}

private actor StubReleaseClient: AppUpdateReleaseClient {
    private let results: [AppUpdateReleaseLookupResult]
    private(set) var calls = 0

    init(_ results: [AppUpdateReleaseLookupResult]) {
        self.results = results
    }

    func latestRelease() async -> AppUpdateReleaseLookupResult {
        defer { calls += 1 }
        return results[min(calls, results.count - 1)]
    }
}

private struct StubDownloader: AppUpdateDownloading {
    func download(release: AppUpdateRelease, progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        await progress(1)
        return URL(fileURLWithPath: "/tmp/never-read.zip")
    }
}

private final class StubStager: AppUpdateStaging, @unchecked Sendable {
    var restored: StagedAppUpdate?

    func stageDownloadedUpdate(release: AppUpdateRelease, downloadedZIPURL: URL) async throws -> StagedAppUpdate {
        StagedAppUpdate(
            release: release,
            appBundleURL: URL(fileURLWithPath: "/tmp/Staged/\(release.tagName)/Reqling.app"),
            stagedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func loadValidatedStagedUpdate() async throws -> StagedAppUpdate? {
        restored
    }
}

/// A sleep the test wakes by hand. A check reaching its next sleep is the checkpoint that it has applied its result.
final class ScheduleGate: Sendable {
    private struct State {
        var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var cancelled: Set<UUID> = []
        var waiters: [CheckedContinuation<Void, Never>] = []
        var requested: [Duration] = []
        var cancellations = 0
    }

    private let state = Mutex(State())

    var requested: [Duration] {
        state.withLock { $0.requested }
    }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        signal { $0.requested.append(duration) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelledAlready = state.withLock { state in
                    guard state.cancelled.remove(id) == nil else {
                        return true
                    }
                    state.sleepers[id] = continuation
                    return false
                }
                if cancelledAlready {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state in
                let sleeper = state.sleepers.removeValue(forKey: id)
                if sleeper == nil {
                    state.cancelled.insert(id)
                }
                return sleeper
            }
            signal { $0.cancellations += 1 }
            sleeper?.resume(throwing: CancellationError())
        }
    }

    func wakeAll() {
        let woken = state.withLock { state in
            defer { state.sleepers = [:] }
            return Array(state.sleepers.values)
        }
        for sleeper in woken {
            sleeper.resume()
        }
    }

    func waitForSleeps(_ count: Int) async {
        await wait { $0.requested.count >= count }
    }

    func waitForCancellations(_ count: Int) async {
        await wait { $0.cancellations >= count }
    }

    private func wait(until isDone: @escaping @Sendable (State) -> Bool) async {
        while !state.withLock({ isDone($0) }) {
            await withCheckedContinuation { continuation in
                let done = state.withLock { state in
                    guard !isDone(state) else {
                        return true
                    }
                    state.waiters.append(continuation)
                    return false
                }
                if done {
                    continuation.resume()
                }
            }
        }
    }

    private func signal(_ change: (inout State) -> Void) {
        let waiters = state.withLock { state in
            change(&state)
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}
